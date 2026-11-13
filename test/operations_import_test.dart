import 'dart:convert';
import 'dart:io';

import 'package:flutter_localisation_cli/src/management_client.dart';
import 'package:flutter_localisation_cli/src/call_budget.dart';
import 'package:flutter_localisation_cli/src/exceptions.dart';
import 'package:flutter_localisation_cli/src/operations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

http.Response _project(final http.Request req) => http.Response(
      jsonEncode(<String, dynamic>{
        'id': 7,
        'name': 'P',
        'flavors': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 3,
            'name': 'default',
            'languages': <Map<String, dynamic>>[
              <String, dynamic>{
                'code': 'en',
                'is_base_language': true,
                'translations': <Map<String, dynamic>>[],
              },
            ],
          },
        ],
      }),
      200,
    );

void main() {
  _languageTests();

  test('importArb posts the ARB to the import endpoint and counts keys',
      () async {
    final List<String> hits = <String>[];
    final MockClient mock = MockClient((final http.Request req) async {
      hits.add('${req.method} ${req.url.path}');
      if (req.url.path == '/api/projects/7/') return _project(req);
      return http.Response(
          jsonEncode(<String, dynamic>{'import_status': 'success'}), 200);
    });
    final ManagementClient client = ManagementClient(
        baseUrl: 'http://t', token: 'flk_live_x', httpClient: mock);

    final String arb = jsonEncode(<String, dynamic>{
      '@@locale': 'en',
      'k1': 'v1',
      'k2': 'v2',
      '@k1': <String, dynamic>{'description': 'meta, not a key'},
    });
    final OpResult r = await Operations(client, 7,
            flavor: 'default', budget: CallBudget.disabled())
        .importArb(arb);

    expect(r.ok, isTrue);
    expect(hits, contains('POST /api/project/7/import-arb/'));
    expect(r.data['imported'], 2); // k1, k2 — not @@locale / @k1
  });

  test('importArb dry run resolves but does NOT hit the import endpoint',
      () async {
    final List<String> hits = <String>[];
    final MockClient mock = MockClient((final http.Request req) async {
      hits.add('${req.method} ${req.url.path}');
      if (req.url.path == '/api/projects/7/') return _project(req);
      return http.Response('{}', 200);
    });
    final ManagementClient client =
        ManagementClient(baseUrl: 'http://t', token: 'x', httpClient: mock);

    final OpResult r = await Operations(client, 7,
            flavor: 'default', budget: CallBudget.disabled())
        .importArb(jsonEncode(<String, dynamic>{'k': 'v'}), dryRun: true);

    expect(r.ok, isTrue);
    expect(r.message, contains('DRY RUN'));
    expect(hits.any((final String h) => h.contains('import-arb')), isFalse);
  });

  test('importArb rejects invalid JSON before any network call', () async {
    final List<String> hits = <String>[];
    final MockClient mock = MockClient((final http.Request req) async {
      hits.add('${req.method} ${req.url.path}');
      return http.Response('{}', 200);
    });
    final ManagementClient client =
        ManagementClient(baseUrl: 'http://t', token: 'x', httpClient: mock);

    final OpResult r = await Operations(client, 7,
            flavor: 'default', budget: CallBudget.disabled())
        .importArb('not json {');

    expect(r.ok, isFalse);
    expect(r.message, contains('Invalid ARB'));
    expect(hits, isEmpty);
  });

  test('importArb WITH --language scopes to that locale only', () async {
    String? body;
    final MockClient mock = MockClient((final http.Request req) async {
      if (req.url.path == '/api/projects/7/') return _project(req);
      if (req.url.path == '/api/project/7/import-arb/') {
        body = req.body;
        return http.Response(
            jsonEncode(<String, dynamic>{'import_status': 'success'}), 200);
      }
      return http.Response('{}', 200);
    });
    final ManagementClient client =
        ManagementClient(baseUrl: 'http://t', token: 'x', httpClient: mock);

    await Operations(client, 7,
            flavor: 'default', budget: CallBudget.disabled())
        .importArb(jsonEncode(<String, dynamic>{'k': 'v'}), languageCode: 'fr');

    // A targeted locale import must NOT fan out across every language, else it
    // clobbers the others with this file's values.
    expect(_field(body!, 'apply_to_all_languages'), 'false');
    expect(_field(body!, 'selected_language_code'), 'fr');
  });

  test('importArb WITHOUT --language still seeds every locale', () async {
    String? body;
    final MockClient mock = MockClient((final http.Request req) async {
      if (req.url.path == '/api/projects/7/') return _project(req);
      if (req.url.path == '/api/project/7/import-arb/') {
        body = req.body;
        return http.Response(
            jsonEncode(<String, dynamic>{'import_status': 'success'}), 200);
      }
      return http.Response('{}', 200);
    });
    final ManagementClient client =
        ManagementClient(baseUrl: 'http://t', token: 'x', httpClient: mock);

    await Operations(client, 7,
            flavor: 'default', budget: CallBudget.disabled())
        .importArb(jsonEncode(<String, dynamic>{'k': 'v'}));

    // A base-language import seeds all locales so fresh keys are translatable.
    expect(_field(body!, 'apply_to_all_languages'), 'true');
  });

  test('importArb naming the BASE language explicitly still seeds every locale',
      () async {
    String? body;
    final MockClient mock = MockClient((final http.Request req) async {
      if (req.url.path == '/api/projects/7/') return _project(req);
      if (req.url.path == '/api/project/7/import-arb/') {
        body = req.body;
        return http.Response(
            jsonEncode(<String, dynamic>{'import_status': 'success'}), 200);
      }
      return http.Response('{}', 200);
    });
    final ManagementClient client =
        ManagementClient(baseUrl: 'http://t', token: 'x', httpClient: mock);

    await Operations(client, 7,
            flavor: 'default', budget: CallBudget.disabled())
        .importArb(jsonEncode(<String, dynamic>{'k': 'v'}), languageCode: 'en');

    // `--language en` on an en-base project must behave exactly like omitting
    // the flag. It used to scope the import to `en` alone, leaving the other
    // locales without rows; `--translate` then found nothing, reported success,
    // and the caller's only working fallback was one add+translate PER KEY.
    expect(_field(body!, 'apply_to_all_languages'), 'true');
  });

  test('importArb --translate FAILS loudly when locales were left unseeded',
      () async {
    // en has the imported key, fr does not — the exact state the old code
    // reported as "imported; nothing to translate", i.e. success with zero
    // translations.
    http.Response projectWithUnseededFr(final http.Request req) =>
        http.Response(
          jsonEncode(<String, dynamic>{
            'id': 7,
            'name': 'P',
            'flavors': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 3,
                'name': 'default',
                'languages': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'code': 'en',
                    'is_base_language': true,
                    'translations': <Map<String, dynamic>>[
                      <String, dynamic>{'id': 1, 'key': 'k', 'value': 'v'},
                    ],
                  },
                  <String, dynamic>{
                    'code': 'fr',
                    'is_base_language': false,
                    'translations': <Map<String, dynamic>>[],
                  },
                ],
              },
            ],
          }),
          200,
        );

    final MockClient mock = MockClient((final http.Request req) async {
      if (req.url.path == '/api/projects/7/') return projectWithUnseededFr(req);
      return http.Response(
          jsonEncode(<String, dynamic>{'import_status': 'success'}), 200);
    });
    final ManagementClient client =
        ManagementClient(baseUrl: 'http://t', token: 'x', httpClient: mock);

    final OpResult r = await Operations(client, 7,
            flavor: 'default', budget: CallBudget.disabled())
        .importArb(
      jsonEncode(<String, dynamic>{'k': 'v'}),
      translate: true,
    );

    expect(r.ok, isFalse, reason: 'translating nothing is not success');
    expect(r.message, contains('fr'));
    expect(r.data['unseeded_locales'], <String>['fr']);
    expect(r.data['translated'], 0);
  });

  test('a server that filled the locales itself ends the run there', () async {
    // The point of the server-side flag: ONE round trip. If the CLI still went
    // on to re-fetch the project and batch-translate, the work would be done
    // twice and billed twice.
    var batchCalls = 0;
    final MockClient mock = MockClient((final http.Request req) async {
      if (req.url.path == '/api/ai_batch_translate/') {
        batchCalls++;
        return http.Response('{}', 200);
      }
      if (req.url.path.contains('import')) {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'import_status': 'success',
            'translation': <String, dynamic>{
              'status': 'success',
              'translated': 30,
              'failed': 0,
            },
          }),
          200,
        );
      }
      return _project(req);
    });

    final OpResult r = await Operations(
            ManagementClient(
              baseUrl: 'http://t',
              token: 'x',
              httpClient: mock,
            ),
            7,
            flavor: 'default')
        .importArb(jsonEncode(<String, dynamic>{'k': 'v'}), translate: true);

    expect(r.ok, isTrue);
    expect(r.data['server_side'], isTrue);
    expect(r.data['translated'], 30);
    expect(batchCalls, 0, reason: 'the server already did it');
  });

  test('an older server without the field falls back to client-side batching',
      () async {
    // The flag is ignored by any deployment that predates it, which answers
    // with no `translation` block. That must degrade to the old path rather
    // than silently import nothing translated.
    var batchCalls = 0;
    final MockClient mock = MockClient((final http.Request req) async {
      if (req.url.path == '/api/ai_batch_translate/') {
        batchCalls++;
        return http.Response('{}', 200);
      }
      if (req.url.path.contains('import')) {
        return http.Response(
          jsonEncode(<String, dynamic>{'import_status': 'success'}),
          200,
        );
      }
      return http.Response(
        jsonEncode(<String, dynamic>{
          'id': 7,
          'name': 'P',
          'flavors': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 3,
              'name': 'default',
              'languages': <Map<String, dynamic>>[
                <String, dynamic>{
                  'code': 'en',
                  'is_base_language': true,
                  'translations': <Map<String, dynamic>>[
                    <String, dynamic>{'id': 1, 'key': 'k', 'value': 'v'},
                  ],
                },
                <String, dynamic>{
                  'code': 'fr',
                  'is_base_language': false,
                  'translations': <Map<String, dynamic>>[
                    <String, dynamic>{'id': 2, 'key': 'k', 'value': 'v'},
                  ],
                },
              ],
            },
          ],
        }),
        200,
      );
    });

    await Operations(
            ManagementClient(
              baseUrl: 'http://t',
              token: 'x',
              httpClient: mock,
            ),
            7,
            flavor: 'default')
        .importArb(jsonEncode(<String, dynamic>{'k': 'v'}), translate: true);

    expect(batchCalls, 1, reason: 'the CLI must still translate it');
  });

  test('a job the server refuses as too large falls back too', () async {
    // "too_large" is the server saying the work cannot finish inside a request
    // — not that it is done. Treating it as done would leave every row
    // untranslated while reporting success.
    var batchCalls = 0;
    final MockClient mock = MockClient((final http.Request req) async {
      if (req.url.path == '/api/ai_batch_translate/') {
        batchCalls++;
        return http.Response('{}', 200);
      }
      if (req.url.path.contains('import')) {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'import_status': 'success',
            'translation': <String, dynamic>{
              'status': 'too_large',
              'pending': 25110,
            },
          }),
          200,
        );
      }
      return http.Response(
        jsonEncode(<String, dynamic>{
          'id': 7,
          'name': 'P',
          'flavors': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 3,
              'name': 'default',
              'languages': <Map<String, dynamic>>[
                <String, dynamic>{
                  'code': 'en',
                  'is_base_language': true,
                  'translations': <Map<String, dynamic>>[
                    <String, dynamic>{'id': 1, 'key': 'k', 'value': 'v'},
                  ],
                },
                <String, dynamic>{
                  'code': 'fr',
                  'is_base_language': false,
                  'translations': <Map<String, dynamic>>[
                    <String, dynamic>{'id': 2, 'key': 'k', 'value': 'v'},
                  ],
                },
              ],
            },
          ],
        }),
        200,
      );
    });

    await Operations(
            ManagementClient(
              baseUrl: 'http://t',
              token: 'x',
              httpClient: mock,
            ),
            7,
            flavor: 'default')
        .importArb(jsonEncode(<String, dynamic>{'k': 'v'}), translate: true);

    expect(batchCalls, 1);
  });

  test('import --translate chunks its batch calls', () async {
    // The 504 that motivated this was not "837 keys is too many to create" —
    // the import itself is one request by design and worked. It was the
    // translate step sending every row in a single call: 837 keys × 30 locales
    // = 25,110 rows in one HTTP request. retranslate had chunked for exactly
    // this reason and this path had not, so the protection existed and simply
    // was not shared.
    final List<int> batchSizes = <int>[];
    final MockClient mock = MockClient((final http.Request req) async {
      if (req.url.path == '/api/ai_batch_translate/') {
        final Map<String, dynamic> body =
            jsonDecode(req.body) as Map<String, dynamic>;
        batchSizes.add((body['translation_ids'] as List<dynamic>).length);
        return http.Response('{}', 200);
      }
      if (req.url.path.contains('import')) return http.Response('{}', 200);
      return http.Response(
        jsonEncode(<String, dynamic>{
          'id': 7,
          'name': 'P',
          'flavors': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 3,
              'name': 'default',
              'languages': <Map<String, dynamic>>[
                <String, dynamic>{
                  'code': 'en',
                  'is_base_language': true,
                  'translations': <Map<String, dynamic>>[
                    for (int i = 0; i < 25; i++)
                      <String, dynamic>{
                        'id': i + 1,
                        'key': 'k$i',
                        'value': 'v'
                      },
                  ],
                },
                <String, dynamic>{
                  'code': 'fr',
                  'is_base_language': false,
                  'translations': <Map<String, dynamic>>[
                    for (int i = 0; i < 25; i++)
                      <String, dynamic>{
                        'id': 100 + i,
                        'key': 'k$i',
                        'value': 'v',
                      },
                  ],
                },
              ],
            },
          ],
        }),
        200,
      );
    });

    await Operations(
            ManagementClient(
              baseUrl: 'http://t',
              token: 'x',
              httpClient: mock,
            ),
            7,
            flavor: 'default')
        .importArb(
      jsonEncode(<String, dynamic>{
        for (int i = 0; i < 25; i++) 'k$i': 'v',
      }),
      translate: true,
      chunkSize: 10,
    );

    expect(batchSizes, <int>[10, 10, 5],
        reason: '25 rows at chunkSize 10 is three calls, not one');
  });

  test('a timeout while translating still reports the keys as imported',
      () async {
    // A big `--translate` is the request most likely to time out, and the
    // import has already been written by the time it does. Letting the
    // exception escape reported a bare "Gateway Time-out" for a run whose 837
    // keys were all safely created — so the true state (keys in, values not)
    // and the one-command remedy were both invisible.
    final MockClient mock = MockClient((final http.Request req) async {
      if (req.url.path == '/api/ai_batch_translate/') {
        return http.Response(
          jsonEncode(<String, dynamic>{'message': 'Gateway Time-out'}),
          504,
        );
      }
      if (req.url.path.contains('import')) {
        return http.Response('{}', 200);
      }
      return http.Response(
        jsonEncode(<String, dynamic>{
          'id': 7,
          'name': 'P',
          'flavors': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 3,
              'name': 'default',
              'languages': <Map<String, dynamic>>[
                <String, dynamic>{
                  'code': 'en',
                  'is_base_language': true,
                  'translations': <Map<String, dynamic>>[
                    <String, dynamic>{'id': 1, 'key': 'k', 'value': 'v'},
                  ],
                },
                <String, dynamic>{
                  'code': 'fr',
                  'is_base_language': false,
                  'translations': <Map<String, dynamic>>[
                    <String, dynamic>{'id': 2, 'key': 'k', 'value': 'v'},
                  ],
                },
              ],
            },
          ],
        }),
        200,
      );
    });
    final ManagementClient client =
        ManagementClient(baseUrl: 'http://t', token: 'x', httpClient: mock);

    final OpResult r = await Operations(client, 7,
            flavor: 'default', budget: CallBudget.disabled())
        .importArb(
      jsonEncode(<String, dynamic>{'k': 'v'}),
      translate: true,
    );

    expect(r.ok, isFalse, reason: 'the caller did not get what they asked for');
    expect(r.data['imported'], 1, reason: 'but the keys ARE created');
    expect(r.message, contains('Imported'));
    expect(r.message, contains('fl retranslate'),
        reason: 'the message must name the remedy');
  });
}

