/// Keeping the on-disk ARB mirror in step with the service, without ever
/// asking a human to run a git command.
///
/// The ARB directory is an *artifact*: the backend owns it, pushes to it, and
/// the app only reads it. That was always the intent, but `fl pull` used to be
/// a bare `git pull --rebase` inside it, which made the mirror behave like a
/// working copy. Two failures followed from that, both seen in the field:
///
///  * **Local state blocked the sync.** An edited `app_en.arb` (the documented
///    way to stage keys for `fl import`) or a stale local commit made the
///    rebase refuse or conflict, and the caller was told to `git stash` /
///    `git rebase --continue` inside a directory they are supposed to treat as
///    generated output.
///  * **The git path is not always available.** The clone is authenticated by
///    whatever ambient git credential happens to be active, so the wrong
///    account, a missing credential helper or a repo that was never linked all
///    surface as `Repository not found` — while the very same ARBs sit behind
///    the API token the CLI already holds.
///
/// So the sync is defined by *outcome*, not by transport: after it runs, the
/// directory equals the service. Git is used when it can deliver that (it is
/// cheaper and preserves history); the API is used when it cannot. Neither
/// path can be blocked by local state, and nothing local is dropped without
/// being recoverable — see [GitMirror.hardSync] for the recovery ref and
/// [localOnlyKeys] for the one case that stops the sync on purpose.
library;

import 'dart:convert';
import 'dart:io';

/// How the ARBs on disk were refreshed.
enum ArbSyncMethod {
  /// `git fetch` + hard reset onto the upstream branch.
  git,

  /// Written from the API, the same data the backend pushes to the repo.
  api,
}

/// Why the git path could not be used (so the caller can say so out loud).
enum GitSkipReason {
  /// No `git` binary on PATH.
  gitMissing,

  /// The ARB directory is not a git working tree.
  notARepo,

  /// A working tree with no `origin` remote.
  noRemote,

  /// `git fetch` failed: repo deleted, renamed, or the ambient credential
  /// cannot see it. The API path covers all three.
  unreachable,
}

/// Result of a [GitMirror.hardSync].
class GitSyncOutcome {
  const GitSyncOutcome.synced({
    required this.upstream,
    required this.discardedLocalCommits,
    required this.discardedWorkingChanges,
    this.recoveryRef,
  })  : ok = true,
        skip = null,
        detail = '';

  const GitSyncOutcome.skipped(this.skip, {this.detail = ''})
      : ok = false,
        upstream = '',
        discardedLocalCommits = 0,
        discardedWorkingChanges = false,
        recoveryRef = null;

  final bool ok;
  final GitSkipReason? skip;

  /// stderr/stdout snippet explaining a skip, for the caller's message.
  final String detail;

  /// The branch the mirror was reset onto, e.g. `origin/main`.
  final String upstream;

  /// Local commits that were on top of [upstream] and are now gone.
  final int discardedLocalCommits;

  /// Whether tracked files had uncommitted edits before the reset.
  final bool discardedWorkingChanges;

  /// Ref holding everything that was discarded, when anything was.
  ///
  /// `git show <ref>` brings it back. Printed by the caller so "the sync threw
  /// away my edit" always has an answer.
  final String? recoveryRef;

  bool get discardedAnything =>
      discardedLocalCommits > 0 || discardedWorkingChanges;
}

/// The ARB directory seen as a git mirror of the backend's repo.
class GitMirror {
  GitMirror(this.dir, {this.runner = _run});

  final String dir;

  /// Injectable process runner — the tests drive the whole decision tree
  /// through this without a real repository.
  final Future<ProcessResult> Function(
    String executable,
    List<String> args, {
    String? workingDirectory,
  }) runner;

  static Future<ProcessResult> _run(
    final String executable,
    final List<String> args, {
    final String? workingDirectory,
  }) =>
      Process.run(
        executable,
        args,
        workingDirectory: workingDirectory,
        // A sync must never sit waiting for a human. Without these, git can
        // block on a credential prompt (or pop a GUI keychain dialog) and the
        // command simply hangs, which is worse than failing over to the API.
        environment: const <String, String>{
          'GIT_TERMINAL_PROMPT': '0',
          'GCM_INTERACTIVE': 'never',
        },
        runInShell: false,
      );

  Future<ProcessResult> _git(final List<String> args) =>
      runner('git', args, workingDirectory: dir);

