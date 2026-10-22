/// Native iOS: String Catalogs through `pull`/`export`/`import`.
///
/// The backend renders the catalog; the CLI's job is to fetch it unchanged,
/// know when a project has one, and never lose a key an iOS developer added
/// in Xcode. These tests pin those three things.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_localisation_cli/src/call_budget.dart';
import 'package:flutter_localisation_cli/src/config.dart';
import 'package:flutter_localisation_cli/src/management_client.dart';
import 'package:flutter_localisation_cli/src/operations.dart';
import 'package:flutter_localisation_cli/src/xcstrings.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Bytes the way the backend serves them: Xcode's ` : ` separator, which a
/// Dart re-encode would silently normalise away.
const String kServedCatalog = '{\n'
    '  "sourceLanguage" : "en",\n'
    '  "strings" : {\n'
    '    "running %lld" : {\n'
    '      "extractionState" : "manual",\n'
    '      "localizations" : {\n'
    '        "en" : {\n'
    '          "stringUnit" : {\n'
    '            "state" : "translated",\n'
    '            "value" : "Cleaning… %lld s left"\n'
    '          }\n'
    '        }\n'
    '      }\n'
    '    }\n'
    '  },\n'
    '  "version" : "1.0"\n'
    '}\n';

const String kEmptyInfoPlist =
    '{\n  "sourceLanguage" : "en",\n  "strings" : {\n\n  },\n  "version" : "1.0"\n}\n';

String _project(final List<String> platforms) => jsonEncode(<String, dynamic>{
      'id': 7,
      'name': 'Gush',
      'platforms': platforms,
      'xcstrings_dir': 'Gush/Resources',
      'flavors': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 3,
          'name': 'Default',
          'languages': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 1,
              'code': 'en',
              'is_base_language': true,
              'translations': <Map<String, dynamic>>[
                <String, dynamic>{
                  'id': 1,
                  'key': 'running %lld',
                  'value': 'Cleaning… {arg1} s left',
                  'placeholders': <String, dynamic>{
                    'arg1': <String, dynamic>{'type': 'int', 'spec': '%lld'},
                  },
                },
              ],
            },
          ],
        },
      ],
    });

/// A JSON response with a charset, so a non-ASCII fixture survives the mock.
http.Response _json(final String body, [final int status = 200]) =>
    http.Response.bytes(
      utf8.encode(body),
      status,
      headers: <String, String>{'content-type': 'application/json; charset=utf-8'},
    );