/// A German project with [others] as its translated languages; records what
/// each import asked for and refuses translation when [translateScope] is off.
({ManagementClient client, List<String> imports}) _germanProject({
  final List<String> others = const <String>['en'],
  final bool translateScope = true,
  final String refusalBody =
      "auto_translate requires the 'translate' scope; this token only has "
          "'strings:write'. Import without it, then translate with a token "
          'that has the scope.',
}) {
  final List<String> imports = <String>[];
  final MockClient mock = MockClient((final http.Request req) async {
    if (req.url.path == '/api/projects/7/') {
      return http.Response(
        jsonEncode(<String, dynamic>{
          'id': 7,
          'name': 'P',
          'flavors': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 3,
              'name': 'default',
              'languages': <Map<String, dynamic>>[
                for (final String code in <String>['de', ...others])
                  <String, dynamic>{
                    'code': code,
                    'is_base_language': code == 'de',
                    'translations': <Map<String, dynamic>>[],
                  },
              ],
            },
          ],
        }),
        200,
      );
    }
    final bool translate = _field(req.body, 'auto_translate') == 'true';
    if (translate && !translateScope) {
      return http.Response(
          jsonEncode(<String, String>{'error': refusalBody}), 403);
    }
    imports.add('${_field(req.body, 'selected_language_code')}'
        '${_field(req.body, 'apply_to_all_languages') == 'true' ? ' all' : ''}'
        '${translate ? ' +translate' : ''}');
    return http.Response(
      jsonEncode(<String, dynamic>{
        'import_status': 'success',
        if (translate)
          'translation': <String, dynamic>{
            'status': 'success',
            'translated': 4,
            'failed': 0,
          },
      }),
      200,
    );
  });
  return (
    client: ManagementClient(baseUrl: 'http://t', token: 'x', httpClient: mock),
    imports: imports,
  );
}

