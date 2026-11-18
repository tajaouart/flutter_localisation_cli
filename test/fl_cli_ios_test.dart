/// The `fl` binary on an iOS project, end to end: config file, flags, exit
/// codes, what lands on disk and what reaches the backend.
///
/// `pull`, `export` and `import` each have a platform branch in `bin/fl.dart`
/// that no `Operations` test can reach; these run the real command against a
/// backend on a local port.
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

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

  setUpAll(() async => backend = await FakeBackend.start());
  tearDownAll(() => backend.close());

  setUp(() {
    backend.platforms = <String>['ios'];
    backend.imports.clear();
    tmp = Directory(Directory.systemTemp
        .createTempSync('fl_cli_ios_test')
        .resolveSymbolicLinksSync());
    File(p.join(tmp.path, 'flutterlocalisation.json'))
        .writeAsStringSync(jsonEncode(<String, String>{
      'base_url': backend.url,
      'project': 'Gush',
      'arb_dir': 'lib/l10n',
      'xcstrings_dir': 'Resources',
    }));
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  File catalog() =>
      File(p.join(tmp.path, 'Resources', 'Localizable.xcstrings'));
  Iterable<String> arbsOnDisk() => tmp
      .listSync(recursive: true)
      .map((final FileSystemEntity e) => e.path)
      .where((final String path) => path.endsWith('.arb'));

  test('pull writes the catalog as served and no ARB for an iOS project',
      () async {
    final Run r = await fl(<String>['pull', '--no-git']);
    expect(r.code, 0, reason: r.err);
    expect(r.out, contains('String Catalog'));
    expect(catalog().readAsStringSync(), kServedCatalog);
    expect(
        File(p.join(tmp.path, 'Resources', 'InfoPlist.xcstrings')).existsSync(),
        isFalse);
    expect(arbsOnDisk(), isEmpty);
    expect(r.out, isNot(contains('regenerate the Dart')),
        reason: 'no gen_l10n step for iOS');
  });

  test('init --yes writes the config from what is on disk and pulls', () async {
    File(p.join(tmp.path, 'flutterlocalisation.json')).deleteSync();
    File(p.join(tmp.path, 'App', 'Localizable.xcstrings'))
      ..createSync(recursive: true)
      ..writeAsStringSync(kServedCatalog);

    final Run r =
        await fl(<String>['init', '--yes', '--base-url', backend.url]);
    expect(r.code, 0, reason: '${r.out}\n${r.err}');
    final Map<String, dynamic> cfg = jsonDecode(
        File(p.join(tmp.path, 'flutterlocalisation.json'))
            .readAsStringSync()) as Map<String, dynamic>;
    expect(cfg['project'], 'Gush');
    expect(cfg['project_id'], 7);
    expect(cfg['xcstrings_dir'], 'App');
    expect(cfg.containsKey('arb_dir'), isFalse, reason: 'iOS-only project');
    expect(cfg['flavor'], 'Default',
        reason: 'stored, so a second flavor later does not break commands');
    expect(r.out, contains('Wrote flutterlocalisation.json'));
    expect(r.out, contains('String Catalog'), reason: 'the first pull ran');
    expect(File(p.join(tmp.path, '.claude', 'settings.json')).existsSync(),
        isFalse,
        reason: '--yes does not write the guard unless asked');
  });

  test('init --yes --guard writes the rules for Claude Code and Copilot',
      () async {
    File(p.join(tmp.path, 'flutterlocalisation.json')).deleteSync();
    File(p.join(tmp.path, 'App', 'Localizable.xcstrings'))
      ..createSync(recursive: true)
      ..writeAsStringSync(kServedCatalog);

    final Run r = await fl(
        <String>['init', '--yes', '--guard', '--base-url', backend.url]);
    expect(r.code, 0, reason: '${r.out}\n${r.err}');
    for (final String name in <String>[
      p.join('.claude', 'settings.json'),
      p.join('.github', 'hooks', 'fl-guard.json'),
      p.join('.github', 'copilot-instructions.md'),
    ]) {
      expect(File(p.join(tmp.path, name)).existsSync(), isTrue, reason: name);
    }
  });

  test(
      'init refuses to overwrite a config without --force when not interactive',
      () async {
    final Run r =
        await fl(<String>['init', '--yes', '--base-url', backend.url]);
    expect(r.code, 1);
    expect(r.err, contains('--force'));
  });

  test('init --no-pull on a Flutter project prefills arb_dir from l10n.yaml',
      () async {
    backend.platforms = <String>['flutter'];
    File(p.join(tmp.path, 'l10n.yaml'))
        .writeAsStringSync('arb-dir: lib/l10n\n');
    final Run r = await fl(<String>[
      'init',
      '--yes',
      '--force',
      '--no-pull',
      '--base-url',
      backend.url
    ]);
    expect(r.code, 0, reason: r.err);
    final Map<String, dynamic> cfg = jsonDecode(
        File(p.join(tmp.path, 'flutterlocalisation.json'))
            .readAsStringSync()) as Map<String, dynamic>;
    expect(cfg['arb_dir'], 'lib/l10n');
    expect(cfg.containsKey('xcstrings_dir'), isFalse);
  });

  test('login refuses a token the API rejects and saves one it accepts',
      () async {
    final File creds = File(
        p.join(tmp.path, '.config', 'flutterlocalisation', 'credentials.json'));

    final Run bad = await fl(<String>[
      'login',
      '--token',
      'flk_live_stale',
      '--base-url',
      backend.url
    ]);
    expect(bad.code, 1);
    expect(bad.err, contains('rejected the token'));
    expect(bad.err, contains('--no-verify'));
    expect(creds.existsSync(), isFalse);

    final Run good = await fl(<String>[
      'login',
      '--token',
      'flk_live_test',
      '--base-url',
      backend.url
    ]);
    expect(good.code, 0, reason: good.err);
    expect(good.out, contains('accepts the token (1 project(s))'));
    final Map<String, dynamic> saved =
        jsonDecode(creds.readAsStringSync()) as Map<String, dynamic>;
    expect((saved['tokens'] as Map<String, dynamic>)[backend.url],
        'flk_live_test');

    final Run unverified = await fl(<String>[
      'login',
      '--token',
      'flk_live_stale',
      '--base-url',
      backend.url,
      '--no-verify'
    ]);
    expect(unverified.code, 0, reason: unverified.err);
  });

  test('a rejected token names where it came from', () async {
    final ProcessResult r = await Process.run(
      'dart',
      <String>['run', p.join(packageRoot(), 'bin', 'fl.dart'), 'projects'],
      workingDirectory: tmp.path,
      environment: <String, String>{
        'FL_API_TOKEN': 'flk_live_stale',
        'HOME': tmp.path
      },
    );
    expect(r.exitCode, 1);
    expect(r.stderr as String,
        contains(r'The token from $FL_API_TOKEN was rejected'));
    expect(r.stderr as String, contains('fl login'));
  });

  test('projects lists each flavor with its id', () async {
    final Run text = await fl(<String>['projects']);
    expect(text.code, 0, reason: text.err);
    expect(text.out, contains('Default (id 3): en'));
    final Run json = await fl(<String>['projects', '--json']);
    final List<dynamic> projects = jsonDecode(json.out) as List<dynamic>;
    final Map<String, dynamic> flavor =
        ((projects.single as Map<String, dynamic>)['flavors'] as List<dynamic>)
            .single as Map<String, dynamic>;
    expect(flavor['id'], 3);
  });

  test('edit finds a catalog key by its stem and keeps its placeholders',
      () async {
    final Run stem = await fl(<String>[
      '--dry-run',
      'edit',
      'running',
      '--locale',
      'en',
      '--value',
      '{arg1} s to go'
    ]);
    expect(stem.code, 0, reason: stem.err);
    expect(stem.out, contains('would update "running %lld" [en]'));

    final Run dropped = await fl(<String>[
      '--dry-run',
      'edit',
      'running',
      '--locale',
      'en',
      '--value',
      'almost done'
    ]);
    expect(dropped.code, 1);
    expect(dropped.out, contains('must keep {arg1}'));

    final Run unknown = await fl(<String>[
      '--dry-run',
      'edit',
      'runn',
      '--locale',
      'en',
      '--value',
      'x'
    ]);
    expect(unknown.code, 1);
    expect(unknown.err, contains('Did you mean "running %lld"?'));
  });

  test('pull --dry-run touches nothing', () async {
    final Run r = await fl(<String>['--dry-run', 'pull']);
    expect(r.code, 0, reason: r.err);
    expect(r.out, contains('DRY RUN'));
    expect(catalog().existsSync(), isFalse);
  });

  test(
      'pull stops when the catalog holds a key the service lacks, and --adopt imports it',
      () async {
    catalog()
      ..createSync(recursive: true)
      ..writeAsStringSync(kCatalogWithLocalKey);

    final Run refused = await fl(<String>['pull', '--no-git']);
    expect(refused.code, 1);
    expect(refused.err, contains('Localizable.xcstrings has 1 key(s)'));
    expect(refused.err, contains('local only'));
    expect(refused.err, contains('fl pull --adopt'));
    expect(backend.imports, isEmpty);
    expect(catalog().readAsStringSync(), kCatalogWithLocalKey);

    final Run adopted =
        await fl(<String>['pull', '--no-git', '--adopt', '--json']);
    expect(adopted.code, 0, reason: adopted.err);
    expect(backend.imports, hasLength(1));
    expect(backend.imports.single.hasLanguage, isFalse);
    expect(backend.imports.single.fileName, 'Localizable.xcstrings');
    expect(adopted.json['adopted'], <String>['local only']);
    expect(adopted.json['method'], 'api');
    expect(adopted.json['catalog_dir'], p.join(tmp.path, 'Resources'));
    expect(adopted.json.containsKey('template'), isFalse);
    expect(catalog().readAsStringSync(), kServedCatalog);
  });

  test(
      'pull --adopt imports the catalog when the token cannot translate, and says so',
      () async {
    backend.translateScope = false;
    addTearDown(() => backend.translateScope = true);
    catalog()
      ..createSync(recursive: true)
      ..writeAsStringSync(kCatalogWithLocalKey);

    final Run adopted = await fl(<String>['pull', '--no-git', '--adopt']);

    expect(adopted.code, 0, reason: adopted.err);
    expect(backend.imports.last.autoTranslate, isFalse);
    expect(backend.imports.last.fileName, 'Localizable.xcstrings');
    expect(adopted.out, contains('Not translated: this token does not have'));
    expect(adopted.out, contains('fl retranslate'));
    expect(catalog().readAsStringSync(), kServedCatalog);
  });

  test('pull --discard-local takes the service copy over the Xcode edit',
      () async {
    catalog()
      ..createSync(recursive: true)
      ..writeAsStringSync(kCatalogWithLocalKey);
    final Run r = await fl(<String>['pull', '--no-git', '--discard-local']);
    expect(r.code, 0, reason: r.err);
    expect(backend.imports, isEmpty);
    expect(catalog().readAsStringSync(), kServedCatalog);
  });

  test(
      'pull on a mixed project writes the ARBs and the catalog in their own folders',
      () async {
    backend.platforms = <String>['flutter', 'ios'];
    final Run r = await fl(<String>['pull', '--no-git', '--json']);
    expect(r.code, 0, reason: r.err);
    expect(File(p.join(tmp.path, 'lib', 'l10n', 'app_en.arb')).existsSync(),
        isTrue);
    expect(catalog().readAsStringSync(), kServedCatalog);
    expect(r.json['template'], 'app_en.arb');
    expect(r.json['dir'], p.join(tmp.path, 'lib', 'l10n'));
    expect(r.json['catalog_dir'], p.join(tmp.path, 'Resources'));
    final List<dynamic> files = r.json['files'] as List<dynamic>;
    expect(files.map((final dynamic f) => (f as Map<String, dynamic>)['file']),
        containsAll(<String>['app_en.arb', 'Localizable.xcstrings']));
  });

  test('export writes the catalog into the given folder and reports it',
      () async {
    final Run r = await fl(<String>['export', 'out', '--json']);
    expect(r.code, 0, reason: r.err);
    expect(
        File(p.join(tmp.path, 'out', 'Localizable.xcstrings'))
            .readAsStringSync(),
        kServedCatalog);
    expect(r.json['catalog_dir'], 'out');
    expect(r.json.containsKey('template'), isFalse);
    expect(arbsOnDisk(), isEmpty);
  });

  test('export refuses to drop a key staged in the catalog', () async {
    catalog()
      ..createSync(recursive: true)
      ..writeAsStringSync(kCatalogWithLocalKey);
    final Run r = await fl(<String>['export']);
    expect(r.code, 1);
    expect(r.err, contains('local only'));
    expect(r.err, contains('--discard-local'));
    expect(catalog().readAsStringSync(), kCatalogWithLocalKey);
  });

  test('import sends a catalog without a language and reports its locales',
      () async {
    final File staged = File(p.join(tmp.path, 'Staged.xcstrings'))
      ..writeAsStringSync(kCatalogWithLocalKey);
    final Run r = await fl(<String>['import', staged.path, '--json']);
    expect(r.code, 0, reason: r.err);
    expect(backend.imports, hasLength(1));
    expect(backend.imports.single.hasLanguage, isFalse);
    expect(backend.imports.single.fileName, 'Staged.xcstrings');
    expect(r.json['ok'], isTrue);
    expect(r.json['locales'], <String>['en']);
  });

  test('import --dry-run counts catalog keys and posts nothing', () async {
    final File staged = File(p.join(tmp.path, 'Staged.xcstrings'))
      ..writeAsStringSync(kCatalogWithLocalKey);
    final Run r =
        await fl(<String>['--dry-run', 'import', staged.path, '--json']);
    expect(r.code, 0, reason: r.err);
    expect(r.json['keys'], 2);
    expect(r.json['format'], 'xcstrings');
    expect(backend.imports, isEmpty);
  });

  test('projects lists what each project ships', () async {
    final Run r = await fl(<String>['projects', '--json']);
    expect(r.code, 0, reason: r.err);
    expect(r.out, contains('"ios"'));
  });

  group('an app with a catalog per target', () {
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
    File target(final String dir, [final String name = 'Localizable']) =>
        File(p.join(tmp.path, dir, '$name.xcstrings'));
    Map<String, dynamic> stringsOf(final File file) =>
        (jsonDecode(file.readAsStringSync()) as Map<String, dynamic>)['strings']
            as Map<String, dynamic>;
    void write(final File file, final Map<String, dynamic> strings) => file
      ..createSync(recursive: true)
      ..writeAsStringSync(catalogOf(strings));
    void config(final List<Object> catalogs) =>
        File(p.join(tmp.path, 'flutterlocalisation.json'))
            .writeAsStringSync(jsonEncode(<String, Object>{
          'base_url': backend.url,
          'project': 'Gush',
          'xcstrings_catalogs': catalogs,
        }));

    setUp(() {
      backend
        ..extraKeys = <String>[
          'Start',
          'Shared',
          'Widget title',
          'Gone',
          'mac.NSMicrophoneUsageDescription',
        ]
        ..servedCatalog = catalogOf(<String, dynamic>{
          'running %lld': entry('Cleaning… %lld s left', 'Nettoyage… %lld s'),
          'Start': entry('Start', 'Démarrer'),
          'Shared': entry('Shared', 'Partagé'),
          'Widget title': entry('Widget title', 'Titre du widget'),
          'Gone': entry('Gone', 'Parti'),
          'mac.NSMicrophoneUsageDescription': entry('Mac hears you', 'Le Mac'),
        })
        ..appShortcuts = null;
      // What Xcode left after extracting the strings of each target: the keys,
      // and nothing translated yet.
      write(target('App'), <String, dynamic>{
        'running %lld': <String, dynamic>{},
        'Start': <String, dynamic>{},
        'Shared': <String, dynamic>{},
        '': <String, dynamic>{},
      });
      write(target('Extensions/Widgets'), <String, dynamic>{
        'Shared': <String, dynamic>{},
        'Widget title': <String, dynamic>{},
      });
      config(<Object>['App', 'Extensions/Widgets']);
    });
    tearDown(() {
      backend
        ..extraKeys = <String>[]
        ..servedCatalog = null
        ..appShortcuts = null;
    });

    test('pull gives each catalog the keys it declares, in Xcode\'s format',
        () async {
      final Run r = await fl(<String>['pull']);
      expect(r.code, 0, reason: r.err);

      expect(stringsOf(target('App')).keys,
          <String>['Shared', 'Start', 'running %lld']);
      expect(stringsOf(target('Extensions/Widgets')).keys,
          <String>['Shared', 'Widget title']);
      expect(
        stringsOf(target('Extensions/Widgets'))['Widget title'],
        entry('Widget title', 'Titre du widget'),
      );
      expect(
        target('Extensions/Widgets').readAsStringSync(),
        startsWith('{\n  "sourceLanguage" : "en",\n  "strings" : {\n'
            '    "Shared" : {\n      "localizations" : {\n        "en" : {\n'),
      );
      expect(r.out, contains('Wrote 2 String Catalog(s)'));
      expect(
        r.out,
        contains('2 key(s) on the service are in none of the catalogs'),
      );
      expect(r.out, contains('Gone, mac.NSMicrophoneUsageDescription'));
      expect(target('App', 'AppShortcuts').existsSync(), isFalse,
          reason: 'an older service has no such catalog, and that is fine');
      expect(target('App', 'InfoPlist').existsSync(), isFalse);
    });

    test('a second pull changes no byte', () async {
      expect((await fl(<String>['pull'])).code, 0);
      final String app = target('App').readAsStringSync();
      final String widgets = target('Extensions/Widgets').readAsStringSync();
      expect((await fl(<String>['pull'])).code, 0);
      expect(target('App').readAsStringSync(), app);
      expect(target('Extensions/Widgets').readAsStringSync(), widgets);
    });

    test('a target with its own Info.plist gets its prefixed keys', () async {
      write(target('Mac'), <String, dynamic>{'Start': <String, dynamic>{}});
      config(<Object>[
        'App',
        'Extensions/Widgets',
        <String, String>{'dir': 'Mac', 'infoplist_prefix': 'mac.'},
      ]);
      final Run r = await fl(<String>['pull']);
      expect(r.code, 0, reason: r.err);
      expect(stringsOf(target('Mac')).keys, <String>['Start']);
      expect(stringsOf(target('Mac', 'InfoPlist')), <String, dynamic>{
        'NSMicrophoneUsageDescription': entry('Mac hears you', 'Le Mac'),
      });
      expect(r.out, contains('1 key(s) on the service are in none'));
      expect(
          stringsOf(target('App')).keys, isNot(contains(startsWith('mac.'))));
    });

    test('App Shortcut phrases land beside the first catalog', () async {
      backend.appShortcuts = catalogOf(<String, dynamic>{
        r'Open ${applicationName}': entry(r'Open ${applicationName}'),
      });
      final Run r = await fl(<String>['pull']);
      expect(r.code, 0, reason: r.err);
      expect(stringsOf(target('App', 'AppShortcuts')).keys,
          <String>[r'Open ${applicationName}']);
      expect(
          target('Extensions/Widgets', 'AppShortcuts').existsSync(), isFalse);
    });

    test('a key only a catalog has stops the pull and is named', () async {
      write(target('Extensions/Widgets'), <String, dynamic>{
        'Shared': <String, dynamic>{},
        'Brand new': entry('Brand new'),
      });
      final String before = target('App').readAsStringSync();
      final Run r = await fl(<String>['pull']);
      expect(r.code, 1);
      expect(r.err, contains('have 1 key(s) the service does not have yet'));
      expect(r.err, contains('  Brand new'));
      expect(r.err, contains('fl pull --adopt'));
      expect(target('App').readAsStringSync(), before);
      expect(backend.imports, isEmpty);

      final Run export = await fl(<String>['export']);
      expect(export.code, 1);
      expect(export.err, contains('Brand new'));
      expect(export.err, contains('Run `fl pull --adopt`'));
    });

    test('pull --adopt imports the union once, then writes every catalog',
        () async {
      write(target('Extensions/Widgets'), <String, dynamic>{
        'Shared': <String, dynamic>{},
        'Brand new': entry('Brand new'),
      });
      final Run r = await fl(<String>['pull', '--adopt']);
      expect(r.code, 0, reason: r.err);
      expect(backend.imports, hasLength(1));
      final ReceivedImport sent = backend.imports.single;
      expect(sent.fileName, 'Localizable.xcstrings');
      expect(sent.hasLanguage, isFalse);
      expect(sent.autoTranslate, isTrue);
      expect(sent.body, contains('Brand new'));
      expect(sent.body, contains('running %lld'),
          reason: 'one catalog, every target');
      expect(stringsOf(target('App')).keys,
          <String>['Shared', 'Start', 'running %lld']);
    });

    test('a folder with no catalog is named, and nothing is written', () async {
      config(<Object>['App', 'Extensions/Widgets', 'Extensions/Shield']);
      final String before = target('App').readAsStringSync();
      final Run r = await fl(<String>['pull']);
      expect(r.code, 1);
      expect('${r.out}${r.err}', contains('No catalog at'));
      expect('${r.out}${r.err}',
          contains(p.join('Extensions', 'Shield', 'Localizable.xcstrings')));
      expect(target('App').readAsStringSync(), before);
    });

    test('export into a folder still writes the whole catalog as served',
        () async {
      final Run r = await fl(<String>['export', 'out']);
      expect(r.code, 0, reason: r.err);
      expect(target('out').readAsStringSync(), backend.servedCatalog);
      expect(stringsOf(target('App'))['Start'], <String, dynamic>{},
          reason: 'the targets are left alone');
    });

    test('a wrong shape in the config is refused', () async {
      for (final Object wrong in <Object>[
        'App',
        <Object>[],
        <Object>[3],
        <Object>[
          <String, Object>{'infoplist_prefix': 'mac.'}
        ],
      ]) {
        File(p.join(tmp.path, 'flutterlocalisation.json'))
            .writeAsStringSync(jsonEncode(<String, Object>{
          'base_url': backend.url,
          'project': 'Gush',
          'xcstrings_catalogs': wrong,
        }));
        final Run r = await fl(<String>['pull']);
        expect(r.code, isNot(0), reason: '$wrong');
        expect(r.err, contains('"xcstrings_catalogs" must list the folders'),
            reason: '$wrong');
      }
    });
  });
}
