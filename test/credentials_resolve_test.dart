import 'dart:convert';
import 'dart:io';

import 'package:flutter_localisation_cli/src/config.dart';
import 'package:flutter_localisation_cli/src/exceptions.dart';
import 'package:test/test.dart';

/// Token resolution used by both the `fl` CLI and `fl_mcp`. Covers the
/// credentials-file fallback that `fl_mcp` now relies on (previously it read
/// only $FL_API_TOKEN and ignored the file written by `fl login`).
void main() {
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
