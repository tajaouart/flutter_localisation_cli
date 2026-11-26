/// The `fl` binary on an Angular project, end to end: config, what lands on
/// disk, what `angular.json` says afterwards and what reaches the backend.
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

/// What `ng new` + `ng add @angular/localize` + an ARB extract-i18n leave.
Map<String, dynamic> angularJson() => <String, dynamic>{
      'version': 1,
      'projects': <String, dynamic>{
        'studio': <String, dynamic>{
          'projectType': 'application',
          'root': '',
          'architect': <String, dynamic>{
            'build': <String, dynamic>{
              'options': <String, dynamic>{
                'polyfills': <String>['zone.js', '@angular/localize/init'],
              },
            },
            'extract-i18n': <String, dynamic>{
              'options': <String, dynamic>{
                'format': 'arb',
                'outputPath': 'src/locale',
              },
            },
          },
        },
      },
    };

const String kExtraction = r'''{
  "@@locale": "en-US",
  "home.title": "Hello world",
  "@home.title": {"x-locations": [{"file": "src/app/app.component.ts"}]},
  "home.greeting": "Hi {$INTERPOLATION}",
  "home.new": "Brand new"
}
''';

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

  File inApp(final String rel) => File(p.join(tmp.path, rel));
  Map<String, dynamic> readAngularJson() =>
      jsonDecode(inApp('angular.json').readAsStringSync())
          as Map<String, dynamic>;

  setUp(() {
    backend.platforms = <String>['angular'];
    backend.languages = <String>['en', 'fr', 'pt-BR'];
    backend.imports.clear();
    backend.deletedKeys.clear();
    backend.importProblems = <String>[];
    tmp = Directory(Directory.systemTemp
        .createTempSync('fl_cli_angular_test')
        .resolveSymbolicLinksSync());
    inApp('flutterlocalisation.json')
        .writeAsStringSync(jsonEncode(<String, String>{
      'base_url': backend.url,
      'project': 'Gush',
      'angular_dir': 'src/locale',
    }));
    inApp('angular.json').writeAsStringSync(jsonEncode(angularJson()));
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('pull writes one Angular file per target locale and lists them',
      () async {
    final Run r = await fl(<String>['pull']);
    expect(r.code, 0, reason: r.err);
    expect(r.out, contains('Angular file'));
    final Map<String, dynamic> fr =
        jsonDecode(inApp('src/locale/messages.fr.arb').readAsStringSync())
            as Map<String, dynamic>;
    expect(fr['@@locale'], 'fr');
    expect(fr['home.greeting'], r'Hi {$INTERPOLATION} (fr)');
    expect(inApp('src/locale/messages.pt-BR.arb').existsSync(), isTrue);
    // Never the source: ng extract-i18n owns it.
    expect(inApp('src/locale/messages.arb').existsSync(), isFalse);
    expect(inApp('src/locale/messages.en.arb').existsSync(), isFalse);
    // No Flutter ARB and no catalog for an Angular-only project.
    expect(
        tmp.listSync(recursive: true).where((final FileSystemEntity e) =>
            p.basename(e.path).startsWith('app_')),
        isEmpty);
    final Map<String, dynamic> i18n =
        ((readAngularJson()['projects'] as Map<String, dynamic>)['studio']
            as Map<String, dynamic>)['i18n'] as Map<String, dynamic>;
    expect(i18n['sourceLocale'], 'en');
    expect(i18n['locales'], <String, dynamic>{
      'fr': <String, dynamic>{'translation': 'src/locale/messages.fr.arb'},
      'pt-BR': <String, dynamic>{
        'translation': 'src/locale/messages.pt-BR.arb'
      },
    });
  });

  test('a locale angular.json already lists keeps what it says', () async {
    final Map<String, dynamic> ws = angularJson();
    ((ws['projects'] as Map<String, dynamic>)['studio']
        as Map<String, dynamic>)['i18n'] = <String, dynamic>{
      'sourceLocale': 'en-US',
      'locales': <String, dynamic>{'fr': 'custom/fr.arb'},
    };
    inApp('angular.json').writeAsStringSync(jsonEncode(ws));
    final Run r = await fl(<String>['pull']);
    expect(r.code, 0, reason: r.err);
    final Map<String, dynamic> i18n =
        ((readAngularJson()['projects'] as Map<String, dynamic>)['studio']
            as Map<String, dynamic>)['i18n'] as Map<String, dynamic>;
    expect(i18n['sourceLocale'], 'en-US');
    expect((i18n['locales'] as Map<String, dynamic>)['fr'], 'custom/fr.arb');
    expect((i18n['locales'] as Map<String, dynamic>).keys,
        containsAll(<String>['fr', 'pt-BR']));
  });

  test(
      'new strings in messages.arb are named, never block, and --adopt '
      'imports them', () async {
    inApp('src/locale/messages.arb')
      ..createSync(recursive: true)
      ..writeAsStringSync(kExtraction);
    Run r = await fl(<String>['pull']);
    expect(r.code, 0, reason: r.err);
    expect(r.out, contains('fl import'));
    expect(backend.imports, isEmpty);

    r = await fl(<String>['pull', '--adopt']);
    expect(r.code, 0, reason: r.err);
    expect(backend.imports, hasLength(1));
    // The service reads the locale from the file: none is sent.
    expect(backend.imports.single.hasLanguage, isFalse);
    expect(backend.imports.single.fileName, 'messages.arb');
  });

  test('import sends an extraction as is, whatever its @@locale says',
      () async {
    inApp('src/locale/messages.arb')
      ..createSync(recursive: true)
      ..writeAsStringSync(kExtraction);
    backend.importProblems = <String>[
      'home.updated: a plural or select inside a sentence gets a hash id from '
          'Angular; make it the whole message, with the sentence inside each '
          'case',
    ];
    final Run r = await fl(<String>['import', 'src/locale/messages.arb']);
    expect(r.code, 0, reason: r.err);
    expect(backend.imports.single.hasLanguage, isFalse);
    expect(r.out, contains('home.updated'));
    expect(r.out, contains('could not be imported'));
  });

  test('a translated Angular file is imported as its own locale', () async {
    inApp('src/locale/messages.fr.arb')
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(
          <String, String>{'@@locale': 'fr', 'home.title': 'Bonjour'}));
    final Run r = await fl(<String>['import', 'src/locale/messages.fr.arb']);
    expect(r.code, 0, reason: r.err);
    expect(backend.imports.single.hasLanguage, isFalse);
  });

  test('export writes the Angular files into a given folder', () async {
    final Run r = await fl(<String>['export', 'out']);
    expect(r.code, 0, reason: r.err);
    expect(inApp('out/messages.fr.arb').existsSync(), isTrue);
  });

  // The service answers home.title "Hello (en)" and home.greeting
  // "Hi {$INTERPOLATION} (en)" for the source; kExtraction has other texts
  // for both and adds home.new.
  void writeSource([final String content = kExtraction]) =>
      inApp('src/locale/messages.arb')
        ..createSync(recursive: true)
        ..writeAsStringSync(content);

  test(
      'diff lists what only the file has, what differs and what only the '
      'service has', () async {
    writeSource();
    Run r = await fl(<String>['diff', 'src/locale/messages.arb']);
    expect(r.code, 0, reason: r.err);
    expect(r.out, contains('against "en" (the source)'));
    expect(r.out, contains('1 new, not on the service yet: home.new'));
    expect(r.out, contains('2 different'));
    expect(r.out, contains('service: "Hello (en)"'));

    r = await fl(<String>['--json', 'diff', 'src/locale/messages.arb']);
    expect(r.json['added'], <String>['home.new']);
    expect((r.json['changed'] as Map<String, dynamic>).keys,
        <String>['home.title', 'home.greeting']);
    expect(r.json['gone'], isEmpty);
    expect(backend.imports, isEmpty, reason: 'diff changes nothing');
  });

  test('a dry-run import says key by key what it would do', () async {
    writeSource();
    final Run r =
        await fl(<String>['--dry-run', 'import', 'src/locale/messages.arb']);
    expect(r.code, 0, reason: r.err);
    expect(r.out, contains('1 new key(s) would be added'));
    expect(
        r.out,
        contains(
            "2 differ and would keep the service's text (--overwrite replaces it)"));
    expect(backend.imports, isEmpty);
  });

  test('--prune deletes the keys the source no longer has, after the import',
      () async {
    writeSource(jsonEncode(
        <String, String>{'@@locale': 'en', 'home.title': 'Hello world'}));
    Run r = await fl(
        <String>['--dry-run', 'import', 'src/locale/messages.arb', '--prune']);
    expect(r.code, 0, reason: r.err);
    expect(
        r.out,
        contains(
            '1 on the service are not in the file and would be deleted: home.greeting'));
    expect(backend.deletedKeys, isEmpty);

    r = await fl(<String>['import', 'src/locale/messages.arb', '--prune']);
    expect(r.code, 0, reason: r.err);
    expect(backend.imports, hasLength(1));
    expect(backend.deletedKeys, <String>['home.greeting']);
    expect(r.out,
        contains('Deleted 1 key(s) the file no longer has: home.greeting'));
  });

  test('--prune lets a service that prunes do it and says what it did',
      () async {
    backend.serverPrune =
        (pruned: <String>['home.greeting'], unshipped: <String>['home.shared']);
    addTearDown(() => backend.serverPrune = null);
    writeSource(jsonEncode(
        <String, String>{'@@locale': 'en', 'home.title': 'Hello world'}));
    final Run r =
        await fl(<String>['import', 'src/locale/messages.arb', '--prune']);
    expect(r.code, 0, reason: r.err);
    expect(backend.imports.single.prune, isTrue);
    expect(backend.deletedKeys, isEmpty,
        reason: 'the service knows which keys the platform ships');
    expect(r.out,
        contains('Deleted 1 key(s) the file no longer has: home.greeting'));
    expect(
        r.out,
        contains('1 key(s) the file no longer has also ship to other '
            'platforms and no longer ship to angular: home.shared'));
  });

  test('a dry-run --prune names a key other platforms ship as losing angular',
      () async {
    backend
      ..platformText = true
      ..platforms = <String>['angular', 'ios']
      ..extraKeys = <String>['home.greeting']
      ..extraKeyPlatforms = <String, List<String>>{
        'home.greeting': <String>['angular', 'ios'],
      };
    addTearDown(() => backend
      ..platformText = false
      ..extraKeys = <String>[]
      ..extraKeyPlatforms = <String, List<String>>{});
    writeSource(jsonEncode(
        <String, String>{'@@locale': 'en', 'home.title': 'Hello world'}));
    final Run r = await fl(
        <String>['--dry-run', 'import', 'src/locale/messages.arb', '--prune']);
    expect(r.code, 0, reason: r.err);
    expect(
        r.out,
        contains('1 not in the file also ship to other platforms and would '
            'no longer ship to angular: home.greeting'));
    expect(r.out, isNot(contains('would be deleted')));
  });

  test('--prune refuses a translated file', () async {
    inApp('src/locale/messages.fr.arb')
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(
          <String, String>{'@@locale': 'fr', 'home.title': 'Bonjour'}));
    final Run r =
        await fl(<String>['import', 'src/locale/messages.fr.arb', '--prune']);
    expect(r.code, isNot(0));
    expect(r.out + r.err,
        contains('--prune deletes keys the SOURCE file no longer has'));
    expect(backend.imports, isEmpty);
    expect(backend.deletedKeys, isEmpty);
  });

  test('export writes the ids in the order of the source file', () async {
    writeSource(jsonEncode(<String, String>{
      '@@locale': 'en',
      'home.greeting': r'Hi {$INTERPOLATION}',
      'home.title': 'Hello world',
    }));
    final Run r = await fl(<String>['export', 'src/locale']);
    expect(r.code, 0, reason: r.err);
    final String fr = inApp('src/locale/messages.fr.arb').readAsStringSync();
    expect((jsonDecode(fr) as Map<String, dynamic>).keys,
        <String>['@@locale', 'home.greeting', 'home.title']);
    expect(fr, endsWith('}\n'));
  });

  test('a Flutter + Angular project writes both', () async {
    backend.platforms = <String>['flutter', 'angular'];
    inApp('flutterlocalisation.json')
        .writeAsStringSync(jsonEncode(<String, Object>{
      'base_url': backend.url,
      'project': 'Gush',
      'platforms': <String>['flutter', 'angular'],
      'arb_dir': 'lib/l10n',
      'angular_dir': 'web/src/locale',
    }));
    final Run r = await fl(<String>['pull', '--no-git']);
    expect(r.code, 0, reason: r.err);
    expect(inApp('lib/l10n/app_en.arb').existsSync(), isTrue);
    expect(inApp('web/src/locale/messages.fr.arb').existsSync(), isTrue);
  });

  test('doctor names what an Angular app is missing', () async {
    final Map<String, dynamic> ws = angularJson();
    (((ws['projects'] as Map<String, dynamic>)['studio']
            as Map<String, dynamic>)['architect'] as Map<String, dynamic>)
        .remove('extract-i18n');
    inApp('angular.json').writeAsStringSync(jsonEncode(ws));
    inApp('src/locale/messages.arb')
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(<String, String>{
        '@@locale': 'en',
        '12345': 'No id',
        'home.x': r'Updated {$ICU}',
      }));
    inApp('src/locale/messages.de.arb').writeAsStringSync('{"@@locale":"de"}');
    final Run r = await fl(<String>['doctor']);
    expect(r.code, 1, reason: r.out);
    expect(r.out, contains('does not write ARB'));
    expect(r.out, contains('12345: no @@id'));
    expect(r.out, contains('home.x: a plural or select inside a sentence'));
    expect(r.out, contains('de has a file'));
  });

  test('doctor is quiet on a complete Angular setup', () async {
    await fl(<String>['pull']);
    inApp('src/locale/messages.arb').writeAsStringSync(kExtraction);
    final Run r = await fl(<String>['doctor']);
    expect(r.code, 0, reason: r.out);
    expect(r.out, contains('Angular i18n setup is in place'));
  });
}
