import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:flutter_localisation_cli/src/config.dart';
import 'package:flutter_localisation_cli/src/exceptions.dart';
import 'package:test/test.dart';

/// Token resolution used by both the `fl` CLI and `fl_mcp`. Covers the
/// credentials-file fallback that `fl_mcp` now relies on (previously it read
/// only $FL_API_TOKEN and ignored the file written by `fl login`).
void main() {
  _arbDirTests();
  late Directory tmp;

  // The env var short-circuits the file fallback; if the runner has it set,
  // skip the file-dependent cases so the suite stays deterministic.
  final String? envToken = Platform.environment['FL_API_TOKEN'];
  final String? skipIfEnv = (envToken != null && envToken.isNotEmpty)
      ? 'FL_API_TOKEN is set in this environment'
      : null;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fl_creds_test');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  File writeCreds(final Map<String, dynamic> data) {
    final File f = File('${tmp.path}/credentials.json');
    f.writeAsStringSync(jsonEncode(data));
    return f;
  }

  group('token_file in flutterlocalisation.json', () {
    test('is read before the credentials file, ~ meaning home', () {
      final File creds = writeCreds(<String, dynamic>{'token': 'flk_login'});
      File('${tmp.path}/project_token').writeAsStringSync('flk_project\n');
      expect(
        Credentials.resolve(
          credentialsFile: creds,
          tokenFile: '~/project_token',
          env: <String, String>{'HOME': tmp.path},
        ).token,
        'flk_project',
      );
    });

    test('loses to FL_API_TOKEN', () {
      expect(
        Credentials.resolve(
          tokenFile: '${tmp.path}/nowhere',
          env: <String, String>{'FL_API_TOKEN': 'flk_env'},
        ).token,
        'flk_env',
      );
    });

    test('a missing file says so instead of falling back to another token', () {
      expect(
        () => Credentials.resolve(
          credentialsFile: writeCreds(<String, dynamic>{'token': 'flk_login'}),
          tokenFile: '${tmp.path}/nowhere',
          env: <String, String>{},
        ),
        throwsA(isA<AuthConfigException>().having(
            (final AuthConfigException e) => e.message,
            'message',
            contains('does not exist'))),
      );
    });

    test('is read from the config file', () {
      final File cfg = File('${tmp.path}/flutterlocalisation.json')
        ..writeAsStringSync(
            jsonEncode(<String, String>{'token_file': '~/.config/fl/studio'}));
      expect(
          ProjectConfig.load(path: cfg.path).tokenFile, '~/.config/fl/studio');
    });
  });

  test('explicit token wins over everything', () {
    expect(Credentials.resolve(explicit: 'flk_explicit').token, 'flk_explicit');
  });

  test('falls back to the credentials file default token', () {
    final File creds = writeCreds(<String, dynamic>{'token': 'flk_from_file'});
    expect(
      Credentials.resolve(credentialsFile: creds).token,
      'flk_from_file',
    );
  }, skip: skipIfEnv);

  test('prefers a base-url-scoped token from the credentials file', () {
    const String baseUrl = 'https://api.flutterlocalisation.com';
    final File creds = writeCreds(<String, dynamic>{
      'token': 'flk_default',
      'tokens': <String, dynamic>{baseUrl: 'flk_scoped'},
    });
    expect(
      Credentials.resolve(baseUrl: baseUrl, credentialsFile: creds).token,
      'flk_scoped',
    );
  }, skip: skipIfEnv);

  test('throws AuthConfigException when no token is available anywhere', () {
    final File missing = File('${tmp.path}/does_not_exist.json');
    expect(
      () => Credentials.resolve(credentialsFile: missing),
      throwsA(isA<AuthConfigException>()),
    );
  }, skip: skipIfEnv);
}

void _arbDirTests() {
  group('arb_dir in flutterlocalisation.json', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('fl_arbdir_test'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('a relative arb_dir resolves against the config file, not the cwd',
        () {
      final Directory project = Directory(p.join(tmp.path, 'app'))
        ..createSync();
      File(p.join(project.path, 'flutterlocalisation.json')).writeAsStringSync(
          jsonEncode({'project': 'X', 'arb_dir': 'lib/l10n'}));

      final ProjectConfig cfg = ProjectConfig.load(
          path: p.join(project.path, 'flutterlocalisation.json'));

      expect(cfg.arbDir, p.join(project.path, 'lib', 'l10n'));
      expect(p.isAbsolute(cfg.arbDir!), isTrue);
    });

    test('an absolute arb_dir is kept as is', () {
      final String abs = p.join(tmp.path, 'elsewhere');
      File(p.join(tmp.path, 'flutterlocalisation.json'))
          .writeAsStringSync(jsonEncode({'arb_dir': abs}));
      expect(
          ProjectConfig.load(path: p.join(tmp.path, 'flutterlocalisation.json'))
              .arbDir,
          abs);
    });

    test('no arb_dir stays null so commands keep their own default', () {
      File(p.join(tmp.path, 'flutterlocalisation.json'))
          .writeAsStringSync('{}');
      expect(
          ProjectConfig.load(path: p.join(tmp.path, 'flutterlocalisation.json'))
              .arbDir,
          isNull);
    });
  });
}
