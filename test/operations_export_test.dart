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
                <String, dynamic>{
                  'id': 3,
                  'key': 'hello',
                  'value': '你好',
                  'description': 'A greeting.',
                  'placeholders': <String, dynamic>{},
                },
                <String, dynamic>{
                  'id': 4,
                  'key': 'saved',
                  'value': '{count, plural, one{{count} 項} other{{count} 項}}',
                  'is_plural_enabled': true,
                  'description': 'How many saved.',
                  'placeholders': <String, dynamic>{
                    'count': <String, dynamic>{'type': 'num'},
                  },
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

  test('@key metadata lands in every locale, like the backend writes it', () async {
    // Not a style choice: `fl pull` falls back to this writer when the git
    // mirror is unusable, so anything it does differently from the backend
    // shows up as a diff across all 36 files the first time a credential
    // goes stale.
    await _ops().exportArbs(tmp.path);
    final Map<String, dynamic> en = jsonDecode(
        File('${tmp.path}/app_en_US.arb').readAsStringSync()) as Map<String, dynamic>;
    final Map<String, dynamic> zh = jsonDecode(
        File('${tmp.path}/app_zh_Hant.arb').readAsStringSync()) as Map<String, dynamic>;
    expect((en['@saved'] as Map<String, dynamic>)['placeholders'], isNotNull);
    expect(en['@hello'], isNotNull);
    expect((zh['@saved'] as Map<String, dynamic>)['placeholders'], isNotNull);
    expect((zh['@hello'] as Map<String, dynamic>)['description'], 'A greeting.');
  });

  test('every file carries an @@last_modified stamp', () async {
    await _ops().exportArbs(tmp.path);
    for (final String name in <String>['app_en_US.arb', 'app_zh_Hant.arb']) {
      final Map<String, dynamic> arb = jsonDecode(
          File('${tmp.path}/$name').readAsStringSync()) as Map<String, dynamic>;
      expect(arb['@@last_modified'], isA<String>());
      expect(arb['@@last_modified'], endsWith('+00:00'),
          reason: 'the backend writes Python isoformat; this must match');
    }
  });

  test('re-exporting unchanged content leaves the files byte-identical', () async {
    // A fresh timestamp on an otherwise identical file would dirty the ARB
    // repo on every run, which is how a fallback export turns into a
    // 36-file diff that nobody can read.
    await _ops().exportArbs(tmp.path);
    final Map<String, String> first = <String, String>{
      for (final FileSystemEntity f in tmp.listSync())
        (f as File).path: f.readAsStringSync(),
    };
    await _ops().exportArbs(tmp.path);
    for (final MapEntry<String, String> e in first.entries) {
      expect(File(e.key).readAsStringSync(), e.value, reason: e.key);
    }
  });

  test('a changed string gets a fresh stamp', () async {
    await _ops().exportArbs(tmp.path);
    final File en = File('${tmp.path}/app_en_US.arb');
    final Map<String, dynamic> before =
        jsonDecode(en.readAsStringSync()) as Map<String, dynamic>;
    en.writeAsStringSync(jsonEncode(<String, dynamic>{
      ...before,
      'hello': 'Stale value',
    }),);
    await _ops().exportArbs(tmp.path);
    final Map<String, dynamic> after =
        jsonDecode(en.readAsStringSync()) as Map<String, dynamic>;
    expect(after['hello'], 'Hello');
    expect(after['@@last_modified'], isNot(before['@@last_modified']));
  });

  test('a dry run reports the plan and writes nothing', () async {
    final OpResult r = await _ops().exportArbs(tmp.path, dryRun: true);
    expect(r.ok, isTrue);
    expect(r.message, contains('DRY RUN'));
    expect(tmp.listSync(), isEmpty);
  });
}
