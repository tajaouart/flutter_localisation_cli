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
}
