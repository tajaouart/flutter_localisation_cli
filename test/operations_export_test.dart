/// `fl export` — ARBs straight from the API.
///
/// Cover for the case that stranded a fully-translated project: the dashboard's
/// git provider pointed at a repository that did not exist, so `clone`/`pull`
/// both failed and 36 finished locales had no way to reach the app.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_localisation_cli/src/call_budget.dart';
import 'package:flutter_localisation_cli/src/management_client.dart';
import 'package:flutter_localisation_cli/src/operations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

String _project() => jsonEncode(<String, dynamic>{
      'id': 7,
      'name': 'P',
      'flavors': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 3,
          'name': 'default',
          'languages': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 1,
              'code': 'en-US',
              'is_base_language': true,
              'translations': <Map<String, dynamic>>[
                <String, dynamic>{
                  'id': 1,
                  'key': 'hello',
                  'value': 'Hello',
                  'description': 'A greeting.',
                  'placeholders': <String, dynamic>{},
                },
                <String, dynamic>{
                  'id': 2,
                  'key': 'saved',
                  'value': '{count, plural, one{{count} item} other{{count} items}}',
                  'is_plural_enabled': true,
                  'description': 'How many saved.',
                  'placeholders': <String, dynamic>{
                    'count': <String, dynamic>{'type': 'num'},
                  },
                },
              ],
            },
            <String, dynamic>{
              'id': 2,
              'code': 'zh-Hant',
              'is_base_language': false,
              'translations': <Map<String, dynamic>>[
                <String, dynamic>{'id': 3, 'key': 'hello', 'value': '你好'},
                <String, dynamic>{
                  'id': 4,
                  'key': 'saved',
                  'value': '{count, plural, one{{count} 項} other{{count} 項}}',
                  'is_plural_enabled': true,
                },
              ],
            },
          ],
        },
      ],
    });

Operations _ops() {
  final MockClient mock = MockClient(
      (final http.Request req) async => http.Response(
            _project(),
            200,
            // Without the charset, http decodes the body as latin-1 and every
            // non-ASCII translation in the fixture becomes mojibake.
            headers: <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          ));
  return Operations(
      ManagementClient(baseUrl: 'http://t', token: 'x', httpClient: mock), 7,
      flavor: 'default', budget: CallBudget.disabled());
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('fl_export_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('writes one ARB per locale, named the way gen_l10n expects', () async {
    final OpResult r = await _ops().exportArbs(tmp.path);
    expect(r.ok, isTrue);
    // Underscores, not hyphens: gen_l10n does not recognise `app_zh-Hant.arb`.
    expect(File('${tmp.path}/app_en_US.arb').existsSync(), isTrue);
    expect(File('${tmp.path}/app_zh_Hant.arb').existsSync(), isTrue);
    expect(r.data['template'], 'app_en_US.arb');
  });

  test('every file carries @@locale so the locale is never guessed', () async {
    await _ops().exportArbs(tmp.path);
    final Map<String, dynamic> zh = jsonDecode(
        File('${tmp.path}/app_zh_Hant.arb').readAsStringSync()) as Map<String, dynamic>;
    // Underscores in both the name and @@locale: gen_l10n compares them and
    // fails the build when they disagree.
    expect(zh['@@locale'], 'zh_Hant');
    expect(zh['hello'], '你好');
  });

  test('plural values keep their assembled ICU', () async {
    await _ops().exportArbs(tmp.path);
    final Map<String, dynamic> en = jsonDecode(
        File('${tmp.path}/app_en_US.arb').readAsStringSync()) as Map<String, dynamic>;
    expect(en['saved'], contains('plural'));
    expect(en['saved'], contains('other{'));
  });

  test('@key metadata goes in the template only', () async {
    // gen_l10n reads it from the template; 35 copies in the translated files
    // would be 35 things to drift.
    await _ops().exportArbs(tmp.path);
    final Map<String, dynamic> en = jsonDecode(
        File('${tmp.path}/app_en_US.arb').readAsStringSync()) as Map<String, dynamic>;
    final Map<String, dynamic> zh = jsonDecode(
        File('${tmp.path}/app_zh_Hant.arb').readAsStringSync()) as Map<String, dynamic>;
    expect((en['@saved'] as Map<String, dynamic>)['placeholders'], isNotNull);
    expect(en['@hello'], isNotNull);
    expect(zh.containsKey('@saved'), isFalse);
    expect(zh.containsKey('@hello'), isFalse);
  });

  test('a dry run reports the plan and writes nothing', () async {
    final OpResult r = await _ops().exportArbs(tmp.path, dryRun: true);
    expect(r.ok, isTrue);
    expect(r.message, contains('DRY RUN'));
    expect(tmp.listSync(), isEmpty);
  });
}
