import 'dart:io';

import 'package:flutter_localisation_cli/src/repo_url.dart';
import 'package:test/test.dart';

void main() {
  test('sshFormOf covers the three hosted providers only', () {
    expect(sshFormOf('https://github.com/Acme/arbs'),
        'git@github.com:Acme/arbs.git');
    expect(sshFormOf('https://gitlab.com/acme/sub/arbs.git/'),
        'git@gitlab.com:acme/sub/arbs.git');
    expect(sshFormOf('https://user@bitbucket.org/acme/arbs.git'),
        'git@bitbucket.org:acme/arbs.git');
    expect(sshFormOf('https://git.acme.dev/acme/arbs.git'), isNull);
    expect(sshFormOf('git@github.com:acme/arbs.git'), isNull);
  });

  test('https, ssh and scp spellings of one repo are the same repo', () {
    const String https = 'https://github.com/Acme/ARBs.git';
    for (final String other in <String>[
      'https://github.com/acme/arbs',
      'https://x-access-token:abc@GitHub.com/acme/arbs/',
      'git@github.com:acme/arbs.git',
      'ssh://git@github.com/acme/arbs.git',
      'ssh://git@github.com:22/acme/arbs',
    ]) {
      expect(sameRepo(https, other), isTrue, reason: other);
    }
    expect(sameRepo(https, 'https://gitlab.com/acme/arbs.git'), isFalse);
    expect(sameRepo(https, 'git@github.com:acme/arbs-old.git'), isFalse);
    expect(
        sameRepo('https://bb.acme.dev/scm/app/arbs.git',
            'ssh://git@bb.acme.dev:7999/app/arbs.git'),
        isTrue,
        reason: 'Bitbucket Server puts https clones under /scm/');
    expect(sameRepo('/tmp/x/arbs.git', 'file:///tmp/x/arbs'), isTrue);
  });

  test('redactCredentials hides a token, keeps a plain user', () {
    expect(redactCredentials('https://x-access-token:abc@github.com/a/b.git'),
        'https://x-access-token:***@github.com/a/b.git');
    expect(redactCredentials('ssh://git@github.com/a/b.git'),
        'ssh://git@github.com/a/b.git');
  });

  group('cloneRepo', () {
    Future<CloneOutcome> run(
      final String url,
      final Map<String, (int, String)> byUrl,
      final List<String> tried,
    ) =>
        cloneRepo(url, 'arbs', runner:
            (final String exe, final List<String> args,
                {final Map<String, String>? environment}) async {
          final String from = args[1];
          tried.add(from);
          expect(environment?['GIT_TERMINAL_PROMPT'], '0');
          final (int, String) r = byUrl[from]!;
          return ProcessResult(0, r.$1, '', r.$2);
        });

    test('retries over SSH when https is refused', () async {
      final List<String> tried = <String>[];
      final CloneOutcome o = await run(
        'https://github.com/acme/arbs.git',
        <String, (int, String)>{
          'https://github.com/acme/arbs.git': (
            128,
            "remote: Repository not found.\nfatal: repository 'x' not found"
          ),
          'git@github.com:acme/arbs.git': (0, ''),
        },
        tried,
      );
      expect(o.ok, isTrue);
      expect(o.url, 'git@github.com:acme/arbs.git');
      expect(tried, hasLength(2));
    });

    test('does not retry a network failure or a self-hosted URL', () async {
      final List<String> tried = <String>[];
      CloneOutcome o = await run(
        'https://github.com/acme/arbs.git',
        <String, (int, String)>{
          'https://github.com/acme/arbs.git': (
            128,
            'fatal: unable to access: Could not resolve host: github.com'
          ),
        },
        tried,
      );
      expect(o.ok, isFalse);
      expect(tried, hasLength(1));

      tried.clear();
      o = await run(
        'https://git.acme.dev/acme/arbs.git',
        <String, (int, String)>{
          'https://git.acme.dev/acme/arbs.git': (
            128,
            'fatal: Authentication failed'
          ),
        },
        tried,
      );
      expect(o.ok, isFalse);
      expect(o.attempts.single.output, contains('Authentication failed'));
    });
  });

  test('a Windows drive path is a local repo, not an scp host', () {
    expect(normalizeRepoUrl(r'C:\repos\app.git'), isNot(startsWith('c/')));
    expect(sameRepo(r'file://C:\repos\app.git', r'C:\repos\app'), isTrue);
  });

  test('a file URL names the same repo as its path, even a malformed one', () {
    expect(sameRepo('file:///srv/git/app.git', '/srv/git/app/'), isTrue);
    expect(normalizeRepoUrl('file://%zz/app.git'), '%zz/app');
  });
}
