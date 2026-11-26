/// `fl` on an iOS app whose strings are spread over a target folder, named
/// tables (`Posts.xcstrings`, read with `tableName:`) and InfoPlist: one flat
/// key set on the service, each file given back the keys it declares.
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_localisation_cli/src/xcstrings.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fake_backend.dart';

class Run {
  Run(this.code, this.out, this.err);

  final int code;
  final String out;
  final String err;

  Map<String, dynamic> get json {
    final int start = out.indexOf('{');
    return jsonDecode(out.substring(start)) as Map<String, dynamic>;
  }
}

void main() {
  late FakeBackend backend;
  late Directory tmp;

  Future<Run> fl(final List<String> args) async {
    final ProcessResult r = await Process.run(
      'dart',
      <String>['run', p.join(packageRoot(), 'bin', 'fl.dart'), ...args],
      workingDirectory: tmp.path,
      environment: <String, String>{
        'FL_API_TOKEN': 'flk_live_test',
        'HOME': tmp.path,
      },
    );
    return Run(r.exitCode, r.stdout as String, r.stderr as String);
  }

  Map<String, dynamic> unit(final String value) => <String, dynamic>{
        'stringUnit': <String, String>{'state': 'translated', 'value': value},
      };
  Map<String, dynamic> entry(final String en, [final String? fr]) =>
      <String, dynamic>{
        'localizations': <String, dynamic>{
          'en': unit(en),
          if (fr != null) 'fr': unit(fr),
        },
      };
  String catalogOf(final Map<String, dynamic> strings) =>
      jsonEncode(<String, dynamic>{
        'sourceLanguage': 'en',
        'strings': strings,
        'version': '1.0',
      });
  File file(final String rel) => File(p.join(tmp.path, rel));
  Map<String, dynamic> stringsOf(final String rel) =>
      (jsonDecode(file(rel).readAsStringSync())
          as Map<String, dynamic>)['strings'] as Map<String, dynamic>;
  void write(final String rel, final Map<String, dynamic> strings) => file(rel)
    ..createSync(recursive: true)
    ..writeAsStringSync(catalogOf(strings));

  const String app = 'App/Resources/Localizable.xcstrings';
  const String posts = 'App/Posts/Posts.xcstrings';
  const String brand = 'App/Brand/Brand.xcstrings';
  const String plist = 'App/Resources/InfoPlist.xcstrings';
  const List<String> allKeys = <String>[
    'home.title',
    'shared.ok',
    'posts.title',
    'posts.empty',
    'brand.name',
  ];

  setUpAll(() async => backend = await FakeBackend.start());
  tearDownAll(() => backend.close());

  setUp(() {
    backend
      ..platforms = <String>['ios']
      ..imports.clear()
      ..extraKeys = <String>[]
      ..appShortcuts = null
      ..infoPlist = catalogOf(<String, dynamic>{
        'NSCameraUsageDescription': entry('To film', 'Pour filmer'),
      })
      ..servedCatalog = catalogOf(<String, dynamic>{
        'home.title': entry('Home', 'Accueil'),
        'shared.ok': entry('OK', "D'accord"),
        'posts.title': entry('Posts', 'Publications'),
        'posts.empty': entry('No post yet', 'Aucune publication'),
        'brand.name': entry('Brand', 'Marque'),
        'gone.key': entry('Gone', 'Parti'),
      });
    tmp = Directory(Directory.systemTemp
        .createTempSync('fl_cli_tables_test')
        .resolveSymbolicLinksSync());
    write(app, <String, dynamic>{
      'home.title': entry('Home'),
      'shared.ok': entry('OK'),
    });
    write(plist, <String, dynamic>{
      'NSCameraUsageDescription': entry('To film'),
    });
    write(posts, <String, dynamic>{
      'posts.title': entry('Posts'),
      'posts.empty': entry('No post yet'),
      'shared.ok': entry('OK'),
    });
    write(brand, <String, dynamic>{'brand.name': entry('Brand')});
    file('flutterlocalisation.json').writeAsStringSync(jsonEncode(
      <String, Object>{
        'base_url': backend.url,
        'project': 'Gush',
        'xcstrings_catalogs': <String>['App/Resources', posts, brand],
      },
    ));
  });
  tearDown(() {
    backend
      ..extraKeys = <String>[]
      ..servedCatalog = null
      ..infoPlist = null;
    tmp.deleteSync(recursive: true);
  });

  void conflict() => write(posts, <String, dynamic>{
        'posts.title': entry('Posts'),
        'shared.ok': entry('Okay'),
      });

  test('round trip: adopt sends each key once, pull cuts it back', () async {
    final Run adopt = await fl(<String>['pull', '--adopt']);
    expect(adopt.code, 0, reason: adopt.err);
    final ReceivedImport sent = backend.imports.single;
    expect(sent.fileName, kLocalizableCatalog);
    for (final String key in allKeys) {
      expect(
          RegExp(RegExp.escape('"$key"')).allMatches(sent.body), hasLength(1),
          reason: '$key goes up once');
    }

    backend.extraKeys = allKeys;
    final Run pull = await fl(<String>['pull']);
    expect(pull.code, 0, reason: pull.err);
    expect(stringsOf(app).keys, <String>['home.title', 'shared.ok']);
    expect(stringsOf(posts).keys,
        <String>['posts.empty', 'posts.title', 'shared.ok']);
    expect(stringsOf(brand).keys, <String>['brand.name']);
    expect(stringsOf(app)['shared.ok'], entry('OK', "D'accord"));
    expect(stringsOf(posts)['shared.ok'], entry('OK', "D'accord"),
        reason: 'a shared key is written to every file declaring it');
    expect(stringsOf(posts)['posts.title'], entry('Posts', 'Publications'));
    expect(stringsOf(plist), <String, dynamic>{
      'NSCameraUsageDescription': entry('To film', 'Pour filmer'),
    });
    expect(
      file(posts).readAsStringSync(),
      startsWith('{\n  "sourceLanguage" : "en",\n  "strings" : {\n'
          '    "posts.empty" : {\n      "localizations" : {\n'),
      reason: 'Xcode\'s own formatting',
    );
    expect(
        file(posts).readAsStringSync(), endsWith('  "version" : "1.0"\n}\n'));
    expect(pull.out, contains('1 key(s) on the service are in none'));
    expect(pull.out, contains('gone.key'));

    final List<String> before = <String>[
      for (final String f in <String>[app, posts, brand, plist])
        file(f).readAsStringSync(),
    ];
    expect((await fl(<String>['pull'])).code, 0);
    expect(<String>[
      for (final String f in <String>[app, posts, brand, plist])
        file(f).readAsStringSync(),
    ], before, reason: 'a second pull changes no byte');
  });

  test('export writes each file with only its keys, a dry run lists them',
      () async {
    backend.extraKeys = allKeys;
    final String untouched = file(posts).readAsStringSync();
    final Run dry = await fl(<String>['export', '--dry-run']);
    expect(dry.code, 0, reason: dry.err);
    expect(dry.out, contains('DRY RUN: would write'));
    expect(dry.out,
        contains('${p.join('App', 'Posts', 'Posts.xcstrings')}  3 key(s)'));
    expect(dry.out,
        contains('${p.join('App', 'Brand', 'Brand.xcstrings')}  1 key(s)'));
    expect(
        dry.out,
        contains(
            '${p.join('App', 'Resources', 'Localizable.xcstrings')}  2 key(s)'));
    expect(file(posts).readAsStringSync(), untouched);

    final Run pullDry = await fl(<String>['pull', '--dry-run']);
    expect(pullDry.code, 0, reason: pullDry.err);
    expect(pullDry.out,
        contains('${p.join('App', 'Posts', 'Posts.xcstrings')}  3 key(s)'));

    final Run r = await fl(<String>['export']);
    expect(r.code, 0, reason: r.err);
    expect(stringsOf(brand), <String, dynamic>{
      'brand.name': entry('Brand', 'Marque'),
    });
    expect(stringsOf(posts).keys,
        <String>['posts.empty', 'posts.title', 'shared.ok']);
  });

  test('a key with two texts stops every command before anything is sent',
      () async {
    conflict();
    final String postsBefore = file(posts).readAsStringSync();
    final String appBefore = file(app).readAsStringSync();
    final String sharedFiles =
        'shared.ok: ${p.join('App', 'Resources', 'Localizable.xcstrings')}, '
        '${p.join('App', 'Posts', 'Posts.xcstrings')} (en)';
    for (final List<String> args in <List<String>>[
      <String>['pull'],
      <String>['pull', '--adopt'],
      <String>['export'],
      <String>['import', posts],
      <String>['diff'],
      <String>['diff', posts],
    ]) {
      final Run r = await fl(args);
      expect(r.code, 1, reason: '$args');
      expect('${r.out}${r.err}', contains(sharedFiles), reason: '$args');
      expect('${r.out}${r.err}', contains('Rename the key in one table'),
          reason: '$args');
    }
    expect(backend.imports, isEmpty);
    expect(file(posts).readAsStringSync(), postsBefore);
    expect(file(app).readAsStringSync(), appBefore);

    final Run json = await fl(<String>['pull', '--adopt', '--json']);
    expect(json.json['error'], 'catalog_conflicts');
    expect(
        (json.json['conflicts'] as List<dynamic>).single['key'], 'shared.ok');

    final Run status = await fl(<String>['status']);
    expect(status.code, 0, reason: status.err);
    expect(status.out, contains(sharedFiles));

    final Run brandOnly = await fl(<String>['import', brand, '--dry-run']);
    expect(brandOnly.code, 0,
        reason: 'a file with none of the keys in conflict: ${brandOnly.out}');
  });

  test('pull --discard-local takes the service text into both files', () async {
    conflict();
    backend.extraKeys = allKeys;
    final Run r = await fl(<String>['pull', '--discard-local']);
    expect(r.code, 0, reason: r.err);
    expect(stringsOf(posts)['shared.ok'], entry('OK', "D'accord"));
  });

  test('import of a named table goes into the Localizable table', () async {
    final Run r = await fl(<String>['import', posts]);
    expect(r.code, 0, reason: '${r.out}${r.err}');
    final ReceivedImport sent = backend.imports.single;
    expect(sent.fileName, kLocalizableCatalog);
    expect(sent.body, contains('posts.empty'));
  });

  test('diff and status go through every listed file', () async {
    backend.extraKeys = <String>['home.title', 'shared.ok', 'posts.title'];
    backend.servedCatalog = catalogOf(<String, dynamic>{
      'home.title': entry('Home'),
      'shared.ok': entry('OK'),
      'posts.title': entry('Posts (old)'),
      'gone.key': entry('Gone'),
    });
    final Run d = await fl(<String>['diff']);
    expect(d.code, 0, reason: '${d.out}${d.err}');
    expect(d.out,
        contains('${p.join('App', 'Posts', 'Posts.xcstrings')}: 3 key(s)'));
    expect(d.out, contains('1 new, not on the service yet: posts.empty'));
    expect(d.out, contains('1 different: posts.title (en)'));
    expect(d.out,
        contains('${p.join('App', 'Brand', 'Brand.xcstrings')}: 1 key(s)'));
    expect(
        d.out,
        contains('1 on the service are in none of these catalogs: '
            'gone.key'));

    final Run one = await fl(<String>['diff', brand, '--json']);
    expect(one.code, 0, reason: one.out);
    expect((one.json['files'] as List<dynamic>).single['added'],
        <String>['brand.name']);

    final Run s = await fl(<String>['status']);
    expect(s.code, 0, reason: s.err);
    expect(s.out, contains('String Catalogs:'));
    expect(
        s.out,
        contains('${p.join('App', 'Posts', 'Posts.xcstrings')}: 3 key(s), '
            '1 not on the service yet'));
    expect(
        s.out,
        contains(
            '${p.join('App', 'Resources', 'Localizable.xcstrings')}: 2 key(s)\n'));
  });

  test('init --yes lists every catalog in xcstrings_catalogs', () async {
    file('flutterlocalisation.json').deleteSync();
    backend.extraKeys = allKeys;
    final Run r =
        await fl(<String>['init', '--yes', '--base-url', backend.url]);
    expect(r.code, 0, reason: '${r.out}\n${r.err}');
    final Map<String, dynamic> cfg =
        jsonDecode(file('flutterlocalisation.json').readAsStringSync())
            as Map<String, dynamic>;
    expect(cfg['xcstrings_catalogs'], <String>[
      p.join('App', 'Resources'),
      p.join('App', 'Brand', 'Brand.xcstrings'),
      p.join('App', 'Posts', 'Posts.xcstrings'),
    ]);
    expect(cfg.containsKey('xcstrings_dir'), isFalse);
    expect(stringsOf(brand)['brand.name'], entry('Brand', 'Marque'),
        reason: 'the first pull ran');
  });
}
