/// The `fl` binary on a Flutter project, end to end: the config file as
/// `fl init` writes it, the codegen step, clone, flavors and argument errors.
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

  Future<Run> fl(final List<String> args, {final String? cwd}) async {
    final ProcessResult r = await Process.run(
      'dart',
      <String>['run', p.join(packageRoot(), 'bin', 'fl.dart'), ...args],
      workingDirectory: cwd ?? tmp.path,
      environment: <String, String>{
        'FL_API_TOKEN': 'flk_live_test',
        'HOME': tmp.path,
      },
    );
    return Run(r.exitCode, r.stdout as String, r.stderr as String);
  }

  /// `fl` with [input] typed at its prompts and PATH replaced by [path].
  Future<Run> flWith(
    final List<String> args, {
    final String input = '',
    final String? path,
  }) async {
    final Process process = await Process.start(
      Platform.resolvedExecutable,
      <String>['run', p.join(packageRoot(), 'bin', 'fl.dart'), ...args],
      workingDirectory: tmp.path,
      environment: <String, String>{
        'FL_API_TOKEN': 'flk_live_test',
        'HOME': tmp.path,
        if (input.isNotEmpty) 'FL_INTERACTIVE': '1',
        if (path != null) 'PATH': path,
      },
    );
    process.stdin.write(input);
    await process.stdin.close();
    final List<String> streams = await Future.wait(<Future<String>>[
      process.stdout.transform(utf8.decoder).join(),
      process.stderr.transform(utf8.decoder).join(),
    ]);
    return Run(await process.exitCode, streams[0], streams[1]);
  }

  void writeConfig(final Map<String, Object> fields) =>
      File(p.join(tmp.path, 'flutterlocalisation.json'))
          .writeAsStringSync(jsonEncode(<String, Object>{
        'base_url': backend.url,
        'project': 'Gush',
        ...fields,
      }));

  /// A repo laid out the way the backend pushes it: one folder per flavor
  /// at the root. Cloning a plain working tree needs no bare repo.
  String serviceRepo(final String name) {
    final String dir = p.join(tmp.path, 'remotes', name);
    File(p.join(dir, 'Default', 'app_en.arb'))
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(<String, String>{
        '@@locale': 'en',
        'running %lld': 'Cleaning… {arg1} s left',
      }));
    for (final List<String> args in <List<String>>[
      <String>['init', '-q', '-b', 'main'],
      <String>['add', '.'],
      <String>[
        '-c',
        'user.name=t',
        '-c',
        'user.email=t@t',
        'commit',
        '-qm',
        'ARBs'
      ],
    ]) {
      final ProcessResult r =
          Process.runSync('git', args, workingDirectory: dir);
      expect(r.exitCode, 0, reason: '${r.stderr}');
    }
    return dir;
  }

  setUpAll(() async => backend = await FakeBackend.start());
  tearDownAll(() => backend.close());

  setUp(() {
    backend.platforms = <String>['flutter'];
    backend.flavors = <String>['Default'];
    backend.repoUrl = null;
    backend.languages = <String>['en'];
    backend.translateScope = true;
    backend.imports.clear();
    tmp = Directory(Directory.systemTemp
        .createTempSync('fl_cli_flutter_test')
        .resolveSymbolicLinksSync());
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  group('codegen', () {
    // A pubspec with no dependencies resolves offline, and `dart run` of a
    // package it does not list fails the same way a missing dependency does.
    const String pubspec = 'name: app\n'
        'environment:\n'
        '  sdk: ^3.4.0\n';

    test(
        'sync from another folder runs the generator in the app root with the '
        'flavor folder split off an absolute arb_dir', () async {
      File(p.join(tmp.path, 'pubspec.yaml')).writeAsStringSync(pubspec);
      writeConfig(<String, Object>{
        'arb_dir': p.join(tmp.path, 'arbs', 'Default'),
      });
      final Directory sub = Directory(p.join(tmp.path, 'lib'))..createSync();

      final Run r = await fl(<String>['sync'], cwd: sub.path);
      expect(r.code, isNot(0));
      expect(
          File(p.join(tmp.path, 'arbs', 'Default', 'app_en.arb')).existsSync(),
          isTrue,
          reason: 'the pull ran before the codegen');
      expect(r.out, contains('Regenerating Dart from arbs/Default'));
      expect(r.err, contains('Codegen failed'));
      expect(r.err, contains(tmp.path), reason: 'names where it ran');
      expect(r.err, contains('Could not find package `flutter_localisation`'),
          reason: "the generator's own output is shown");
      expect(
          r.err, contains('pubspec.yaml does not list flutter_localisation'));
      expect(r.err, contains('generate: true'),
          reason: 'the doctor check runs first');
      expect(r.err, contains('--no-codegen'));
    });

    group('an app on plain gen-l10n', () {
      late String dartOnly;

      /// A `flutter` on the PATH that prints [says] and exits with [code].
      String fakeFlutter(final int code, final String says) {
        final Directory bin = Directory(p.join(tmp.path, 'fakebin'))
          ..createSync();
        if (Platform.isWindows) {
          File(p.join(bin.path, 'flutter.bat'))
              .writeAsStringSync('@echo $says\r\n@exit /b $code\r\n');
        } else {
          final File script = File(p.join(bin.path, 'flutter'))
            ..writeAsStringSync('#!/bin/sh\necho "$says"\nexit $code\n');
          Process.runSync('chmod', <String>['+x', script.path]);
        }
        return '${bin.path}${Platform.isWindows ? ';' : ':'}$dartOnly';
      }

      setUp(() {
        // The SDK's own bin folder holds dart and no flutter.
        dartOnly = <String>[
          p.dirname(Platform.resolvedExecutable),
          if (Platform.isWindows)
            p.join(Platform.environment['SystemRoot']!, 'System32')
          else ...<String>['/usr/bin', '/bin'],
        ].join(Platform.isWindows ? ';' : ':');
        File(p.join(tmp.path, 'pubspec.yaml')).writeAsStringSync(pubspec);
        File(p.join(tmp.path, 'l10n.yaml'))
            .writeAsStringSync('arb-dir: lib/l10n\n');
        writeConfig(<String, Object>{'arb_dir': 'lib/l10n'});
      });

      test('sync ends with flutter gen-l10n, not the package generator',
          () async {
        final Run r =
            await flWith(<String>['sync'], path: fakeFlutter(0, 'generated'));
        expect(r.code, 0, reason: r.err);
        expect(r.out, contains('Regenerating Dart with `flutter gen-l10n`'));
        expect('${r.out}${r.err}', isNot(contains('Could not find package')));
      });

      test('a failing gen-l10n fails the sync and shows what it said',
          () async {
        final Run r = await flWith(<String>['sync'],
            path: fakeFlutter(3, 'template missing'));
        expect(r.code, 3);
        expect(r.err, contains('`flutter gen-l10n` failed (exit 3)'));
        expect(r.err, contains('template missing'));
      });

      test('without flutter on the PATH the files are synced and it says so',
          () async {
        final Run r = await flWith(<String>['sync'], path: dartOnly);
        expect(r.code, 0, reason: r.err);
        expect(r.out, contains('`flutter` is not on the PATH here.'));
        expect(File(p.join(tmp.path, 'lib', 'l10n', 'app_en.arb')).existsSync(),
            isTrue);
      });
    });

    test('the dependency hint is left out when the pubspec has it', () async {
      File(p.join(tmp.path, 'pubspec.yaml')).writeAsStringSync('$pubspec'
          'dependencies:\n'
          '  flutter_localisation:\n'
          '    path: missing_folder\n'
          'flutter:\n'
          '  generate: true\n');
      writeConfig(<String, Object>{'arb_dir': 'arbs/Default'});

      final Run r = await fl(<String>['sync']);
      expect(r.code, isNot(0));
      expect(r.err, contains('Codegen failed'));
      expect(r.err, isNot(contains('does not list flutter_localisation')));
      expect(r.err, isNot(contains('generate: true')));
    });
  });

  group('flavor', () {
    test('init stores the flavor it picked', () async {
      final Run r = await fl(<String>[
        'init',
        '--yes',
        '--no-pull',
        '--base-url',
        backend.url,
      ]);
      expect(r.code, 0, reason: r.err);
      final Map<String, dynamic> cfg = jsonDecode(
          File(p.join(tmp.path, 'flutterlocalisation.json'))
              .readAsStringSync()) as Map<String, dynamic>;
      expect(cfg['flavor'], 'Default');
      expect(cfg['arb_dir'], 'arbs/Default');
    });

    test(
        'an older config without "flavor" keeps working once a second flavor '
        'exists: arb_dir names it', () async {
      backend.flavors = <String>['Default', 'staging'];
      writeConfig(<String, Object>{'project_id': 7, 'arb_dir': 'arbs/Default'});
      final Run r = await fl(<String>['--json', 'languages', 'list']);
      expect(r.code, 0, reason: r.err);
      expect(r.json['flavor'], 'Default');
    });

    test('"flavor" in the config wins over the arb_dir folder', () async {
      backend.flavors = <String>['Default', 'staging'];
      writeConfig(<String, Object>{
        'project_id': 7,
        'flavor': 'staging',
        'arb_dir': 'arbs/Default',
      });
      final Run r = await fl(<String>['--json', 'languages', 'list']);
      expect(r.code, 0, reason: r.err);
      expect(r.json['flavor'], 'staging');
    });

    test('with neither, the error says how to choose', () async {
      backend.flavors = <String>['Default', 'staging'];
      writeConfig(<String, Object>{'project_id': 7, 'arb_dir': 'lib/l10n'});
      final Run r = await fl(<String>['languages', 'list']);
      expect(r.code, isNot(0));
      expect(r.err, contains('--flavor'));
    });
  });

  group('arguments', () {
    test('edit without --locale edits the base language', () async {
      writeConfig(<String, Object>{'project_id': 7, 'arb_dir': 'arbs/Default'});
      final Run r = await fl(<String>[
        '--dry-run',
        'edit',
        'running',
        '--value',
        '{arg1} s to go',
      ]);
      expect(r.code, 0, reason: r.err);
      expect(r.out, contains('would update "running %lld" [en]'));
    });

    test('a missing mandatory option prints usage and exits 64, no trace',
        () async {
      final Run r = await fl(<String>['login']);
      expect(r.code, 64);
      expect(r.err, contains('Option token is mandatory'));
      expect(r.err, contains('Usage: fl login'));
      expect(r.err, isNot(contains('#0 ')), reason: 'no stack trace');
    });

    test('an unknown option is a usage error too', () async {
      final Run r = await fl(<String>['edit', 'k', '--nope']);
      expect(r.code, 64);
      expect(r.err, contains('Could not find an option named "--nope"'));
    });
  });

  group('clone', () {
    test('clones into the folder above the flavor folder arb_dir names',
        () async {
      backend.repoUrl = serviceRepo('arbs');
      writeConfig(<String, Object>{'project_id': 7, 'arb_dir': 'arbs/Default'});
      final Run r = await fl(<String>['clone']);
      expect(r.code, 0, reason: r.err);
      expect(
          File(p.join(tmp.path, 'arbs', 'Default', 'app_en.arb')).existsSync(),
          isTrue);
      expect(
          Directory(p.join(tmp.path, 'arbs', 'Default', 'Default'))
              .existsSync(),
          isFalse);
      expect(r.out, contains('Add "/arbs/" to .gitignore'));

      final Run pull = await fl(<String>['pull']);
      expect(pull.code, 0, reason: pull.err);
      expect(pull.out, contains('Synced'), reason: 'pull finds the same clone');
    });

    test('an arb_dir that is not a flavor folder is the clone itself',
        () async {
      backend.repoUrl = serviceRepo('arbs');
      writeConfig(<String, Object>{'project_id': 7, 'arb_dir': 'translations'});
      final Run r = await fl(<String>['clone']);
      expect(r.code, 0, reason: r.err);
      expect(
          File(p.join(tmp.path, 'translations', 'Default', 'app_en.arb'))
              .existsSync(),
          isTrue);
    });

    test('a failed clone shows what git said and a way forward', () async {
      backend.repoUrl = p.join(tmp.path, 'no_such_repo');
      writeConfig(<String, Object>{'project_id': 7, 'arb_dir': 'arbs/Default'});
      final Run r = await fl(<String>['clone']);
      expect(r.code, isNot(0));
      expect(r.err, contains('git clone'));
      expect(r.err, contains('fl pull --no-git'));
    });
  });

  group('pull after the project was relinked', () {
    setUp(() async {
      backend.repoUrl = serviceRepo('github');
      writeConfig(<String, Object>{'project_id': 7, 'arb_dir': 'arbs/Default'});
      final Run r = await fl(<String>['clone']);
      expect(r.code, 0, reason: r.err);
    });

    test('refuses the stale clone, names both repos and the fix', () async {
      final String moved = serviceRepo('gitlab');
      backend.repoUrl = moved;
      final Run r = await fl(<String>['pull']);
      expect(r.code, 1);
      expect(r.err, contains(p.join(tmp.path, 'remotes', 'github')));
      expect(r.err, contains(moved));
      expect(r.err, contains('remote set-url origin $moved'));
      expect(r.err, contains('fl clone'));
      expect(r.out, isNot(contains('Synced')));

      final Run json = await fl(<String>['--json', 'pull']);
      expect(json.code, 1);
      expect(json.json['error'], 'repo_mismatch');
      expect(json.json['project_repo'], moved);
      expect(json.json['local_origin'], p.join(tmp.path, 'remotes', 'github'));

      final ProcessResult fix = Process.runSync('git', <String>[
        '-C',
        p.join(tmp.path, 'arbs'),
        'remote',
        'set-url',
        'origin',
        moved
      ]);
      expect(fix.exitCode, 0);
      final Run again = await fl(<String>['pull']);
      expect(again.code, 0, reason: again.err);
      expect(again.out, contains('Synced'));
    });

    test('a key only the old repo has is not offered for adoption', () async {
      backend.repoUrl = serviceRepo('gitlab');
      final File template =
          File(p.join(tmp.path, 'arbs', 'Default', 'app_en.arb'));
      final Map<String, dynamic> arb =
          jsonDecode(template.readAsStringSync()) as Map<String, dynamic>;
      template.writeAsStringSync(jsonEncode(<String, dynamic>{
        ...arb,
        'onlyInTheOldRepo': 'x',
      }));
      final Run r = await fl(<String>['pull']);
      expect(r.code, 1);
      expect(r.err, contains('is now linked to'));
      expect(r.err, isNot(contains('--adopt')));
    });

    test('the same repo spelled differently is not a change', () async {
      backend.repoUrl = 'file://${p.join(tmp.path, 'remotes', 'github')}.git';
      final Run r = await fl(<String>['pull']);
      expect(r.code, 0, reason: r.err);
      expect(r.out, contains('Synced'));
    });

    test('--no-git skips the check and writes from the API', () async {
      backend.repoUrl = serviceRepo('gitlab');
      final Run r = await fl(<String>['pull', '--no-git']);
      expect(r.code, 0, reason: r.err);
    });
  });

  group('an app that already has ARBs', () {
    late Directory l10n;

    void arb(final String name, final Map<String, String> strings) =>
        File(p.join(l10n.path, name)).writeAsStringSync(jsonEncode(strings));

    setUp(() {
      backend.languages = <String>['de', 'en', 'fr'];
      l10n = Directory(p.join(tmp.path, 'lib', 'l10n'))
        ..createSync(recursive: true);
      arb('app_de.arb', <String, String>{'@@locale': 'de', 'title': 'Titel'});
      arb('app_en.arb', <String, String>{'@@locale': 'en', 'title': 'Title'});
    });

    test('init imports them without first telling the user to pick a command',
        () async {
      final Run r = await fl(<String>[
        'init',
        '--yes',
        '--base-url',
        backend.url,
        '--arb-dir',
        'lib/l10n',
      ]);
      expect(r.code, 0, reason: r.err);
      expect(r.out,
          contains('app_de.arb has 1 key(s) the service does not have yet.'));
      expect('${r.out}${r.err}', isNot(contains('Either:')));
      expect('${r.out}${r.err}', isNot(contains('--discard-local')));
      expect(r.out, contains('app_en.arb (en):'));
    });

    test('answering no at the prompt imports nothing and says what to run',
        () async {
      final Run r = await flWith(
        <String>['init', '--base-url', backend.url, '--arb-dir', 'lib/l10n'],
        input: 'n\n',
      );
      expect(r.code, 1);
      expect(r.out, contains('Import them (and the translations in the ARBs'));
      expect(r.err, contains('Nothing was imported or pulled.'));
      expect(r.err, contains('fl pull --adopt'));
      expect(backend.imports, isEmpty);
      expect(File(p.join(l10n.path, 'app_de.arb')).readAsStringSync(),
          contains('Titel'));
    });

    test('answering yes at the prompt imports the base and its translations',
        () async {
      final Run r = await flWith(
        <String>[
          'init',
          '--base-url',
          backend.url,
          '--arb-dir',
          'lib/l10n',
        ],
        input: 'y\nn\nn\nn\n',
      );
      expect(r.code, 0, reason: r.err);
      expect(backend.imports.map((final ReceivedImport i) => i.language),
          containsAllInOrder(<String>['de', 'en']));
    });

    test('a plain pull still names both commands', () async {
      writeConfig(<String, Object>{'project_id': 7, 'arb_dir': 'lib/l10n'});
      final Run r = await fl(<String>['pull']);
      expect(r.code, 1);
      expect(r.err, contains('Either:'));
      expect(r.err, contains('fl pull --adopt'));
      expect(r.err, contains('fl pull --discard-local'));
      expect(backend.imports, isEmpty);
    });

    test(
        'adopt imports each local ARB as its own language and asks for '
        'translation only for the language with no file', () async {
      writeConfig(<String, Object>{'project_id': 7, 'arb_dir': 'lib/l10n'});
      final Run r = await fl(<String>['pull', '--adopt']);
      expect(r.code, 0, reason: r.err);
      expect(
          backend.imports
              .map((final ReceivedImport i) =>
                  '${i.language}${i.autoTranslate ? ' +translate' : ''}')
              .toList(),
          <String>['de', 'en', 'de +translate']);
      expect(r.out, contains('app_de.arb (de, base):'));
      expect(r.out, contains('app_en.arb (en):'));
      expect(r.out, isNot(contains('Not translated')));
    });

    test('a token without the Translate scope still gets its strings imported',
        () async {
      backend.translateScope = false;
      writeConfig(<String, Object>{'project_id': 7, 'arb_dir': 'lib/l10n'});
      final Run r = await fl(<String>['pull', '--adopt']);
      expect(r.code, 0, reason: r.err);
      expect(
          backend.imports.map((final ReceivedImport i) => i.language).toList(),
          <String>['de', 'en']);
      expect(
          r.out,
          contains('Not translated: this token does not have the Translate '
              'scope, so the base text is still in fr.'));
      expect(r.out, contains('fl retranslate'));
      expect(r.err, isNot(contains('Hint: your token may lack')));
    });

    test('import reads the language of the file from its name', () async {
      writeConfig(<String, Object>{'project_id': 7, 'arb_dir': 'lib/l10n'});
      arb('app_en.arb', <String, String>{'title': 'Title'});
      final Run r = await fl(<String>['import', 'lib/l10n/app_en.arb']);
      expect(r.code, 0, reason: r.err);
      expect(backend.imports.single.language, 'en');
      expect(
          r.out,
          contains('Imported as "en" (from the file name). Pass --language to '
              'choose another.'));
    });

    test('--language wins over what the file says', () async {
      writeConfig(<String, Object>{'project_id': 7, 'arb_dir': 'lib/l10n'});
      final Run r = await fl(
          <String>['import', 'lib/l10n/app_en.arb', '--language', 'de']);
      expect(r.code, 0, reason: r.err);
      expect(backend.imports.single.language, 'de');
      expect(r.out, isNot(contains('Imported as')));
    });

    test('import refuses a file in a language the project does not have',
        () async {
      writeConfig(<String, Object>{'project_id': 7, 'arb_dir': 'lib/l10n'});
      arb('app_it.arb', <String, String>{'@@locale': 'it', 'title': 'Titolo'});
      final Run r = await fl(<String>['import', 'lib/l10n/app_it.arb']);
      expect(r.code, 1);
      expect(backend.imports, isEmpty);
      expect(r.out, contains('app_it.arb holds "it" (from @@locale)'));
      expect(r.out, contains('fl languages add it'));
      expect(r.out, contains('--language de'));
    });
  });

  test("arb_dir inside the app's own repo is written from the API", () async {
    backend.repoUrl = serviceRepo('github');
    for (final List<String> args in <List<String>>[
      <String>['init', '-q'],
      <String>['remote', 'add', 'origin', 'https://github.com/acme/app.git'],
    ]) {
      expect(
          Process.runSync('git', args, workingDirectory: tmp.path).exitCode, 0);
    }
    Directory(p.join(tmp.path, 'lib', 'l10n')).createSync(recursive: true);
    writeConfig(<String, Object>{'project_id': 7, 'arb_dir': 'lib/l10n'});
    final Run r = await fl(<String>['pull']);
    expect(r.code, 0, reason: r.err);
    expect(r.out, contains("arb_dir is in the app's own repo"));
    expect(File(p.join(tmp.path, 'lib', 'l10n', 'app_en.arb')).existsSync(),
        isTrue);
  });
}