  /// Bring the mirror to exactly what the remote holds.
  ///
  /// Deliberately a reset and not a merge or a rebase: there is no such thing
  /// as a local contribution here, so there is nothing to reconcile, and a
  /// conflict in generated output is never a question worth asking a user.
  Future<GitSyncOutcome> hardSync() async {
    if (!Directory(dir).existsSync()) {
      return const GitSyncOutcome.skipped(GitSkipReason.notARepo);
    }
    final ProcessResult version = await _git(<String>['--version']);
    if (version.exitCode != 0) {
      return const GitSyncOutcome.skipped(GitSkipReason.gitMissing);
    }
    final ProcessResult inside =
        await _git(<String>['rev-parse', '--is-inside-work-tree']);
    if (inside.exitCode != 0 || '${inside.stdout}'.trim() != 'true') {
      return const GitSyncOutcome.skipped(GitSkipReason.notARepo);
    }
    final ProcessResult remotes = await _git(<String>['remote']);
    if (remotes.exitCode != 0 || '${remotes.stdout}'.trim().isEmpty) {
      return const GitSyncOutcome.skipped(GitSkipReason.noRemote);
    }
    final String remote = '${remotes.stdout}'.trim().split('\n').first.trim();

    final ProcessResult fetch =
        await _git(<String>['fetch', '--prune', remote]);
    if (fetch.exitCode != 0) {
      return GitSyncOutcome.skipped(
        GitSkipReason.unreachable,
        detail: _firstLine('${fetch.stderr}${fetch.stdout}'),
      );
    }

    final String? upstream = await _upstream(remote);
    if (upstream == null) {
      return const GitSyncOutcome.skipped(
        GitSkipReason.unreachable,
        detail: 'no upstream branch to sync onto',
      );
    }

    final bool dirty = await _isDirty();
    final int ahead = await _commitsAhead(upstream);
    String? recovery;
    if (dirty || ahead > 0) recovery = await _saveRecoveryRef(dirty: dirty);

    final ProcessResult reset =
        await _git(<String>['reset', '--hard', upstream]);
    if (reset.exitCode != 0) {
      return GitSyncOutcome.skipped(
        GitSkipReason.unreachable,
        detail: _firstLine('${reset.stderr}'),
      );
    }
    // Untracked ARBs only: a locale the service dropped would otherwise stay
    // on disk and get compiled into the app. Anything else a human left in the
    // directory is theirs and is left alone.
    await _git(<String>['clean', '-f', '--', '*.arb', '*.xcstrings']);

    return GitSyncOutcome.synced(
      upstream: upstream,
      discardedLocalCommits: ahead,
      discardedWorkingChanges: dirty,
      recoveryRef: recovery,
    );
  }

  Future<String?> _upstream(final String remote) async {
    final ProcessResult tracked = await _git(
      <String>['rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}'],
    );
    if (tracked.exitCode == 0 && '${tracked.stdout}'.trim().isNotEmpty) {
      return '${tracked.stdout}'.trim();
    }
    // Detached HEAD, or a branch nobody set an upstream for: fall back to the
    // remote's default branch, which is what the backend pushes to.
    final ProcessResult head = await _git(
        <String>['symbolic-ref', '--short', 'refs/remotes/$remote/HEAD']);
    if (head.exitCode == 0 && '${head.stdout}'.trim().isNotEmpty) {
      return '${head.stdout}'.trim();
    }
    for (final String branch in <String>['main', 'master']) {
      final ProcessResult exists =
          await _git(<String>['rev-parse', '--verify', '$remote/$branch']);
      if (exists.exitCode == 0) return '$remote/$branch';
    }
    return null;
  }

  Future<bool> _isDirty() async {
    final ProcessResult status =
        await _git(<String>['status', '--porcelain', '--untracked-files=no']);
    return status.exitCode == 0 && '${status.stdout}'.trim().isNotEmpty;
  }

  Future<int> _commitsAhead(final String upstream) async {
    final ProcessResult count =
        await _git(<String>['rev-list', '--count', '$upstream..HEAD']);
    if (count.exitCode != 0) return 0;
    return int.tryParse('${count.stdout}'.trim()) ?? 0;
  }

  /// Park everything about to be discarded under `refs/fl/pre-sync/<stamp>`.
  ///
  /// `git stash create` builds a commit that carries the working tree AND the
  /// current HEAD as its parent, without touching the index or the stash list,
  /// so one ref is enough to get either back.
  Future<String?> _saveRecoveryRef({required final bool dirty}) async {
    final String ref =
        'refs/fl/pre-sync/${DateTime.now().toUtc().toIso8601String().replaceAll(RegExp('[:.]'), '-')}';
    String target = 'HEAD';
    if (dirty) {
      final ProcessResult stash = await _git(<String>['stash', 'create']);
      final String sha = '${stash.stdout}'.trim();
      if (stash.exitCode == 0 && sha.isNotEmpty) target = sha;
    }
    final ProcessResult update =
        await _git(<String>['update-ref', ref, target]);
    return update.exitCode == 0 ? ref : null;
  }

  static String _firstLine(final String text) {
    final List<String> lines = text
        .split('\n')
        .map((final String l) => l.trim())
        .where((final String l) => l.isNotEmpty)
        .toList();
    return lines.isEmpty ? '' : lines.first;
  }
}

/// Keys that exist in the on-disk template but not on the service.
///
/// This is the one thing a sync must never steamroll. Both refresh paths
/// rewrite the template from the service, so a key that only exists on disk —
/// typically staged by hand for a `fl import` that never ran — would vanish
/// with no trace. It has happened, and it took the app's build with it.
///
/// [templateFile] is the base-locale ARB (`app_en.arb`); [serviceKeys] is what
/// the project holds. Metadata entries (`@key`, `@@locale`) are ignored.
List<String> localOnlyKeys(
  final File templateFile,
  final Set<String> serviceKeys,
) {
  if (!templateFile.existsSync()) return const <String>[];
  final Object? decoded = jsonDecode(templateFile.readAsStringSync());
  if (decoded is! Map<String, dynamic>) return const <String>[];
  return <String>[
    for (final String key in decoded.keys)
      if (!key.startsWith('@') && !serviceKeys.contains(key)) key,
  ]..sort();
}
