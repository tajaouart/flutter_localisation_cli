// What a real iOS client hit on its first day (Reelfree, 2026-11-01): an
// import with --translate that answered "Gateway Time-out", 35 locales added
// in silence for eleven minutes, an export blocked by a key with no name, and
// identical answers reported as plain failures.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_localisation_cli/src/call_budget.dart';
import 'package:flutter_localisation_cli/src/config.dart';
import 'package:flutter_localisation_cli/src/exceptions.dart';
import 'package:flutter_localisation_cli/src/management_client.dart';
import 'package:flutter_localisation_cli/src/operations.dart';
import 'package:flutter_localisation_cli/src/xcstrings.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

http.Response _project({final List<String> locales = const <String>['en', 'fr']}) =>
    http.Response(
      jsonEncode(<String, dynamic>{
        'id': 7,
        'name': 'P',
        'flavors': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 3,
            'name': 'default',
            'languages': <Map<String, dynamic>>[
              for (final String code in locales)
                <String, dynamic>{
                  'code': code,
                  'is_base_language': code == 'en',
                  'translations': <Map<String, dynamic>>[],
                },
            ],
          },
        ],
      }),
      200,
    );

Operations _ops(final MockClient mock, final List<String> progress) =>
    Operations(
      ManagementClient(baseUrl: 'http://t', token: 'flk_live_x', httpClient: mock),
      7,
      flavor: 'default',
      budget: CallBudget.disabled(),
    )
      ..onProgress = progress.add
      ..jobPollInterval = Duration.zero;

final String _arb = jsonEncode(<String, dynamic>{'@@locale': 'en', 'a': 'A', 'b': 'B'});

