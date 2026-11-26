/// One project shipping to a website and an iPhone app, each in its own
/// repository: every repository gets the files of its own platform only.
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fake_backend.dart';
import 'fl_mcp_test.dart' show McpProcess;

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
  late Directory web;
  late Directory app;

  Future<Run> fl(final Directory repo, final List<String> args) async {
    final ProcessResult r = await Process.run(
      'dart',
      <String>['run', p.join(packageRoot(), 'bin', 'fl.dart'), ...args],
      workingDirectory: repo.path,
      environment: <String, String>{
        'FL_API_TOKEN': 'flk_live_test',
        'HOME': repo.path,
      },
    );
    return Run(r.exitCode, r.stdout as String, r.stderr as String);
  }

  File at(final Directory repo, final String rel) =>
      File(p.join(repo.path, rel));

  void writeConfig(final Directory repo, final Map<String, Object> extra) =>
      at(repo, 'flutterlocalisation.json')
          .writeAsStringSync(jsonEncode(<String, Object>{
        'base_url': backend.url,
        'project': 'Gush',
        ...extra,
      }));

  List<String> filesIn(final Directory repo) => <String>[
        for (final FileSystemEntity e in repo.listSync(recursive: true))
          if (e is File &&
              (e.path.endsWith('.xcstrings') || e.path.endsWith('.arb')))
            p.relative(e.path, from: repo.path),
      ]..sort();

  Directory temp(final String name) => Directory(
      Directory.systemTemp.createTempSync(name).resolveSymbolicLinksSync());

  setUpAll(() async => backend = await FakeBackend.start());
  tearDownAll(() => backend.close());

  setUp(() {
    backend.platforms = <String>['angular', 'ios'];
    backend.languages = <String>['en', 'fr'];
    backend.extraKeys = <String>[];
    backend.imports.clear();

    // The website: Angular with @angular/localize.
    web = temp('fl_repo_web');
    at(web, 'angular.json').writeAsStringSync(jsonEncode(<String, dynamic>{
      'version': 1,
      'projects': <String, dynamic>{
        'site': <String, dynamic>{'projectType': 'application', 'root': ''},
      },
    }));
    at(web, 'package.json').writeAsStringSync(jsonEncode(<String, dynamic>{
      'dependencies': <String, String>{'@angular/localize': '^17.3.12'},
    }));
    writeConfig(web, <String, Object>{'angular_dir': 'src/locale'});

    // The iPhone app: an Xcode project and its catalog folder.
    app = temp('fl_repo_app');
    Directory(p.join(app.path, 'App.xcodeproj')).createSync();
    Directory(p.join(app.path, 'App', 'Resources')).createSync(recursive: true);
    writeConfig(app, <String, Object>{'xcstrings_dir': 'App/Resources'});
  });

  tearDown(() {
    web.deleteSync(recursive: true);
    app.deleteSync(recursive: true);
  });

  test('pull in the website repository writes the Angular files only',
      () async {
    final Run r = await fl(web, <String>['pull']);
    expect(r.code, 0, reason: r.err);
    expect(filesIn(web), <String>[p.join('src', 'locale', 'messages.fr.arb')]);
    expect(r.err, contains('angular.json with @angular/localize'));
    expect(r.err, contains('"platforms": ["angular"]'));
  });

  test('pull in the app repository writes the String Catalog only', () async {
    final Run r = await fl(app, <String>['pull']);
    expect(r.code, 0, reason: r.err);
    expect(filesIn(app),
        <String>[p.join('App', 'Resources', 'Localizable.xcstrings')]);
    expect(r.err, contains('App.xcodeproj'));
    expect(r.err, contains('"platforms": ["ios"]'));
  });

  test('export follows the same platforms', () async {
    final Run r = await fl(app, <String>['export', '--json']);
    expect(r.code, 0, reason: r.err);
    expect(r.json.containsKey('angular_dir'), isFalse);
    expect(filesIn(app),
        <String>[p.join('App', 'Resources', 'Localizable.xcstrings')]);
  });

  test('a pinned platform wins over what the repository shows', () async {
    // A catalog left behind in the website would make it look like iOS too.
    at(web, 'stray/Localizable.xcstrings')
      ..createSync(recursive: true)
      ..writeAsStringSync('{}');
    writeConfig(web, <String, Object>{
      'angular_dir': 'src/locale',
      'platforms': <String>['angular'],
    });
    final Run r = await fl(web, <String>['pull']);
    expect(r.code, 0, reason: r.err);
    expect(at(web, 'stray/Localizable.xcstrings').readAsStringSync(), '{}');
    expect(at(web, 'src/locale/messages.fr.arb').existsSync(), isTrue);
    expect(r.err, isNot(contains('Pin it')));
  });

  test('status says which platforms this repository holds', () async {
    writeConfig(app, <String, Object>{
      'xcstrings_dir': 'App/Resources',
      'platforms': <String>['ios'],
    });
    final Run r = await fl(app, <String>['status', '--json']);
    expect(r.code, 0, reason: r.err);
    expect(r.json['platforms'], <String>['ios', 'angular']);
    expect(r.json['repo_platforms'], <String>['ios']);
  });

  test('a repository that shows none of the platforms writes nothing',
      () async {
    final Directory bare = temp('fl_repo_bare');
    try {
      writeConfig(bare, <String, Object>{'angular_dir': 'src/locale'});
      final Run r = await fl(bare, <String>['pull']);
      expect(r.code, 1);
      expect(r.err, contains('"platforms"'));
      expect(filesIn(bare), isEmpty);
    } finally {
      bare.deleteSync(recursive: true);
    }
  });

  test('a pin naming a platform the project does not ship writes nothing',
      () async {
    writeConfig(app, <String, Object>{
      'xcstrings_dir': 'App/Resources',
      'platforms': <String>['flutter'],
    });
    final Run r = await fl(app, <String>['pull']);
    expect(r.code, 1);
    expect(r.err, contains('ships iOS, Angular only'));
    expect(filesIn(app), isEmpty);
  });

  test('an unknown platform in the config is refused', () async {
    writeConfig(app, <String, Object>{
      'platforms': <String>['android'],
    });
    final Run r = await fl(app, <String>['pull']);
    expect(r.code, isNot(0));
    expect(r.err, contains('"platforms" must list'));
  });

  test('a single-platform project ignores what the repository shows', () async {
    backend.platforms = <String>['ios'];
    // The website config of an iOS-only project still gets the catalog, as
    // before platforms per repository existed.
    final Run r = await fl(web, <String>['pull']);
    expect(r.code, 0, reason: r.err);
    expect(filesIn(web), <String>['Localizable.xcstrings']);
    expect(r.err, isNot(contains('Pin it')));
  });

  test('init -y in the app repository pins ios and lists its catalogs',
      () async {
    at(app, 'flutterlocalisation.json').deleteSync();
    at(app, 'App/Resources/Localizable.xcstrings')
        .writeAsStringSync(kServedCatalog);
    at(app, 'Widgets/Localizable.xcstrings')
      ..createSync(recursive: true)
      ..writeAsStringSync(kServedCatalog);
    final Run r = await fl(
        app, <String>['init', '--yes', '--no-pull', '--base-url', backend.url]);
    expect(r.code, 0, reason: '${r.out}\n${r.err}');
    final Map<String, dynamic> cfg =
        jsonDecode(at(app, 'flutterlocalisation.json').readAsStringSync())
            as Map<String, dynamic>;
    expect(cfg['platforms'], <String>['ios']);
    expect(cfg['xcstrings_catalogs'],
        <String>['Widgets', p.join('App', 'Resources')]);
    expect(cfg.containsKey('angular_dir'), isFalse);
    expect(cfg.containsKey('xcstrings_dir'), isFalse);
  });

  test('init -y in the website repository pins angular', () async {
    at(web, 'flutterlocalisation.json').deleteSync();
    final Run r = await fl(
        web, <String>['init', '--yes', '--no-pull', '--base-url', backend.url]);
    expect(r.code, 0, reason: '${r.out}\n${r.err}');
    final Map<String, dynamic> cfg =
        jsonDecode(at(web, 'flutterlocalisation.json').readAsStringSync())
            as Map<String, dynamic>;
    expect(cfg['platforms'], <String>['angular']);
    expect(cfg['angular_dir'], 'src/locale');
    expect(cfg.containsKey('xcstrings_dir'), isFalse);
    expect(cfg.containsKey('xcstrings_catalogs'), isFalse);
  });

  test('init --platforms wins over what the repository shows', () async {
    at(web, 'flutterlocalisation.json').deleteSync();
    final Run r = await fl(web, <String>[
      'init',
      '--yes',
      '--no-pull',
      '--platforms',
      'ios',
      '--base-url',
      backend.url,
    ]);
    expect(r.code, 0, reason: '${r.out}\n${r.err}');
    final Map<String, dynamic> cfg =
        jsonDecode(at(web, 'flutterlocalisation.json').readAsStringSync())
            as Map<String, dynamic>;
    expect(cfg['platforms'], <String>['ios']);
    expect(cfg.containsKey('angular_dir'), isFalse);
  });

  test('init -y where nothing shows the platform asks for --platforms',
      () async {
    final Directory bare = temp('fl_repo_bare');
    try {
      final Run r = await fl(bare,
          <String>['init', '--yes', '--no-pull', '--base-url', backend.url]);
      expect(r.code, 1);
      expect(r.err, contains('--platforms'));
      expect(at(bare, 'flutterlocalisation.json').existsSync(), isFalse);
    } finally {
      bare.deleteSync(recursive: true);
    }
  });

  test('pull_arbs of the MCP server writes the catalog only in the app',
      () async {
    final McpProcess mcp = await McpProcess.start(
        baseUrl: backend.url, workingDirectory: app.path);
    try {
      final Map<String, dynamic> data =
          await mcp.call('pull_arbs', <String, dynamic>{'apply': true});
      expect(data['ok'], isTrue, reason: data.toString());
      expect(filesIn(app),
          <String>[p.join('App', 'Resources', 'Localizable.xcstrings')]);
    } finally {
      await mcp.stop();
    }
  });

  test('doctor skips the Angular checks in a repository pinned to ios',
      () async {
    at(app, 'angular.json').writeAsStringSync('{"version": 1}');
    writeConfig(app, <String, Object>{
      'xcstrings_dir': 'App/Resources',
      'platforms': <String>['ios'],
    });
    final Run r = await fl(app, <String>['doctor']);
    expect(r.code, 0, reason: r.out);
    expect(r.out, isNot(contains('Angular')));
  });
}
