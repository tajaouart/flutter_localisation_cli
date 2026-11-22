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

  test('a Flutter + Angular project writes both', () async {
    backend.platforms = <String>['flutter', 'angular'];
    inApp('flutterlocalisation.json')
        .writeAsStringSync(jsonEncode(<String, String>{
      'base_url': backend.url,
      'project': 'Gush',
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
