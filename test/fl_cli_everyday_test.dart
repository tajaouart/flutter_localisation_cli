/// `fl` the way a developer or a coding agent types it, command after
/// command in one checkout: what each one prints, and how often it mentions a
/// newer version.
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

  Map<String, dynamic> get json => jsonDecode(out) as Map<String, dynamic>;
}

void main() {
  late FakeBackend backend;
  late Directory tmp;
  late String checkout;

  /// Not a build: the variables a CI runner sets are emptied, whatever runs
  /// this test.
  Future<Run> fl(
    final List<String> args, {
    final Map<String, String> env = const <String, String>{},
  }) async {
    final Process process = await Process.start(
      Platform.resolvedExecutable,
      <String>['run', p.join(packageRoot(), 'bin', 'fl.dart'), ...args],
      workingDirectory: checkout,
      environment: <String, String>{
        'FL_API_TOKEN': 'flk_live_test',
        'HOME': tmp.path,
        'USERPROFILE': tmp.path,
        'CI': '',
        'TF_BUILD': '',
        ...env,
      },
    );
    await process.stdin.close();
    final List<String> streams = await Future.wait(<Future<String>>[
      process.stdout.transform(utf8.decoder).join(),
      process.stderr.transform(utf8.decoder).join(),
    ]);
    return Run(await process.exitCode, streams[0], streams[1]);
  }

  File stamp() => File(
      p.join(tmp.path, '.config', 'flutterlocalisation', 'update_notice.json'));

  setUpAll(() async => backend = await FakeBackend.start());
  tearDownAll(() => backend.close());

  setUp(() {
    backend
      ..platforms = <String>['flutter']
      ..flavors = <String>['Default']
      ..languages = <String>['en', 'de', 'fr']
      ..targets = <String, Map<String, dynamic>>{}
      ..projectInstructions = ''
      ..latestVersion = null
      ..minimumVersion = null
      ..notice = null;
    backend.translated.clear();
    backend.requests.clear();
    backend.faults.clear();
    tmp = Directory(Directory.systemTemp
        .createTempSync('fl_cli_everyday_test')
        .resolveSymbolicLinksSync());
    checkout = p.join(tmp.path, 'app');
    Directory(checkout).createSync();
    File(p.join(checkout, 'flutterlocalisation.json'))
        .writeAsStringSync(jsonEncode(<String, Object>{
      'base_url': backend.url,
      'project': 'Gush',
      'arb_dir': 'lib/l10n',
    }));
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  group('a newer version', () {
    test('is said once a day at a desk, not after every command', () async {
      backend.latestVersion = '99.0.0';
      final Run first = await fl(<String>['status']);
      expect(first.code, 0, reason: first.err);
      expect(first.err, contains('fl 99.0.0 is available'));

      for (final List<String> command in <List<String>>[
        <String>['status'],
        <String>['style', 'list'],
        <String>['languages', 'list'],
      ]) {
        final Run next = await fl(command);
        expect(next.code, 0, reason: next.err);
        expect(next.err, isEmpty, reason: 'fl ${command.join(' ')}');
      }
    });

    test('is said again the next day', () async {
      backend.latestVersion = '99.0.0';
      expect((await fl(<String>['status'])).err, contains('is available'));
      final Map<String, dynamic> seen =
          jsonDecode(stamp().readAsStringSync()) as Map<String, dynamic>;
      expect(seen['latest'], '99.0.0');
      stamp().writeAsStringSync(jsonEncode(<String, Object>{
        'latest': '99.0.0',
        'at': DateTime.now()
            .subtract(const Duration(hours: 25))
            .millisecondsSinceEpoch,
      }));
      expect((await fl(<String>['status'])).err, contains('is available'));
      expect((await fl(<String>['status'])).err, isEmpty);
    });

    test('is said again when a newer one still comes out', () async {
      backend.latestVersion = '99.0.0';
      expect((await fl(<String>['status'])).err, contains('fl 99.0.0'));
      backend.latestVersion = '99.1.0';
      expect((await fl(<String>['status'])).err, contains('fl 99.1.0'));
      expect((await fl(<String>['status'])).err, isEmpty);
    });

    test('is said on every run of a build', () async {
      backend.latestVersion = '99.0.0';
      for (final Map<String, String> env in <Map<String, String>>[
        <String, String>{'CI': 'true'},
        <String, String>{'TF_BUILD': 'True'},
      ]) {
        for (int i = 0; i < 2; i++) {
          expect((await fl(<String>['status'], env: env)).err,
              contains('is available'),
              reason: '$env, run $i');
        }
      }
      expect(stamp().existsSync(), isFalse);
    });

    test('is said every time when the service says why it matters', () async {
      backend
        ..latestVersion = '99.0.0'
        ..notice = 'Fixes stale strings.';
      for (int i = 0; i < 2; i++) {
        expect((await fl(<String>['status'])).err,
            contains('Fixes stale strings.'));
      }
    });

    test('a stamp that cannot be read does not silence it', () async {
      backend.latestVersion = '99.0.0';
      stamp()
        ..createSync(recursive: true)
        ..writeAsStringSync('not json');
      expect((await fl(<String>['status'])).err, contains('is available'));
      expect((await fl(<String>['status'])).err, isEmpty);
    });

    test('FL_NO_UPDATE_NOTICE still silences a build', () async {
      backend.latestVersion = '99.0.0';
      final Run r = await fl(<String>['status'],
          env: <String, String>{'CI': 'true', 'FL_NO_UPDATE_NOTICE': '1'});
      expect(r.err, isEmpty);
    });
  });

  group('a command group on its own lists', () {
    test('fl style', () async {
      backend.projectInstructions = 'Never use a dash.';
      final Run bare = await fl(<String>['style']);
      expect(bare.code, 0, reason: bare.err);
      expect(bare.err, isEmpty);
      expect(
        bare.out,
        '  every language: Never use a dash.\n'
        "  en: translator's choice\n"
        '  de: informal\n'
        "  fr: translator's choice\n",
      );
      expect((await fl(<String>['style', 'list'])).out, bare.out);
    });

    test('fl style --json, with the flag on either side', () async {
      for (final List<String> args in <List<String>>[
        <String>['style', '--json'],
        <String>['--json', 'style'],
      ]) {
        final Run r = await fl(args);
        expect(r.code, 0, reason: r.err);
        expect(r.json['project_instructions'], '');
        expect(r.json['languages'], hasLength(3));
      }
    });

    test('fl languages and fl glossary', () async {
      final Run languages = await fl(<String>['languages']);
      expect(languages.code, 0, reason: languages.err);
      expect(languages.out, (await fl(<String>['languages', 'list'])).out);
      expect(languages.out, contains('en'));

      final Run glossary = await fl(<String>['glossary']);
      expect(glossary.code, 0, reason: glossary.err);
      expect(glossary.out, (await fl(<String>['glossary', 'list'])).out);
    });

    test('help and a wrong subcommand still answer as before', () async {
      final Run help = await fl(<String>['style', '--help']);
      expect(help.code, 0);
      expect(help.out, contains('Available subcommands:'));
      expect(backend.requests, isEmpty);

      final Run wrong = await fl(<String>['style', 'lst']);
      expect(wrong.code, 64);
      expect(wrong.err, contains('Could not find a subcommand named "lst"'));
      expect(backend.requests, isEmpty);
    });
  });

  group('one instruction for every language', () {
    test('is set, listed and removed', () async {
      final Run set = await fl(
          <String>['style', 'set', '--all', '--instructions', 'No dashes.']);
      expect(set.code, 0, reason: set.err);
      expect(set.out, contains('Every language now follows: "No dashes."'));
      expect(set.out, contains('fl glossary apply --all'));
      expect(backend.projectInstructions, 'No dashes.');
      expect((await fl(<String>['style'])).out,
          startsWith('  every language: No dashes.\n'));

      final Run cleared = await fl(<String>['style', 'clear', '--all']);
      expect(cleared.code, 0, reason: cleared.err);
      expect(cleared.out, contains('Removed the instructions'));
      expect(backend.projectInstructions, isEmpty);
      expect(
          (await fl(<String>['style'])).out, isNot(contains('every language')));
    });

    test('--dry-run writes nothing', () async {
      final Run r = await fl(<String>[
        '--dry-run',
        'style',
        'set',
        '--all',
        '--instructions',
        'No dashes.'
      ]);
      expect(r.code, 0, reason: r.err);
      expect(r.out, contains('Would set the instructions for every language.'));
      expect(backend.projectInstructions, isEmpty);
    });

    test('what does not fit is refused before any request', () async {
      for (final ({List<String> args, String says}) c
          in <({List<String> args, String says})>[
        (
          args: <String>['style', 'set', '--all'],
          says: 'Missing --instructions',
        ),
        (
          args: <String>['style', 'set', '--all', '--instructions', '  '],
          says: 'Missing --instructions',
        ),
        (
          args: <String>['style', 'set', '--all', '--formal'],
          says: 'Formal and informal are set per language',
        ),
        (
          args: <String>['style', 'set', 'de', '--all', '--instructions', 'x'],
          says: 'Pass a locale or --all, not both.',
        ),
        (
          args: <String>['style', 'clear', 'de', '--all'],
          says: 'Pass a locale or --all, not both.',
        ),
        (args: <String>['style', 'set'], says: 'Missing <locale>.'),
        (args: <String>['style', 'clear'], says: 'Missing <locale>.'),
      ]) {
        final Run r = await fl(c.args);
        expect(r.code, 64, reason: '${c.args}');
        expect(r.err, contains(c.says), reason: '${c.args}');
      }
      expect(backend.requests, isEmpty);
      expect(backend.projectInstructions, isEmpty);
    });

    test('a read-only token is told so', () async {
      final Run r = await fl(
        <String>['style', 'set', '--all', '--instructions', 'No dashes.'],
        env: <String, String>{'FL_API_TOKEN': kReadOnlyToken},
      );
      expect(r.code, 1);
      expect(r.err, contains("lacks the 'strings:write' scope"));
      expect(backend.projectInstructions, isEmpty);
    });
  });

  group('translations of a base text that has changed', () {
    setUp(() {
      backend.targets = <String, Map<String, dynamic>>{
        'de': <String, dynamic>{'value': 'Alt {arg1}', 'is_outdated': true},
        'fr': <String, dynamic>{'value': 'Courant {arg1}'},
      };
    });

    test('fl status counts them and names the command', () async {
      final Run r = await fl(<String>['status']);
      expect(r.code, 0, reason: r.err);
      expect(
          r.out, contains('de: 1/1 (100%)  ⚠ 1 translate an older base text'));
      expect(r.out, contains('fr: 1/1 (100%)\n'));
      expect(
        r.out,
        contains('1 value(s) were translated before their base text changed. '
            'Run `fl retranslate --changed` to redo them.'),
      );
      expect((await fl(<String>['--json', 'status'])).json['locales'][0],
          containsPair('outdated', 1));
    });

    test('fl retranslate leaves them and says so', () async {
      final Run r = await fl(<String>['retranslate']);
      expect(r.code, 0, reason: r.err);
      expect(r.out, contains('Nothing is missing. 1 value(s) still translate'));
      expect(r.out, contains('fl retranslate --changed'));
      expect(backend.translated, isEmpty);
    });

    test('fl retranslate --changed redoes them, and only them', () async {
      final Run dry =
          await fl(<String>['--dry-run', 'retranslate', '--changed']);
      expect(dry.code, 0, reason: dry.err);
      expect(
          dry.out, contains('would translate 1 value(s) across 1 locale(s)'));
      expect(backend.translated, isEmpty);

      final Run r = await fl(<String>['retranslate', '--changed']);
      expect(r.code, 0, reason: r.err);
      expect(r.out, contains('Translated 1/1 value(s) across 1 locale(s)'));
      expect(r.out, contains('de: 1 value(s)'));
      expect(backend.translated, <List<int>>[
        <int>[501]
      ]);

      final Run status = await fl(<String>['status']);
      expect(status.out, isNot(contains('older base text')));
      final Run again = await fl(<String>['retranslate', '--changed']);
      expect(again.out, contains('Nothing to translate'));
      expect(backend.translated, hasLength(1));
    });

    test('fl edit of the base text says what it left behind', () async {
      backend.targets['de'] = <String, dynamic>{'value': 'Alt {arg1}'};
      final Run r = await fl(<String>[
        'edit',
        'running %lld',
        '--value',
        'Cleaning, {arg1} s to go'
      ]);
      expect(r.code, 0, reason: r.err);
      expect(
        r.out,
        contains('2 translation(s) were written for the old text and are now '
            'marked for review: `fl retranslate --changed` redoes them.'),
      );
    });
  });
}
