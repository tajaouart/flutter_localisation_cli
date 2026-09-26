import 'dart:convert';
import 'dart:io';

import 'package:flutter_localisation_cli/src/arb_sync.dart';
import 'package:test/test.dart';

/// A scripted `git`: every call is recorded, and each argv prefix can be given
/// an exit code and output. Anything not scripted succeeds with empty output,
/// which keeps each test about the one decision it is making.
class FakeGit {
  FakeGit(this.script);

  final Map<String, ProcessResult> script;
  final List<List<String>> calls = <List<String>>[];

  Future<ProcessResult> run(
    final String executable,
    final List<String> args, {
    final String? workingDirectory,
  }) async {
    calls.add(args);
    for (final MapEntry<String, ProcessResult> e in script.entries) {
      if (args.join(' ').startsWith(e.key)) return e.value;
    }
    return ProcessResult(0, 0, '', '');
  }

  bool ran(final String prefix) =>
      calls.any((final List<String> a) => a.join(' ').startsWith(prefix));
}

ProcessResult ok([final String out = '']) => ProcessResult(0, 0, out, '');
ProcessResult fail(final String err) => ProcessResult(0, 1, '', err);

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('fl_sync_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  GitMirror mirror(final FakeGit git) => GitMirror(tmp.path, runner: git.run);

  group('GitMirror.hardSync', () {
    test('resets onto the upstream branch instead of rebasing', () async {
      final FakeGit git = FakeGit(<String, ProcessResult>{
        'rev-parse --is-inside-work-tree': ok('true\n'),
        'remote': ok('origin\n'),
        'rev-parse --abbrev-ref --symbolic-full-name': ok('origin/main\n'),
        'status --porcelain': ok(''),
        'rev-list --count': ok('0\n'),
      });
      final GitSyncOutcome out = await mirror(git).hardSync();

      expect(out.ok, isTrue);
      expect(out.upstream, 'origin/main');
      expect(git.ran('reset --hard origin/main'), isTrue);
      expect(git.ran('pull'), isFalse, reason: 'a pull can conflict; a reset cannot');
      expect(out.discardedAnything, isFalse);
    });

    test('a dirty tree does not block the sync, and is recoverable', () async {
      final FakeGit git = FakeGit(<String, ProcessResult>{
        'rev-parse --is-inside-work-tree': ok('true\n'),
        'remote': ok('origin\n'),
        'rev-parse --abbrev-ref --symbolic-full-name': ok('origin/main\n'),
        'status --porcelain': ok(' M Default/app_en.arb\n'),
        'rev-list --count': ok('0\n'),
        'stash create': ok('deadbeef\n'),
      });
      final GitSyncOutcome out = await mirror(git).hardSync();

      expect(out.ok, isTrue);
      expect(out.discardedWorkingChanges, isTrue);
      expect(out.recoveryRef, startsWith('refs/fl/pre-sync/'));
      expect(git.ran('update-ref refs/fl/pre-sync/'), isTrue);
      expect(
        git.calls.any((final List<String> a) =>
            a.first == 'update-ref' && a.last == 'deadbeef'),
        isTrue,
        reason: 'the stash commit carries the worktree, so it is what we park',
      );
    });

    test('local commits are counted, parked and dropped', () async {
      final FakeGit git = FakeGit(<String, ProcessResult>{
        'rev-parse --is-inside-work-tree': ok('true\n'),
        'remote': ok('origin\n'),
        'rev-parse --abbrev-ref --symbolic-full-name': ok('origin/main\n'),
        'status --porcelain': ok(''),
        'rev-list --count': ok('2\n'),
      });
      final GitSyncOutcome out = await mirror(git).hardSync();

      expect(out.discardedLocalCommits, 2);
      expect(out.recoveryRef, isNotNull);
      expect(git.ran('reset --hard'), isTrue);
    });

    test('an unreachable remote is a skip, not a failure', () async {
      final FakeGit git = FakeGit(<String, ProcessResult>{
        'rev-parse --is-inside-work-tree': ok('true\n'),
        'remote': ok('origin\n'),
        'fetch': fail('remote: Repository not found.\nfatal: repository not found'),
      });
      final GitSyncOutcome out = await mirror(git).hardSync();

      expect(out.ok, isFalse);
      expect(out.skip, GitSkipReason.unreachable);
      expect(out.detail, contains('Repository not found'));
      expect(git.ran('reset'), isFalse, reason: 'nothing was fetched to reset onto');
    });

    test('a plain directory is a skip, so the caller can use the API', () async {
      final FakeGit git = FakeGit(<String, ProcessResult>{
        'rev-parse --is-inside-work-tree': fail('not a git repository'),
      });
      final GitSyncOutcome out = await mirror(git).hardSync();
      expect(out.skip, GitSkipReason.notARepo);
    });

    test('no git binary is a skip', () async {
      final FakeGit git = FakeGit(<String, ProcessResult>{
        '--version': fail('command not found'),
      });
      expect((await mirror(git).hardSync()).skip, GitSkipReason.gitMissing);
    });

    test('a clone with no remote is a skip', () async {
      final FakeGit git = FakeGit(<String, ProcessResult>{
        'rev-parse --is-inside-work-tree': ok('true\n'),
        'remote': ok('\n'),
      });
      expect((await mirror(git).hardSync()).skip, GitSkipReason.noRemote);
    });

    test('falls back to the remote HEAD when no upstream is set', () async {
      final FakeGit git = FakeGit(<String, ProcessResult>{
        'rev-parse --is-inside-work-tree': ok('true\n'),
        'remote': ok('origin\n'),
        'rev-parse --abbrev-ref --symbolic-full-name': fail('no upstream'),
        'symbolic-ref --short': ok('origin/main\n'),
        'status --porcelain': ok(''),
        'rev-list --count': ok('0\n'),
      });
      final GitSyncOutcome out = await mirror(git).hardSync();
      expect(out.upstream, 'origin/main');
    });

    test('only stale ARBs are cleaned, never the rest of the directory', () async {
      final FakeGit git = FakeGit(<String, ProcessResult>{
        'rev-parse --is-inside-work-tree': ok('true\n'),
        'remote': ok('origin\n'),
        'rev-parse --abbrev-ref --symbolic-full-name': ok('origin/main\n'),
        'status --porcelain': ok(''),
        'rev-list --count': ok('0\n'),
      });
      await mirror(git).hardSync();
      expect(git.ran('clean -f -- *.arb'), isTrue);
      expect(git.ran('clean -fd'), isFalse);
    });
  });

  group('localOnlyKeys', () {
    File template(final Map<String, dynamic> arb) {
      final File f = File('${tmp.path}/app_en.arb')
        ..writeAsStringSync(jsonEncode(arb));
      return f;
    }

    test('names the keys a sync would overwrite away', () {
      final File f = template(<String, dynamic>{
        '@@locale': 'en',
        'known': 'Known',
        'stagedByHand': 'Staged',
        '@stagedByHand': <String, dynamic>{'description': 'x'},
      });
      expect(localOnlyKeys(f, <String>{'known'}), <String>['stagedByHand']);
    });

    test('is empty when disk and service agree', () {
      final File f = template(<String, dynamic>{'@@locale': 'en', 'a': 'A'});
      expect(localOnlyKeys(f, <String>{'a', 'b'}), isEmpty);
    });

    test('a missing template is not a problem', () {
      expect(localOnlyKeys(File('${tmp.path}/nope.arb'), <String>{}), isEmpty);
    });
  });
}
