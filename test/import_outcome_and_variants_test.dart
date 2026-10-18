import 'dart:convert';
import 'dart:io';

import 'package:flutter_localisation_cli/src/call_budget.dart';
import 'package:flutter_localisation_cli/src/exceptions.dart';
import 'package:flutter_localisation_cli/src/locales.dart';
import 'package:flutter_localisation_cli/src/management_client.dart';
import 'package:flutter_localisation_cli/src/operations.dart';
import 'package:flutter_localisation_cli/src/project_resolver.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

Map<String, dynamic> _row(
  final int id,
  final String key,
  final String value, {
  final bool checked = false,
  final Map<String, dynamic> placeholders = const <String, dynamic>{},
}) =>
    <String, dynamic>{
      'id': id,
      'key': key,
      'value': value,
      'is_checked': checked,
      'placeholders': placeholders,
    };

Map<String, dynamic> _lang(
  final String code,
  final List<Map<String, dynamic>> rows, {
  final bool base = false,
}) =>
    <String, dynamic>{
      'id': code.hashCode,
      'code': code,
      'is_base_language': base,
      'translations': rows,
    };

/// A project whose base is `en`, plus [others].
Operations _ops(
  final List<Map<String, dynamic>> others, {
  final List<Map<String, dynamic>>? base,
  final Map<String, dynamic>? importResponse,
  final List<String>? hits,
}) {
  final MockClient mock = MockClient((final http.Request req) async {
    hits?.add('${req.method} ${req.url.path}');
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
                _lang(
                  'en',
                  base ??
                      <Map<String, dynamic>>[
                        _row(1, 'save', 'Save'),
                        _row(2, 'count', '{count}'),
                      ],
                  base: true,
                ),
                ...others,
              ],
            },
          ],
        }),
        200,
      );
    }
    if (req.url.path == '/api/project/7/import-arb/') {
      return http.Response(
        jsonEncode(importResponse ?? <String, dynamic>{'import_status': 'success'}),
        200,
      );
    }
    return http.Response('{}', 200);
  });
  return Operations(
    ManagementClient(baseUrl: 'http://t', token: 'x', httpClient: mock),
    7,
    flavor: 'default',
    budget: CallBudget.disabled(),
  );
}

Map<String, dynamic> _summary({
  required final int written,
  required final int skipped,
  required final int unchanged,
  final List<String> skippedKeys = const <String>[],
}) =>
    <String, dynamic>{
      'import_status': 'success',
      'import': <String, dynamic>{
        'keys': <String, dynamic>{
          'total': written + skipped + unchanged,
          'written': written,
          'skipped': skipped,
          'unchanged': unchanged,
        },
        'rows': <String, dynamic>{},
        'skipped_keys': skippedKeys,
      },
    };

