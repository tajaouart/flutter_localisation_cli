import 'dart:io';

import 'package:flutter_localisation_cli/src/version.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fake_backend.dart';

void main() {
  setUp(() => UpdateNotice.current = null);

  test('kCliVersion is the version in pubspec.yaml and has a changelog entry',
      () {
    final String pubspec =
        File(p.join(packageRoot(), 'pubspec.yaml')).readAsStringSync();
    // A Windows checkout has CRLF line ends.
    expect(
      RegExp(r'^version: (\S+)', multiLine: true).firstMatch(pubspec)!.group(1),
      kCliVersion,
    );
    expect(File(p.join(packageRoot(), 'CHANGELOG.md')).readAsStringSync(),
        contains('## [$kCliVersion]'));
  });

  test('versions compare by number', () {
    expect(isOlder('1.9.0', '1.10.0'), isTrue);
    expect(isOlder('1.18', '1.18.1'), isTrue);
    expect(isOlder('1.19.0', '1.19.0'), isFalse);
    expect(isOlder('2.0.0', '1.99.99'), isFalse);
    expect(isOlder('1.19.0-dev.1', '1.19.0'), isFalse);
    expect(isOlder('soon', '1.19.0'), isFalse);
    expect(isOlder('1.19.0', ''), isFalse);
  });

  test('a notice is kept only for a newer version', () {
    UpdateNotice.read(<String, String>{});
    expect(UpdateNotice.current, isNull);
    UpdateNotice.read(<String, String>{'x-fl-latest-version': kCliVersion});
    expect(UpdateNotice.current, isNull);
    UpdateNotice.read(<String, String>{'x-fl-latest-version': '99.1.0'});
    expect(
      UpdateNotice.current!.describe('fl'),
      'fl 99.1.0 is available (this is $kCliVersion).\n'
      'Update with: $kUpgradeCommand',
    );
    UpdateNotice.read(<String, String>{
      'x-fl-latest-version': '99.2.0',
      'x-fl-notice': 'Fixes stale strings.',
      'x-fl-upgrade-command': 'do this',
    });
    expect(
      UpdateNotice.current!.describe('fl_mcp'),
      'fl_mcp 99.2.0 is available (this is $kCliVersion). '
      'Fixes stale strings.\nUpdate with: do this',
    );
  });
}