Operations _ops(final ManagementClient client) =>
    Operations(client, 7, flavor: 'default', budget: CallBudget.disabled());

void _languageTests() {
  group('the language of an ARB imported without --language', () {
    test('comes from @@locale when that is another language of the flavor',
        () async {
      final ({ManagementClient client, List<String> imports}) t =
          _germanProject();
      final OpResult r = await _ops(t.client).importArb(
          jsonEncode(<String, dynamic>{'@@locale': 'en', 'k': 'v'}),
          fileName: 'strings.arb');
      expect(r.ok, isTrue);
      expect(t.imports, <String>['en']);
      expect(
          r.message,
          endsWith('Imported as "en" (from @@locale). Pass --language to '
              'choose another.'));
      expect(r.data['language'], 'en');
    });

    test('comes from the file name when the file has no @@locale', () async {
      final ({ManagementClient client, List<String> imports}) t =
          _germanProject(others: <String>['en', 'pt-BR']);
      final OpResult r = await _ops(t.client).importArb(
          jsonEncode(<String, dynamic>{'k': 'v'}),
          fileName: 'app_pt_BR.arb');
      expect(t.imports, <String>['pt-BR']);
      expect(r.message, contains('Imported as "pt-BR" (from the file name).'));
    });

    test('the base language, or no hint at all, imports as before', () async {
      final ({ManagementClient client, List<String> imports}) t =
          _germanProject();
      final OpResult named = await _ops(t.client).importArb(
          jsonEncode(<String, dynamic>{'@@locale': 'de', 'k': 'v'}),
          fileName: 'app_de.arb');
      final OpResult plain = await _ops(t.client).importArb(
          jsonEncode(<String, dynamic>{'k': 'v'}),
          fileName: 'new_keys.arb');
      expect(t.imports, <String>['de all', 'de all']);
      expect(named.message, isNot(contains('Imported as')));
      expect(plain.message, isNot(contains('Imported as')));
    });

    test('an explicit language wins and says nothing extra', () async {
      final ({ManagementClient client, List<String> imports}) t =
          _germanProject();
      final OpResult r = await _ops(t.client).importArb(
          jsonEncode(<String, dynamic>{'@@locale': 'en', 'k': 'v'}),
          languageCode: 'de',
          fileName: 'app_en.arb');
      expect(t.imports, <String>['de all']);
      expect(r.message, isNot(contains('Imported as')));
    });

    test('a language the flavor does not have is refused with both fixes',
        () async {
      final ({ManagementClient client, List<String> imports}) t =
          _germanProject();
      final OpResult r = await _ops(t.client).importArb(
          jsonEncode(<String, dynamic>{'k': 'v'}),
          fileName: 'app_fr.arb');
      expect(r.ok, isFalse);
      expect(t.imports, isEmpty);
      expect(
          r.message,
          'app_fr.arb holds "fr" (from the file name), and flavor "default" '
          'has no such language (base "de", also en). Nothing was imported. '
          'Add it with `fl languages add fr`, or pass --language de to import '
          'the file as the base text on purpose.');
    });

    test('a three-letter word ending the file name is not taken for one',
        () async {
      final ({ManagementClient client, List<String> imports}) t =
          _germanProject();
      final OpResult r = await _ops(t.client).importArb(
          jsonEncode(<String, dynamic>{'k': 'v'}),
          fileName: 'keys_new.arb');
      expect(r.ok, isTrue);
      expect(t.imports, <String>['de all']);
    });

    test('a dry run names the language it would use', () async {
      final ({ManagementClient client, List<String> imports}) t =
          _germanProject();
      final OpResult r = await _ops(t.client).importArb(
          jsonEncode(<String, dynamic>{'k': 'v'}),
          fileName: 'app_en.arb',
          dryRun: true);
      expect(t.imports, isEmpty);
      expect(r.message, contains('language "en"'));
      expect(r.message, contains('Would import as "en" (from the file name).'));
    });
  });

  group('adoptArbs', () {
    late Directory tmp;
    late File template;

    void arb(final String name, final String locale) =>
        File('${tmp.path}/$name').writeAsStringSync(
            jsonEncode(<String, String>{'@@locale': locale, 'k': 'v'}));

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('fl_adopt_test');
      arb('app_de.arb', 'de');
      template = File('${tmp.path}/app_de.arb');
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('imports every local ARB as its language and translates nothing',
        () async {
      arb('app_en.arb', 'en');
      arb('app_pt_BR.arb', 'pt-BR');
      final ({ManagementClient client, List<String> imports}) t =
          _germanProject(others: <String>['en', 'pt-BR']);
      final OpResult r = await _ops(t.client).adoptArbs(template);
      expect(r.ok, isTrue);
      expect(t.imports, <String>['de all', 'en', 'pt-BR']);
      expect(r.message.split('\n'), hasLength(3));
      expect(r.message, contains('app_pt_BR.arb (pt-BR):'));
      expect(r.message, isNot(contains('--translate')));
    });

    test('translates after the local files, for the language with no file',
        () async {
      arb('app_en.arb', 'en');
      final ({ManagementClient client, List<String> imports}) t =
          _germanProject(others: <String>['en', 'fr']);
      final OpResult r = await _ops(t.client).adoptArbs(template);
      expect(r.ok, isTrue);
      expect(t.imports, <String>['de all', 'en', 'de all +translate']);
      expect(r.message, contains('Translated 4 locale-string(s)'));
    });

    test('a local file that lacks a base key gets that key translated',
        () async {
      File('${tmp.path}/app_de.arb').writeAsStringSync(jsonEncode(
          <String, String>{'@@locale': 'de', 'k': 'v', 'added': 'Neu'}));
      arb('app_en.arb', 'en');
      final ({ManagementClient client, List<String> imports}) t =
          _germanProject(others: <String>['en']);
      final OpResult r = await _ops(t.client).adoptArbs(template);
      expect(r.ok, isTrue);
      expect(t.imports, <String>['de all', 'en', 'de all +translate']);
    });

    test('the same gap without the Translate scope names the language',
        () async {
      File('${tmp.path}/app_de.arb').writeAsStringSync(jsonEncode(
          <String, String>{'@@locale': 'de', 'k': 'v', 'added': 'Neu'}));
      arb('app_en.arb', 'en');
      final ({ManagementClient client, List<String> imports}) t =
          _germanProject(others: <String>['en'], translateScope: false);
      final OpResult r = await _ops(t.client).adoptArbs(template);
      expect(r.ok, isTrue);
      expect(t.imports, <String>['de all', 'en']);
      expect(r.message, contains('so the base text is still in en'));
    });

    test('with no local translations it is one import that translates',
        () async {
      final ({ManagementClient client, List<String> imports}) t =
          _germanProject(others: <String>['en', 'fr']);
      final OpResult r = await _ops(t.client).adoptArbs(template);
      expect(r.ok, isTrue);
      expect(t.imports, <String>['de all +translate']);
    });

    test('a token without the Translate scope imports and says what is left',
        () async {
      arb('app_en.arb', 'en');
      final ({ManagementClient client, List<String> imports}) t =
          _germanProject(others: <String>['en', 'fr'], translateScope: false);
      final OpResult r = await _ops(t.client).adoptArbs(template);
      expect(r.ok, isTrue);
      expect(t.imports, <String>['de all', 'en']);
      expect(
          r.message,
          endsWith('Not translated: this token does not have the Translate '
              'scope, so the base text is still in fr. Create a token with the '
              'Translate scope (API keys page in the dashboard), then run '
              '`fl retranslate`.'));
      expect(r.data['untranslated_locales'], <String>['fr']);
    });

    test('the same refusal on the only import falls back to a plain import',
        () async {
      final ({ManagementClient client, List<String> imports}) t =
          _germanProject(translateScope: false);
      final OpResult r = await _ops(t.client).adoptArbs(template);
      expect(r.ok, isTrue);
      expect(t.imports, <String>['de all']);
      expect(r.message, contains('so the base text is still in en'));
    });

    test('any other 403 still fails', () async {
      final ({ManagementClient client, List<String> imports}) t =
          _germanProject(
              translateScope: false,
              refusalBody: 'Plan limit reached: Maximum 100 translation keys.');
      await expectLater(
          _ops(t.client).adoptArbs(template),
          throwsA(isA<ApiException>().having(
              (final ApiException e) => e.statusCode, 'statusCode', 403)));
      expect(t.imports, isEmpty);
    });
  });
}

/// Extracts a multipart form field's value from a raw request body.
String _field(final String body, final String name) {
  final RegExpMatch? m =
      RegExp('name="$name"\\r?\\n\\r?\\n([^\\r\\n]*)').firstMatch(body);
  return m?.group(1)?.trim() ?? '';
}
