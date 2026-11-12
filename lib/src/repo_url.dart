/// Git remote URLs: the same repository written as https, ssh or scp form,
/// and the clone that falls back from one to the other.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// Hosts whose SSH form is `git@<host>:<owner>/<repo>.git`.
const Set<String> kSshHosts = <String>{
  'github.com',
  'gitlab.com',
  'bitbucket.org',
};

final RegExp _scp = RegExp(r'^(?:[^@/\s]+@)?([^:/\s]+):(?!//)(.+)$');

/// `git@github.com:owner/repo.git` for an https URL on one of [kSshHosts],
/// else null.
String? sshFormOf(final String url) {
  final Uri? uri = Uri.tryParse(url.trim());
  if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) {
    return null;
  }
  final String host = uri.host.toLowerCase();
  if (!kSshHosts.contains(host)) return null;
  final String path = _trimPath(uri.path);
  if (path.isEmpty) return null;
  return 'git@$host:$path.git';
}

/// A form of [url] two spellings of one repository share: no scheme, user,
/// port or `.git`, host and path lowercased. A local path stays as it is.
String normalizeRepoUrl(final String url) {
  final String s = url.trim();
  final RegExpMatch? scp = _scp.firstMatch(s);
  if (scp != null && !s.contains('://')) {
    return '${scp.group(1)!.toLowerCase()}/'
        '${_trimPath(scp.group(2)!).toLowerCase()}';
  }
  final Uri? uri = Uri.tryParse(s);
  if (uri != null && uri.host.isNotEmpty && uri.scheme != 'file') {
    String path = _trimPath(uri.path);
    // Bitbucket Server serves https clones under /scm/ and ssh ones without.
    if (uri.scheme.startsWith('http') && path.startsWith('scm/')) {
      path = path.substring(4);
    }
    return '${uri.host.toLowerCase()}/${path.toLowerCase()}';
  }
  final String local = s.startsWith('file://') ? Uri.parse(s).toFilePath() : s;
  return p.normalize(_trimGit(local));
}

/// Whether [a] and [b] name the same repository.
bool sameRepo(final String a, final String b) =>
    normalizeRepoUrl(a) == normalizeRepoUrl(b);

/// [url] with any password or token in it replaced, for printing.
String redactCredentials(final String url) => url.replaceFirstMapped(
    RegExp(r'^([a-z+]+://[^/@:\s]*):[^/@\s]+@'),
    (final Match m) => '${m.group(1)}:***@');

/// Whether git's output reads like the repository is private to this
/// credential, rather than gone or the network down.
bool looksLikeAccessDenied(final String gitOutput) {
  final String o = gitOutput.toLowerCase();
  return const <String>[
    'repository not found',
    'could not be found',
    'authentication failed',
    'could not read username',
    'could not read password',
    'terminal prompts disabled',
    'invalid username or password',
    'access denied',
    'permission denied',
    'returned error: 401',
    'returned error: 403',
  ].any(o.contains);
}

String _trimGit(final String s) {
  String out = s;
  while (out.endsWith('/')) {
    out = out.substring(0, out.length - 1);
  }
  return out.endsWith('.git') ? out.substring(0, out.length - 4) : out;
}

String _trimPath(final String path) {
  String out = path;
  while (out.startsWith('/')) {
    out = out.substring(1);
  }
  return _trimGit(out);
}

/// What [cloneRepo] did: the URL that worked, or every attempt's output.
class CloneOutcome {
  CloneOutcome(this.url, this.attempts);

  /// The URL the clone came from, null when every attempt failed.
  final String? url;

  /// Each URL tried, in order, with git's combined output.
  final List<({String url, int exitCode, String output})> attempts;

  bool get ok => url != null;
}

typedef GitRunner = Future<ProcessResult> Function(
  String executable,
  List<String> args, {
  Map<String, String>? environment,
});

Future<ProcessResult> _runGit(
  final String executable,
  final List<String> args, {
  final Map<String, String>? environment,
}) =>
    Process.run(executable, args, environment: environment);

/// `git clone [url] [dir]`, then the SSH form of [url] when the https clone
/// is refused: the dashboard hands out https URLs, and a developer whose git
/// signs in over SSH has no https credential for a private repo.
Future<CloneOutcome> cloneRepo(
  final String url,
  final String dir, {
  final GitRunner runner = _runGit,
}) async {
  final List<({String url, int exitCode, String output})> attempts =
      <({String url, int exitCode, String output})>[];
  // A prompt git opens itself would wait unseen behind the captured output;
  // failing lets the SSH attempt run. BatchMode does the same for ssh.
  final Map<String, String> env = <String, String>{
    'GIT_TERMINAL_PROMPT': '0',
    'GCM_INTERACTIVE': 'never',
    if (!Platform.environment.containsKey('GIT_SSH_COMMAND'))
      'GIT_SSH_COMMAND': 'ssh -o BatchMode=yes',
  };
  Future<bool> attempt(final String from) async {
    final ProcessResult r =
        await runner('git', <String>['clone', from, dir], environment: env);
    attempts.add((
      url: from,
      exitCode: r.exitCode,
      output: '${r.stderr}${r.stdout}'.trim(),
    ));
    return r.exitCode == 0;
  }

  if (await attempt(url)) return CloneOutcome(url, attempts);
  final String? ssh = sshFormOf(url);
  if (ssh != null && looksLikeAccessDenied(attempts.last.output)) {
    if (await attempt(ssh)) return CloneOutcome(ssh, attempts);
  }
  return CloneOutcome(null, attempts);
}
