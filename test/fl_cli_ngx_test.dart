/// The `fl` binary on an ngx-translate project, end to end: what lands on
/// disk, what a pull refuses, and what reaches the backend.
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

  File inApp(final String rel) => File(p.join(tmp.path, rel));
  Map<String, dynamic> read(final String rel) =>
      jsonDecode(inApp(rel).readAsStringSync()) as Map<String, dynamic>;

  setUp(() {
    backend.platforms = <String>['ngx'];
    backend.languages = <String>['en', 'fr'];
    backend.extraKeys = <String>['home.title', 'home.greeting'];
    backend.imports.clear();
    backend.importProblems = <String>[];
    tmp = Directory(Directory.systemTemp
        .createTempSync('fl_cli_ngx_test')
        .resolveSymbolicLinksSync());
    inApp('flutterlocalisation.json')
        .writeAsStringSync(jsonEncode(<String, String>{
      'base_url': backend.url,
      'project': 'Gush',
      'angular_dir': 'src/assets/i18n',
    }));
  });
  tearDown(() {
    backend.extraKeys = <String>[];
    tmp.deleteSync(recursive: true);
  });

  test('pull writes every language, the base included, flat', () async {
    final Run r = await fl(<String>['pull']);
    expect(r.code, 0, reason: r.err);
    expect(r.out, contains('ngx-translate file'));
    expect(read('src/assets/i18n/fr.json'), <String, dynamic>{
      'home.greeting': 'Hi {{name}} (fr)',
      'home.title': 'Hello (fr)',
    });
    expect(read('src/assets/i18n/en.json')['home.title'], 'Hello (en)');
    expect(
        tmp.listSync(recursive: true).where((final FileSystemEntity e) =>
            e.path.endsWith('.arb') || e.path.endsWith('.xcstrings')),
        isEmpty);
    expect(backend.requests.where((final String r) => r.contains('format=ngx')),
        hasLength(2));
  });

  test('a nested file stays nested', () async {
    inApp('src/assets/i18n/fr.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"home": {"title": "x"}}');
    final Run r = await fl(<String>['pull']);
    expect(r.code, 0, reason: r.err);
    expect(read('src/assets/i18n/fr.json')['home'], <String, dynamic>{
      'title': 'Hello (fr)',
      'greeting': 'Hi {{name}} (fr)'
    });
    expect(read('src/assets/i18n/en.json').containsKey('home.title'), isTrue);
  });

  test('a new language follows the nested base file', () async {
    inApp('src/assets/i18n/en.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"home": {"title": "x", "greeting": "y"}}');
    final Run r = await fl(<String>['pull']);
    expect(r.code, 0, reason: r.err);
    expect(read('src/assets/i18n/fr.json'), <String, dynamic>{
      'home': <String, dynamic>{
        'title': 'Hello (fr)',
        'greeting': 'Hi {{name}} (fr)'
      },
    });
  });

  test('what the service refuses stays in the file and never stops the pull',
      () async {
    final Map<String, dynamic> mine = <String, dynamic>{
      r'$schema': './schema.json',
      'home.title': 'old',
      'path': 'Signed in as {{ user.name }}',
      'days': <String>['Mon', 'Tue'],
      'brace': 'Use {curly}',
    };
    final File en = inApp('src/assets/i18n/en.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(mine));
    final Run r = await fl(<String>['pull']);
    expect(r.code, 0, reason: r.err + r.out);
    expect(backend.imports, isEmpty);
    expect(read('src/assets/i18n/en.json'), <String, dynamic>{
      ...mine,
      'home.title': 'Hello (en)',
      'home.greeting': 'Hi {{name}} (en)',
    });
    expect(en.readAsStringSync(), startsWith('{\n  "\$schema"'));
    expect(read('src/assets/i18n/fr.json').containsKey('path'), isFalse);
  });

  test('a key only the base file holds stops the pull; --adopt imports it',
      () async {
    final File en = inApp('src/assets/i18n/en.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(<String, dynamic>{
        r'$schema': './schema.json',
        'home': <String, String>{'title': 'Hello', 'new': 'Brand new'},
      }));
    final Run refused = await fl(<String>['pull']);
    expect(refused.code, 1);
    expect(refused.err, contains('1 key(s) the service does not have'));
    expect(refused.err, contains('home.new'));
    expect(refused.err, contains('fl pull --adopt'));
    expect(backend.imports, isEmpty);
    expect(en.readAsStringSync(), contains('Brand new'));

    final Run adopted = await fl(<String>['pull', '--adopt']);
    expect(adopted.code, 0, reason: adopted.err);
    expect(backend.imports, hasLength(1));
    expect(backend.imports.single.language, 'en');
    expect(backend.imports.single.fileName, 'en.json');
    expect(backend.imports.single.body, contains('Brand new'));
    // The fake service did not take it: it is kept, not deleted.
    expect(read('src/assets/i18n/en.json')['home'],
        containsPair('new', 'Brand new'));
    expect(read('src/assets/i18n/en.json')[r'$schema'], './schema.json');

    final Run export = await fl(<String>['export', '--discard-local']);
    expect(export.code, 0, reason: export.err);
    expect(read('src/assets/i18n/en.json')['home'],
        isNot(containsPair('new', 'Brand new')));
  });

  test('export refuses to overwrite a local-only key', () async {
    inApp('src/assets/i18n/en.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"home.only": "x"}');
    final Run r = await fl(<String>['export']);
    expect(r.code, 1);
    expect(r.err, contains('home.only'));
  });

  test('import sends a JSON with the language of its name', () async {
    inApp('de.json').writeAsStringSync('{"home.title": "Hallo"}');
    inApp('frx_fr.json').writeAsStringSync('{"home": {"title": "Bonjour"}}');
    inApp('strings.json').writeAsStringSync('{"home.title": "Hello"}');

    Run r = await fl(<String>['import', 'frx_fr.json']);
    expect(r.code, 0, reason: r.err);
    expect(backend.imports.last.language, 'fr');
    expect(backend.imports.last.fileName, 'frx_fr.json');
    expect(r.out, contains('Imported as "fr"'));

    r = await fl(<String>['import', 'strings.json']);
    expect(r.code, 0, reason: r.err);
    expect(backend.imports.last.language, 'en');

    r = await fl(<String>['import', 'de.json', '--language', 'fr']);
    expect(r.code, 0, reason: r.err);
    expect(backend.imports.last.language, 'fr');

    r = await fl(<String>['import', 'de.json']);
    expect(r.code, 1);
    expect(r.out + r.err, contains('fl languages add de'));

    r = await fl(<String>['--dry-run', 'import', 'frx_fr.json']);
    expect(r.code, 0, reason: r.err);
    expect(r.out, contains('ngx-translate file'));
  });

  test('doctor does not ask an ngx-translate app for @angular/localize',
      () async {
    inApp('angular.json').writeAsStringSync('{"projects": {}}');
    inApp('package.json').writeAsStringSync(
        '{"dependencies": {"@ngx-translate/core": "^16.0.0"}}');
    final Run r = await fl(<String>['doctor']);
    expect(r.code, 0, reason: r.err);
    expect(r.out, contains('ngx-translate app'));
    expect(r.out, isNot(contains('@angular/localize')));
  });
}