Operations _ops(final MockClient mock) => Operations(
      ManagementClient(baseUrl: 'http://t', token: 'flk_live_x', httpClient: mock),
      7,
      flavor: 'Default',
      budget: CallBudget.disabled(),
    );

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('fl_xcstrings_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('project model', () {
    test('platforms default to flutter when the backend predates the field', () {
      final ProjectData old = ProjectData.fromJson(<String, dynamic>{
        'id': 1,
        'name': 'Old',
        'flavors': <dynamic>[],
      });
      expect(old.platforms, <String>['flutter']);
      expect(old.shipsFlutter, isTrue);
      expect(old.shipsIos, isFalse);

      final ProjectData ios = ProjectData.fromJson(
          jsonDecode(_project(<String>['ios'])) as Map<String, dynamic>);
      expect(ios.shipsFlutter, isFalse);
      expect(ios.shipsIos, isTrue);
      expect(ios.xcstringsDir, 'Gush/Resources');

      final ProjectSummary summary = ProjectSummary.fromJson(<String, dynamic>{
        'id': 1,
        'name': 'Gush',
        'platforms': <String>['flutter', 'ios'],
      });
      expect(summary.platforms, <String>['flutter', 'ios']);
    });
  });

  group('config', () {
    test('xcstrings_dir resolves against the config file and falls back to arb_dir', () {
      final File cfgFile = File(p.join(tmp.path, 'flutterlocalisation.json'))
        ..writeAsStringSync(jsonEncode(<String, dynamic>{
          'project': 'Gush',
          'xcstrings_dir': 'Gush/Resources',
        }));
      final ProjectConfig cfg = ProjectConfig.load(path: cfgFile.path);
      expect(cfg.xcstringsDir, p.join(tmp.path, 'Gush', 'Resources'));
      expect(cfg.catalogDir, cfg.xcstringsDir);

      cfgFile.writeAsStringSync(jsonEncode(<String, dynamic>{'arb_dir': 'arbs/Default'}));
      final ProjectConfig arbOnly = ProjectConfig.load(path: cfgFile.path);
      expect(arbOnly.xcstringsDir, isNull);
      expect(arbOnly.catalogDir, arbOnly.arbDir);

      cfgFile.writeAsStringSync('{}');
      expect(ProjectConfig.load(path: cfgFile.path).catalogDir, '.');
    });
  });

  group('catalog helpers', () {
    test('a catalog is recognised by shape or by name, an ARB is not', () {
      expect(looksLikeCatalog(kServedCatalog), isTrue);
      expect(looksLikeCatalog('{"strings": {"a": "b"}}'), isFalse,
          reason: 'an ARB may have a key called "strings"');
      expect(looksLikeCatalog('{}', fileName: 'Localizable.xcstrings'), isTrue);
      expect(looksLikeCatalog('not json'), isFalse);
      expect(catalogKeys(jsonDecode(kServedCatalog)), <String>['running %lld']);
    });

    test('localOnlyCatalogKeys names what the service lacks', () {
      final File file = File(p.join(tmp.path, kLocalizableCatalog))
        ..writeAsStringSync(jsonEncode(<String, dynamic>{
          'sourceLanguage': 'en',
          'strings': <String, dynamic>{'known': <String, dynamic>{}, 'new %@': <String, dynamic>{}},
        }));
      expect(localOnlyCatalogKeys(file, <String>{'known'}), <String>['new %@']);
      expect(localOnlyCatalogKeys(File(p.join(tmp.path, 'missing')), <String>{}), isEmpty);
    });
  });

  group('exportCatalogs', () {
    test('writes the served bytes unchanged and skips an empty InfoPlist', () async {
      final List<String> hits = <String>[];
      final MockClient mock = MockClient((final http.Request req) async {
        hits.add('${req.method} ${req.url.path}?${req.url.query}');
        if (req.url.path == '/api/projects/7/') {
          return _json(_project(<String>['ios']));
        }
        final String table = req.url.queryParameters['table'] ?? '';
        return _json(table == 'InfoPlist' ? kEmptyInfoPlist : kServedCatalog);
      });

      final OpResult r = await _ops(mock).exportCatalogs(tmp.path);

      expect(r.ok, isTrue, reason: r.message);
      expect(
        hits.where((final String h) => h.contains('format=xcstrings')).toList(),
        <String>[
          'GET /api/project/7/export/?flavor_id=3&format=xcstrings&table=Localizable',
          'GET /api/project/7/export/?flavor_id=3&format=xcstrings&table=InfoPlist',
        ],
      );
      expect(File(p.join(tmp.path, kLocalizableCatalog)).readAsStringSync(), kServedCatalog);
      expect(File(p.join(tmp.path, kInfoPlistCatalog)).existsSync(), isFalse);
      expect((r.data['files'] as List<dynamic>).length, 1);
    });

    test('writes InfoPlist.xcstrings when the project has Info.plist keys', () async {
      final String plist = kServedCatalog.replaceAll('running %lld', 'NSCameraUsageDescription');
      final MockClient mock = MockClient((final http.Request req) async {
        if (req.url.path == '/api/projects/7/') {
          return _json(_project(<String>['ios']));
        }
        final String table = req.url.queryParameters['table'] ?? '';
        return _json(table == 'InfoPlist' ? plist : kServedCatalog);
      });

      final OpResult r = await _ops(mock).exportCatalogs(tmp.path);

      expect(r.ok, isTrue);
      expect(File(p.join(tmp.path, kInfoPlistCatalog)).readAsStringSync(), plist);
    });

    test('a 422 names the strings the backend could not express', () async {
      final MockClient mock = MockClient((final http.Request req) async {
        if (req.url.path == '/api/projects/7/') {
          return _json(_project(<String>['ios']));
        }
        return http.Response(
          jsonEncode(<String, dynamic>{
            'error': 'Some strings have no String Catalog equivalent.',
            'details': <String>["key 'gender' in en: `select` has no String Catalog equivalent"],
          }),
          422,
        );
      });

      final OpResult r = await _ops(mock).exportCatalogs(tmp.path);

      expect(r.ok, isFalse);
      expect(r.message, contains('gender'));
      expect(File(p.join(tmp.path, kLocalizableCatalog)).existsSync(), isFalse);
    });

    test('dry run touches nothing', () async {
      final MockClient mock = MockClient((final http.Request req) async {
        if (req.url.path == '/api/projects/7/') {
          return _json(_project(<String>['ios']));
        }
        return _json(kServedCatalog);
      });
      final OpResult r = await _ops(mock).exportCatalogs(tmp.path, dryRun: true);
      expect(r.ok, isTrue);
      expect(r.message, startsWith('DRY RUN'));
      expect(tmp.listSync(), isEmpty);
    });
  });

  group('importArb with a String Catalog', () {
    test('sends no language, keeps the file name and reports locales and problems', () async {
      String? body;
      String? sentPath;
      final MockClient mock = MockClient((final http.Request req) async {
        if (req.url.path == '/api/projects/7/') {
          return _json(_project(<String>['ios']));
        }
        sentPath = req.url.path;
        body = req.body;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'import_status': 'success',
            'import': <String, dynamic>{
              'keys': <String, int>{'total': 2, 'written': 2, 'skipped': 0, 'unchanged': 0},
              'rows': <String, int>{},
              'skipped_keys': <String>[],
              'locales': <String>['en', 'fr'],
              'problems': <String>['skip_me: marked as not to translate; skipped'],
            },
          }),
          200,
        );
      });

      final OpResult r = await _ops(mock).importArb(
        kServedCatalog,
        fileName: 'Localizable.xcstrings',
      );

      expect(r.ok, isTrue, reason: r.message);
      expect(sentPath, '/api/project/7/import-arb/');
      expect(body, isNot(contains('name="selected_language_code"')));
      expect(body, contains('filename="Localizable.xcstrings"'));
      expect(body, contains('"sourceLanguage" : "en"'),
          reason: 'the catalog is uploaded as is');
      expect(r.data['locales'], <String>['en', 'fr']);
      expect(r.data['problems'], hasLength(1));
      expect(r.message, contains('locales: en, fr'));
      expect(r.message, contains('skip_me'));
    });

    test('a catalog is recognised by content when it has no file name', () async {
      String? body;
      final MockClient mock = MockClient((final http.Request req) async {
        if (req.url.path == '/api/projects/7/') {
          return _json(_project(<String>['ios']));
        }
        body = req.body;
        return http.Response(jsonEncode(<String, dynamic>{'import_status': 'success'}), 200);
      });

      final OpResult r = await _ops(mock).importArb(kServedCatalog);

      expect(r.ok, isTrue);
      expect(body, isNot(contains('name="selected_language_code"')));
      expect(body, contains('filename="Localizable.xcstrings"'));
    });

    test('the dry run counts catalog keys, not top-level JSON keys', () async {
      final MockClient mock = MockClient((final http.Request req) async =>
          _json(_project(<String>['ios'])));
      final OpResult r = await _ops(mock).importArb(kServedCatalog, dryRun: true);
      expect(r.data['keys'], 1);
      expect(r.data['format'], 'xcstrings');
      expect(r.data.containsKey('language'), isFalse);
    });

    test('an ARB still goes through with its language', () async {
      String? body;
      final MockClient mock = MockClient((final http.Request req) async {
        if (req.url.path == '/api/projects/7/') {
          return _json(_project(<String>['flutter']));
        }
        body = req.body;
        return http.Response(jsonEncode(<String, dynamic>{'import_status': 'success'}), 200);
      });
      await _ops(mock).importArb('{"@@locale": "en", "k": "v"}', fileName: 'app_en.arb');
      expect(body, contains('name="selected_language_code"'));
      expect(body, contains('filename="app_en.arb"'));
    });
  });
}