Map<String, dynamic> _statusRow(final OpResult r, final String locale) =>
    (r.data['locales'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .firstWhere((final Map<String, dynamic> m) => m['locale'] == locale);

void main() {
  final String threeKeys =
      jsonEncode(<String, dynamic>{'a': 'A', 'b': 'B', 'c': 'C'});

  group('import reports what the server actually wrote', () {
    test('an import that skipped everything says nothing was written', () async {
      final OpResult r = await _ops(
        const <Map<String, dynamic>>[],
        importResponse: _summary(
            written: 0, skipped: 3, unchanged: 0, skippedKeys: <String>['a', 'b', 'c']),
      ).importArb(threeKeys, languageCode: 'fr');

      expect(r.message, startsWith('Nothing written: 3 of 3 key(s) skipped'));
      expect(r.message, contains('--overwrite'));
      expect(r.message, contains('(a, b, c)'));
      expect(r.data['written'], 0);
      expect(r.data['skipped'], 3);
      expect(r.data['skipped_keys'], <String>['a', 'b', 'c']);
      expect(r.data['imported'], 3);
    });

    test('a partial skip names the count and the remedy', () async {
      final OpResult r = await _ops(
        const <Map<String, dynamic>>[],
        importResponse: _summary(written: 1, skipped: 2, unchanged: 0),
      ).importArb(threeKeys, languageCode: 'fr');

      expect(r.message, contains('Imported 3 key(s) (1 written, 2 skipped)'));
      expect(r.message, contains('2 key(s) already hold a different value'));
    });

    test('a clean import carries no hint', () async {
      final OpResult r = await _ops(
        const <Map<String, dynamic>>[],
        importResponse: _summary(written: 2, skipped: 0, unchanged: 1),
      ).importArb(threeKeys);

      expect(r.message,
          'Imported 3 key(s) (2 written, 1 already identical) into "default".');
    });

    test('an older backend without the summary keeps the old wording', () async {
      final OpResult r =
          await _ops(const <Map<String, dynamic>>[]).importArb(threeKeys);

      expect(r.message, 'Imported 3 key(s) into "default".');
      expect(r.data.containsKey('written'), isFalse);
    });

    test('more than five skipped keys are elided', () async {
      final OpResult r = await _ops(
        const <Map<String, dynamic>>[],
        importResponse: _summary(
          written: 0,
          skipped: 7,
          unchanged: 0,
          skippedKeys: <String>['k1', 'k2', 'k3', 'k4', 'k5', 'k6', 'k7'],
        ),
      ).importArb(threeKeys, languageCode: 'fr');

      expect(r.message, contains('(k1, k2, k3, k4, k5, ...)'));
    });
  });

  group('status', () {
    test('a variant of the base that reads the same is finished', () async {
      final OpResult r = await _ops(<Map<String, dynamic>>[
        _lang('en-GB', <Map<String, dynamic>>[
          _row(10, 'save', 'Save'),
          _row(11, 'count', '{count}'),
        ]),
      ]).status();

      final Map<String, dynamic> gb = _statusRow(r, 'en-GB');
      expect(gb['untranslated'], 0);
      expect(gb['translated_percent'], 100);
      expect(gb['variant_of'], 'en');
    });

    test('another language that reads the same is still flagged', () async {
      final OpResult r = await _ops(<Map<String, dynamic>>[
        _lang('fr', <Map<String, dynamic>>[
          _row(20, 'save', 'Save'),
          _row(21, 'count', '{count}'),
        ]),
      ]).status();

      final Map<String, dynamic> fr = _statusRow(r, 'fr');
      // `save` is untranslated; `{count}` has no words to translate.
      expect(fr['untranslated'], 1);
      expect(fr['translated'], 1);
      expect(fr.containsKey('variant_of'), isFalse);
    });

    test('an empty row in a variant is still missing', () async {
      final OpResult r = await _ops(<Map<String, dynamic>>[
        _lang('en-US', <Map<String, dynamic>>[
          _row(30, 'save', ''),
          _row(31, 'count', '{count}'),
        ]),
      ]).status();

      expect(_statusRow(r, 'en-US')['translated'], 1);
    });
  });

  group('retranslate', () {
    final List<Map<String, dynamic>> locales = <Map<String, dynamic>>[
      _lang('en-GB', <Map<String, dynamic>>[
        _row(10, 'save', 'Save'),
        _row(11, 'count', ''),
      ]),
      _lang('fr', <Map<String, dynamic>>[
        _row(20, 'save', 'Save'),
        _row(21, 'count', '{count}'),
      ]),
    ];

    test('skips identical values in variants and wordless values', () async {
      final OpResult r = await _ops(locales).retranslate(dryRun: true);

      // en-GB: only the empty row. fr: `save`, not `{count}`.
      expect(r.data['per_locale'], <String, int>{'en-GB': 1, 'fr': 1});
    });

    test('includeVariants sends the variant rows too', () async {
      final OpResult r =
          await _ops(locales).retranslate(dryRun: true, includeVariants: true);

      expect(r.data['per_locale'], <String, int>{'en-GB': 2, 'fr': 1});
    });

    test('a variant named explicitly is worked on', () async {
      final OpResult r = await _ops(locales)
          .retranslate(dryRun: true, locales: <String>['en-GB']);

      expect(r.data['per_locale'], <String, int>{'en-GB': 2});
    });
  });

  group('export', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('fl_types_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('a translated locale is typed as the base types it', () async {
      final Operations ops = _ops(
        <Map<String, dynamic>>[
          _lang('fr', <Map<String, dynamic>>[
            _row(20, 'mins', '{minutes} mn {who}', placeholders: <String, dynamic>{
              'minutes': <String, dynamic>{'type': 'String'},
              'who': <String, dynamic>{'type': 'String'},
            }),
          ]),
        ],
        base: <Map<String, dynamic>>[
          _row(1, 'mins', '{minutes} min', placeholders: <String, dynamic>{
            'minutes': <String, dynamic>{'type': 'int', 'format': 'compact'},
          }),
        ],
      );

      await ops.exportArbs(tmp.path);

      final Map<String, dynamic> fr = jsonDecode(
              File('${tmp.path}/app_fr.arb').readAsStringSync())
          as Map<String, dynamic>;
      expect(
        (fr['@mins'] as Map<String, dynamic>)['placeholders'],
        <String, dynamic>{
          'minutes': <String, dynamic>{'type': 'int', 'format': 'compact'},
          'who': <String, dynamic>{'type': 'String'},
        },
      );
      final Map<String, dynamic> en = jsonDecode(
              File('${tmp.path}/app_en.arb').readAsStringSync())
          as Map<String, dynamic>;
      expect(
        (en['@mins'] as Map<String, dynamic>)['placeholders'],
        <String, dynamic>{
          'minutes': <String, dynamic>{'type': 'int', 'format': 'compact'},
        },
      );
    });
  });

  group('resolver', () {
    ProjectResolver resolver(final List<Map<String, dynamic>> projects) {
      final MockClient mock = MockClient((final http.Request req) async =>
          http.Response(jsonEncode(<String, dynamic>{'projects': projects}), 200));
      return ProjectResolver(
          ManagementClient(baseUrl: 'http://t', token: 'x', httpClient: mock));
    }

    test('a missing project names the workspace the token searched', () async {
      await expectLater(
        resolver(<Map<String, dynamic>>[
          <String, dynamic>{
            'id': 1,
            'name': 'ORSY Cockpit',
            'workspace': 'ORSY',
            'flavors': <dynamic>[],
          },
        ]).resolve(project: 'EchoVoice'),
        throwsA(isA<ResolveException>().having(
          (final ResolveException e) => e.toString(),
          'message',
          allOf(
            contains('not found in workspace "ORSY"'),
            contains('Available: ORSY Cockpit'),
            contains('token from that workspace'),
          ),
        )),
      );
    });

    test('an empty workspace still explains the token scope', () async {
      await expectLater(
        resolver(<Map<String, dynamic>>[]).resolve(project: 'EchoVoice'),
        throwsA(isA<ResolveException>().having(
          (final ResolveException e) => e.toString(),
          'message',
          contains('only reaches the workspace it was created in'),
        )),
      );
    });
  });

  group('locale helpers', () {
    test('isVariantOf', () {
      expect(isVariantOf('en-GB', 'en'), isTrue);
      expect(isVariantOf('en_us', 'en'), isTrue);
      expect(isVariantOf('fr-CA', 'fr-FR'), isTrue);
      expect(isVariantOf('en', 'en'), isFalse);
      expect(isVariantOf('en-GB', 'en-gb'), isFalse);
      expect(isVariantOf('fr', 'en'), isFalse);
    });

    test('hasTranslatableText', () {
      expect(hasTranslatableText('Save'), isTrue);
      expect(hasTranslatableText('OK'), isTrue);
      expect(hasTranslatableText('{count} files'), isTrue);
      expect(hasTranslatableText('保存'), isTrue);
      expect(hasTranslatableText('{count}'), isFalse);
      expect(hasTranslatableText('{a} / {b}'), isFalse);
      expect(hasTranslatableText('100%'), isFalse);
    });
  });
}
