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
}