void main() {
  test('import --translate asks for a queued job and polls it to the end', () async {
    final List<String> progress = <String>[];
    final List<Map<String, String>> posted = <Map<String, String>>[];
    int polls = 0;
    final MockClient mock = MockClient((final http.Request req) async {
      if (req.url.path == '/api/projects/7/') return _project();
      if (req.url.path == '/api/project/7/import-arb/') {
        final String body = req.body;
        posted.add(<String, String>{
          'translate_async': RegExp(r'name="translate_async"\r\n\r\n(\w+)').firstMatch(body)!.group(1)!,
        });
        return http.Response(
            jsonEncode(<String, dynamic>{
              'import': <String, dynamic>{
                'keys': <String, dynamic>{'written': 2, 'skipped': 0, 'unchanged': 0},
              },
              'translation': <String, dynamic>{
                'status': 'queued',
                'pending': 2,
                'job_id': 'j1',
                'status_url': '/api/ai_batch_translate_async/j1/',
              },
            }),
            200);
      }
      if (req.url.path == '/api/ai_batch_translate_async/j1/') {
        polls++;
        if (polls == 1) {
          return http.Response(jsonEncode(<String, dynamic>{'state': 'queued'}), 200);
        }
        if (polls == 2) {
          return http.Response(
              jsonEncode(<String, dynamic>{
                'state': 'running',
                'progress': <String, dynamic>{'done': 1, 'total': 2},
              }),
              200);
        }
        return http.Response(
            jsonEncode(<String, dynamic>{
              'state': 'done',
              'results': <String, dynamic>{'success_count': 1, 'failed_count': 1, 'identical_count': 1},
            }),
            200);
      }
      return http.Response('not found', 404);
    });

    final OpResult r = await _ops(mock, progress).importArb(_arb, translate: true);

    expect(posted.single['translate_async'], 'true');
    expect(r.ok, isTrue);
    expect(r.data['translated'], 1);
    expect(r.data['identical_count'], 1);
    expect(r.message, contains('translated 1 locale-string(s)'));
    expect(r.message, contains('1 came back identical to the source'));
    expect(r.message, isNot(contains('failed')));
    expect(progress, <String>[
      'Translating 2 locale-string(s) on the server...',
      'Translation job queued...',
      'Translating: 1/2',
    ]);
  });

  test('a failed translation job keeps the import and says how to finish', () async {
    final MockClient mock = MockClient((final http.Request req) async {
      if (req.url.path == '/api/projects/7/') return _project();
      if (req.url.path == '/api/project/7/import-arb/') {
        return http.Response(
            jsonEncode(<String, dynamic>{
              'translation': <String, dynamic>{
                'status': 'queued',
                'pending': 2,
                'status_url': '/api/ai_batch_translate_async/j2/',
              },
            }),
            200);
      }
      return http.Response(jsonEncode(<String, dynamic>{'state': 'failed', 'error': 'quota'}), 200);
    });

    final OpResult r = await _ops(mock, <String>[]).importArb(_arb, translate: true);

    expect(r.ok, isFalse);
    expect(r.message, contains('translation job failed: quota'));
    expect(r.message, contains('run the import again with --translate'));
  });

  test('an import without --translate says the new keys are still untranslated', () async {
    final MockClient mock = MockClient((final http.Request req) async {
      if (req.url.path == '/api/projects/7/') return _project(locales: <String>['en', 'fr', 'de']);
      return http.Response(
          jsonEncode(<String, dynamic>{
            'import': <String, dynamic>{
              'keys': <String, dynamic>{'written': 2, 'skipped': 0, 'unchanged': 0},
              'problems': <String>['"" (empty key): skipped, there is nothing to translate'],
            },
          }),
          200);
    });

    final OpResult r = await _ops(mock, <String>[]).importArb(_arb);

    expect(r.message, contains('The 2 new key(s) hold the base text in the 2 other locale(s)'));
    expect(r.message, contains('(empty key)'));

    final OpResult overwritten = await _ops(mock, <String>[]).importArb(_arb, overwrite: true);
    expect(overwritten.message, isNot(contains('hold the base text')));
  });

  test('languages add reports each locale as it lands', () async {
    final List<String> progress = <String>[];
    final Set<String> added = <String>{};
    final MockClient mock = MockClient((final http.Request req) async {
      if (req.url.path == '/api/projects/7/') {
        return _project(locales: <String>['en', ...added]);
      }
      if (req.url.path == '/api/add-language/') {
        added.add((jsonDecode(req.body) as Map<String, dynamic>)['languageCode'] as String);
        return http.Response('{"status": "success"}', 201);
      }
      return http.Response('not found', 404);
    });

    final OpResult r = await _ops(mock, progress).addLanguages(<String>['de', 'fr']);

    expect(r.ok, isTrue);
    expect(progress.first, 'Adding 2 locale(s)...');
    expect(progress[1], startsWith('  [1/2] ✓ Added "de"'));
    expect(progress[2], startsWith('  [2/2] ✓ Added "fr"'));
  });

  test('the export guard ignores the empty key Xcode extracts', () {
    final Directory dir = Directory.systemTemp.createTempSync('fl_empty_key');
    final File catalog = File('${dir.path}/Localizable.xcstrings')
      ..writeAsStringSync(jsonEncode(<String, dynamic>{
        'sourceLanguage': 'en',
        'strings': <String, dynamic>{'': <String, dynamic>{}, 'Close': <String, dynamic>{}, 'New': <String, dynamic>{}},
        'version': '1.0',
      }));
    expect(localOnlyCatalogKeys(catalog, <String>{'Close'}), <String>['New']);
    dir.deleteSync(recursive: true);
  });

  test('languages add sends every locale in one request and follows the translation job', () async {
    final List<String> progress = <String>[];
    final List<String> hits = <String>[];
    Map<String, dynamic>? sent;
    final MockClient mock = MockClient((final http.Request req) async {
      hits.add('${req.method} ${req.url.path}');
      if (req.url.path == '/api/projects/7/') return _project();
      if (req.url.path == '/api/add-languages/') {
        sent = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
            jsonEncode(<String, dynamic>{
              'added': 2,
              'results': <Map<String, dynamic>>[
                <String, dynamic>{'code': 'de', 'status': 'added'},
                <String, dynamic>{'code': 'fr', 'status': 'exists'},
                <String, dynamic>{'code': 'de-AT', 'status': 'added'},
                <String, dynamic>{'code': 'xx', 'status': 'error', 'message': "'xx' does not name a known language."},
              ],
              'translation': <String, dynamic>{
                'status': 'queued',
                'pending': 4,
                'status_url': '/api/ai_batch_translate_async/j3/',
              },
            }),
            201);
      }
      if (req.url.path == '/api/ai_batch_translate_async/j3/') {
        return http.Response(
            jsonEncode(<String, dynamic>{
              'state': 'done',
              'results': <String, dynamic>{'success_count': 3, 'failed_count': 1, 'identical_count': 1},
            }),
            200);
      }
      return http.Response('not found', 404);
    });

    final OpResult r = await _ops(mock, progress)
        .addLanguages(<String>['de-AT', 'de', 'fr', 'xx'], autoTranslate: true);

    expect(hits.where((final String h) => h.startsWith('POST')).toList(),
        <String>['POST /api/add-languages/']);
    expect(sent!['languageCodes'], <String>['de', 'fr', 'xx', 'de-AT']);
    expect(sent!['autoTranslate'], isTrue);
    expect(r.ok, isFalse);
    expect(r.message,
        'Added 2/4 locale(s). Translated 3 locale-string(s), 1 identical to the source left for review.');
    expect(r.data['failures'], <String>["xx: 'xx' does not name a known language."]);
    expect(progress, containsAllInOrder(<String>[
      '  ✓ Added "de" to "default".',
      '  ✓ Locale "fr" is already on flavor "default".',
      "  ✗ 'xx' does not name a known language.",
      'Translating 4 locale-string(s) on the server...',
    ]));
  });

  test('a single locale keeps the per-locale call and its checks', () async {
    final List<String> hits = <String>[];
    final MockClient mock = MockClient((final http.Request req) async {
      hits.add('${req.method} ${req.url.path}');
      if (req.url.path == '/api/projects/7/') return _project(locales: <String>['en', if (hits.length > 2) 'de']);
      return http.Response('{"status": "success"}', 201);
    });
    await _ops(mock, <String>[]).addLanguages(<String>['de']);
    expect(hits, contains('POST /api/add-language/'));
    expect(hits, isNot(contains('POST /api/add-languages/')));
  });

  test('a numeric project in the config is the project id, a wrong type a clear error', () {
    final Directory dir = Directory.systemTemp.createTempSync('fl_cfg');
    final File cfg = File('${dir.path}/flutterlocalisation.json')
      ..writeAsStringSync(jsonEncode(<String, dynamic>{'project': 129, 'xcstrings_dir': '.'}));
    final ProjectConfig loaded = ProjectConfig.load(path: cfg.path);
    expect(loaded.projectId, 129);
    expect(loaded.project, isNull);
    cfg.writeAsStringSync(jsonEncode(<String, dynamic>{'project': 'P', 'flavor': 3}));
    expect(() => ProjectConfig.load(path: cfg.path),
        throwsA(isA<ConfigException>().having((final ConfigException e) => e.message, 'message',
            contains('"flavor" must be a string'))));
    dir.deleteSync(recursive: true);
  });
}
