/// `fl pull` the way a build agent runs it: a fresh checkout, the token in the
/// environment, nobody at the keyboard, and a network that is allowed to fail.
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fake_backend.dart';

class Run {
  Run(this.code, this.out, this.err, this.took);

  final int code;
  final String out;
  final String err;
  final Duration took;

  /// The whole of stdout, which `--json` promises is one object.
  Map<String, dynamic> get json => jsonDecode(out) as Map<String, dynamic>;
}

void main() {
  late FakeBackend backend;
  late Directory tmp;
  late String checkout;

  /// `fl` in the checkout with stdin closed, as under a CI runner.
  Future<Run> fl(
    final List<String> args, {
    final Map<String, String> env = const <String, String>{},
  }) async {
    final Stopwatch watch = Stopwatch()..start();
    final Process process = await Process.start(
      Platform.resolvedExecutable,
      <String>['run', p.join(packageRoot(), 'bin', 'fl.dart'), ...args],
      workingDirectory: checkout,
      environment: <String, String>{
        'FL_API_TOKEN': 'flk_live_test',
        'HOME': tmp.path,
        'USERPROFILE': tmp.path,
        ...env,
      },
    );
    await process.stdin.close();
    final List<String> streams = await Future.wait(<Future<String>>[
      process.stdout.transform(utf8.decoder).join(),
      process.stderr.transform(utf8.decoder).join(),
    ]);
    return Run(await process.exitCode, streams[0], streams[1], watch.elapsed);
  }

  void git(final List<String> args, {final String? cwd}) {
    final ProcessResult r = Process.runSync(
      'git',
      <String>['-c', 'user.name=t', '-c', 'user.email=t@t', ...args],
      workingDirectory: cwd ?? checkout,
    );
    expect(r.exitCode, 0, reason: 'git ${args.join(' ')}: ${r.stderr}');
  }

  String gitOut(final List<String> args) => '${Process.runSync(
        'git',
        args,
        workingDirectory: checkout,
      ).stdout}'
          .trim();

  void writeConfig([final Map<String, Object> fields = const {}]) =>
      File(p.join(checkout, 'flutterlocalisation.json'))
          .writeAsStringSync(jsonEncode(<String, Object>{
        'base_url': backend.url,
        'project': 'Gush',
        'arb_dir': 'lib/l10n',
        ...fields,
      }));

  File arbFile(final String name) =>
      File(p.join(checkout, 'lib', 'l10n', name));

  /// No Dart stack trace reached the build log.
  void expectNoTrace(final Run r) {
    expect(r.err, isNot(contains('#0 ')));
    expect(r.err, isNot(contains('Unhandled exception')));
  }

  setUpAll(() async => backend = await FakeBackend.start());
  tearDownAll(() => backend.close());

  setUp(() {
    backend.platforms = <String>['flutter'];
    backend.flavors = <String>['Default'];
    backend.languages = <String>['en', 'de'];
    backend.repoUrl = null;
    backend.faults.clear();
    backend.latestVersion = null;
    backend.minimumVersion = null;
    backend.notice = null;
    backend.clients.clear();
    backend.userAgents.clear();
    backend.requests.clear();
    backend.imports.clear();
    tmp = Directory(Directory.systemTemp
        .createTempSync('fl_cli_pipeline_test')
        .resolveSymbolicLinksSync());
    checkout = p.join(tmp.path, 'app');
    Directory(checkout).createSync();
    writeConfig();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  group('a build agent', () {
    test('pulls the ARBs with one download of the project', () async {
      final Run r = await fl(<String>['pull']);
      expect(r.code, 0, reason: r.err);
      expect(arbFile('app_en.arb').existsSync(), isTrue);
      expect(arbFile('app_de.arb').existsSync(), isTrue);
      expect(
        backend.requests,
        <String>['GET /api/projects/', 'GET /api/projects/7/'],
      );
    });

    test('a second pull changes no byte', () async {
      expect((await fl(<String>['pull'])).code, 0);
      final String first = arbFile('app_en.arb').readAsStringSync();
      final Run again = await fl(<String>['pull']);
      expect(again.code, 0, reason: again.err);
      expect(arbFile('app_en.arb').readAsStringSync(), first);
    });

    test('needs no more than a read-only token', () async {
      final Run r = await fl(
        <String>['pull'],
        env: <String, String>{'FL_API_TOKEN': kReadOnlyToken},
      );
      expect(r.code, 0, reason: r.err);
      expect(backend.requests.where((final String q) => !q.startsWith('GET')),
          isEmpty);
    });

    test('--json prints one object a script can read', () async {
      final Run r = await fl(<String>['--json', 'pull']);
      expect(r.code, 0, reason: r.err);
      expect(r.json['ok'], isTrue);
      expect(r.json['method'], 'api');
      expect(r.json['files'], hasLength(2));
    });

    test('--flavor picks one flavor of several', () async {
      backend.flavors = <String>['Default', 'staging'];
      final Run r = await fl(<String>['--flavor', 'staging', 'pull']);
      expect(r.code, 0, reason: r.err);
      expect(arbFile('app_en.arb').existsSync(), isTrue);
    });

    test('--dry-run writes nothing', () async {
      final Run r = await fl(<String>['--dry-run', 'pull']);
      expect(r.code, 0, reason: r.err);
      expect(arbFile('app_en.arb').existsSync(), isFalse);
    });
  });

  group('the token', () {
    test('missing: exit 1 and the variable to set', () async {
      final Run r =
          await fl(<String>['pull'], env: <String, String>{'FL_API_TOKEN': ''});
      expect(r.code, 1);
      expect(r.err, contains(r'$FL_API_TOKEN'));
      expectNoTrace(r);
      expect(backend.requests, isEmpty);
    });

    test('revoked: exit 1 and where it was read from', () async {
      final Run r = await fl(
        <String>['pull'],
        env: <String, String>{'FL_API_TOKEN': 'flk_live_revoked'},
      );
      expect(r.code, 1);
      expect(r.err, contains(r'The token from $FL_API_TOKEN was rejected'));
      expectNoTrace(r);
      expect(arbFile('app_en.arb').existsSync(), isFalse);
    });

    test('never reaches the log', () async {
      final Run r = await fl(
        <String>['pull'],
        env: <String, String>{'FL_API_TOKEN': 'flk_live_revoked'},
      );
      expect('${r.out}${r.err}', isNot(contains('flk_live_revoked')));
    });
  });

  group('a network that fails', () {
    test('two 502s, then an answer: the pull succeeds', () async {
      backend.faults
        ..add(const Fault(502))
        ..add(const Fault(502));
      final Run r = await fl(<String>['pull']);
      expect(r.code, 0, reason: r.err);
      expect(arbFile('app_en.arb').existsSync(), isTrue);
    });

    test('a short rate limit is waited out', () async {
      backend.faults.add(const Fault(429, retryAfter: 1));
      final Run r = await fl(<String>['pull']);
      expect(r.code, 0, reason: r.err);
      expect(r.err, contains('Rate limited; retrying in 1s'));
    });

    test('a long rate limit fails at once and says for how long', () async {
      backend.faults.add(const Fault(429, retryAfter: 2700));
      final Run r = await fl(<String>['pull']);
      expect(r.code, 1);
      expect(r.err, contains('45 min'));
      expect(r.took, lessThan(const Duration(seconds: 60)));
      expectNoTrace(r);
    });

    test('a service that stays down: exit 1, nothing half written', () async {
      backend.faults.addAll(List<Fault>.filled(8, const Fault(503)));
      final Run r = await fl(<String>['pull']);
      expect(r.code, 1);
      expectNoTrace(r);
      expect(arbFile('app_en.arb').existsSync(), isFalse);
    });

    test('nothing listening: exit 1 with the cause', () async {
      final ServerSocket probe =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final int port = probe.port;
      await probe.close();
      writeConfig(<String, Object>{'base_url': 'http://127.0.0.1:$port'});
      final Run r = await fl(<String>['pull']);
      expect(r.code, 1);
      expect(r.err, contains('Network error'));
      expectNoTrace(r);
    });

    test('a request that never gets an answer ends at the timeout', () async {
      backend.faults.add(const Fault.stall());
      final Run r = await fl(
        <String>['pull'],
        env: <String, String>{'FL_HTTP_TIMEOUT': '3'},
      );
      expect(r.code, 1);
      expect(r.err, contains('No answer from ${backend.url} after 3s'));
      expect(r.took, lessThan(const Duration(seconds: 60)));
      expectNoTrace(r);
      // Not retried: one request went out.
      expect(backend.requests, hasLength(1));
    });

    test('a proxy page instead of JSON is named as such', () async {
      backend.faults.add(const Fault(
        200,
        body: '<html><body>Blocked by policy</body></html>',
        contentType: 'text/html',
      ));
      final Run r = await fl(<String>['pull']);
      expect(r.code, 1);
      expect(r.err, contains('text/html that is not JSON'));
      expectNoTrace(r);
    });

    test('HTTP_PROXY is honoured', () async {
      // The API host does not resolve: only a request sent to the proxy,
      // played here by the backend itself, can succeed.
      writeConfig(<String, Object>{'base_url': 'http://fl-api.invalid'});
      final Run r = await fl(
        <String>['pull'],
        env: <String, String>{'http_proxy': backend.url, 'no_proxy': ''},
      );
      expect(r.code, 0, reason: r.err);
      expect(arbFile('app_en.arb').existsSync(), isTrue);
    });
  });

  group('versions', () {
    final String version = RegExp(r'^version: (\S+)', multiLine: true)
        .firstMatch(
            File(p.join(packageRoot(), 'pubspec.yaml')).readAsStringSync())!
        .group(1)!;

    test('--version prints the version in pubspec.yaml', () async {
      final Run r = await fl(<String>['--version']);
      expect(r.code, 0);
      expect(r.out.trim(), 'fl $version');
      expect(backend.requests, isEmpty);
    });

    test('every request names the client and its version', () async {
      expect((await fl(<String>['pull'])).code, 0);
      expect(backend.clients, everyElement('fl/$version'));
      expect(backend.userAgents,
          everyElement(matches('^fl/$version \\(dart [0-9.]+; [a-z]+\\)\$')));
    });

    test('a newer version is announced on stderr and the build passes',
        () async {
      backend
        ..latestVersion = '99.0.0'
        ..notice = 'Fixes stale strings in CI.';
      final Run r = await fl(<String>['--json', 'pull']);
      expect(r.code, 0, reason: r.err);
      expect(r.json['ok'], isTrue);
      expect(
        r.err,
        contains('fl 99.0.0 is available (this is $version). '
            'Fixes stale strings in CI.\n'
            'Update with: dart pub global activate flutter_localisation_cli'),
      );
      expect('fl 99.0.0 is available'.allMatches(r.err), hasLength(1));
    });

    test('nothing is announced when this is the latest, or an older one',
        () async {
      backend.latestVersion = version;
      expect((await fl(<String>['pull'])).err, isNot(contains('available')));
      backend.latestVersion = '1.9.0';
      expect((await fl(<String>['pull'])).err, isNot(contains('available')));
    });

    test('FL_NO_UPDATE_NOTICE keeps the line out of the log', () async {
      backend.latestVersion = '99.0.0';
      final Run r = await fl(
        <String>['pull'],
        env: <String, String>{'FL_NO_UPDATE_NOTICE': '1'},
      );
      expect(r.code, 0, reason: r.err);
      expect(r.err, isNot(contains('available')));
    });

    test('the notice also follows a command that failed', () async {
      backend.latestVersion = '99.0.0';
      arbFile('app_en.arb')
        ..createSync(recursive: true)
        ..writeAsStringSync('{"@@locale": "en", "addedByHand": "New"}');
      final Run r = await fl(<String>['pull']);
      expect(r.code, 1);
      expect(r.err, contains('addedByHand'));
      expect(r.err, contains('fl 99.0.0 is available'));
    });

    test('a withdrawn version is refused: exit 1 and the command to run',
        () async {
      backend
        ..latestVersion = '99.0.0'
        ..minimumVersion = '99.0.0';
      final Run r = await fl(<String>['pull']);
      expect(r.code, 1);
      expect(r.err, contains('fl $version is no longer supported'));
      expect(
          r.err, contains('dart pub global activate flutter_localisation_cli'));
      // Said once, by the refusal; not retried.
      expect(r.err, isNot(contains('is available')));
      expect(backend.requests, hasLength(1));
      expect(arbFile('app_en.arb').existsSync(), isFalse);
      expectNoTrace(r);
    });

    test('upgrade --dry-run names the command and runs nothing', () async {
      final Run r = await fl(<String>['--dry-run', 'upgrade']);
      expect(r.code, 0);
      expect(
          r.out, contains('dart pub global activate flutter_localisation_cli'));
    });

    test('upgrade installs the published version', () async {
      final Run r = await fl(<String>['upgrade']);
      expect(r.code, 0, reason: r.err);
      expect(r.out, contains('Activated flutter_localisation_cli'));
    },
        skip: Platform.environment['FL_TEST_NETWORK'] == '1'
            ? false
            : 'installs from pub.dev; CI sets FL_TEST_NETWORK=1');
  });

  group('the checkout is the app\'s own git repository', () {
    late String origin;

    /// An app repo with ARBs committed, cloned the way an agent clones it.
    setUp(() {
      origin = p.join(tmp.path, 'origin');
      Directory(origin).createSync();
      File(p.join(origin, 'lib', 'main.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('void main() {}\n');
      File(p.join(origin, 'lib', 'l10n', 'app_en.arb'))
        ..createSync(recursive: true)
        ..writeAsStringSync(jsonEncode(<String, String>{
          '@@locale': 'en',
          'running %lld': 'Old text',
        }));
      git(<String>['init', '-q', '-b', 'main'], cwd: origin);
      git(<String>['add', '.'], cwd: origin);
      git(<String>['commit', '-qm', 'app'], cwd: origin);
      Directory(checkout).deleteSync(recursive: true);
      git(<String>['clone', '-q', origin, checkout], cwd: tmp.path);
      writeConfig();
    });

    test('a feature branch stays checked out, with its commits and edits',
        () async {
      git(<String>['checkout', '-q', '-b', 'feature']);
      File(p.join(checkout, 'lib', 'feature.dart')).writeAsStringSync('// f\n');
      git(<String>['add', '.']);
      git(<String>['commit', '-qm', 'feature work']);
      File(p.join(checkout, 'lib', 'main.dart'))
          .writeAsStringSync('void main() { /* edited */ }\n');
      final String head = gitOut(<String>['rev-parse', 'HEAD']);

      final Run r = await fl(<String>['pull']);
      expect(r.code, 0, reason: r.err);
      expect(gitOut(<String>['rev-parse', 'HEAD']), head);
      expect(File(p.join(checkout, 'lib', 'main.dart')).readAsStringSync(),
          contains('edited'));
      expect(arbFile('app_en.arb').readAsStringSync(), contains('Cleaning'));
      expect(r.out, isNot(contains('Synced')));
    });

    test('a detached HEAD, as CI checks out a commit, is not moved', () async {
      git(<String>['checkout', '-q', '-b', 'feature']);
      File(p.join(checkout, 'lib', 'feature.dart')).writeAsStringSync('// f\n');
      git(<String>['add', '.']);
      git(<String>['commit', '-qm', 'feature work']);
      git(<String>['checkout', '-q', '--detach']);
      final String head = gitOut(<String>['rev-parse', 'HEAD']);

      final Run r = await fl(<String>['pull']);
      expect(r.code, 0, reason: r.err);
      expect(gitOut(<String>['rev-parse', 'HEAD']), head);
      expect(
          File(p.join(checkout, 'lib', 'feature.dart')).existsSync(), isTrue);
      expect(arbFile('app_en.arb').existsSync(), isTrue);
    });

    test('the same holds when the project is linked to an ARB repo', () async {
      backend.repoUrl = 'https://github.com/acme/arbs.git';
      File(p.join(checkout, 'lib', 'main.dart'))
          .writeAsStringSync('void main() { /* edited */ }\n');
      final Run r = await fl(<String>['pull']);
      expect(r.code, 0, reason: r.err);
      expect(File(p.join(checkout, 'lib', 'main.dart')).readAsStringSync(),
          contains('edited'));
      expect(arbFile('app_en.arb').readAsStringSync(), contains('Cleaning'));
    });

    test('a key committed to the ARB but never imported fails the build',
        () async {
      arbFile('app_en.arb')
        ..createSync(recursive: true)
        ..writeAsStringSync(jsonEncode(<String, String>{
          '@@locale': 'en',
          'running %lld': 'Cleaning… {arg1} s left',
          'addedByHand': 'New',
        }));
      final Run r = await fl(<String>['pull']);
      expect(r.code, 1);
      expect(r.err, contains('addedByHand'));
      expect(arbFile('app_en.arb').readAsStringSync(), contains('addedByHand'));
    });
  });

  group('the project is linked and the agent holds no clone', () {
    test('a plain arb_dir is written from the API', () async {
      backend.repoUrl = 'https://github.com/acme/arbs.git';
      final Run r = await fl(<String>['pull']);
      expect(r.code, 0, reason: r.err);
      expect(r.out, contains('writing the files from the API instead'));
      expect(arbFile('app_en.arb').existsSync(), isTrue);
    });
  });
}
