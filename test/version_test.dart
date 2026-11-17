import 'dart:convert';
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

  group('when the notice is due', () {
    late Directory tmp;
    late File stamp;
    DateTime clock = DateTime(2026, 11, 17, 9);

    UpdateNotice notice({final String latest = '99.1.0', final String? why}) =>
        UpdateNotice(latest: latest, reason: why);
    bool due(
      final UpdateNotice n, [
      final Map<String, String> env = const <String, String>{},
    ]) =>
        n.isDue(env, stamp: stamp, now: () => clock);

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('fl_version_test');
      stamp = File(p.join(tmp.path, 'deep', 'update_notice.json'));
      clock = DateTime(2026, 11, 17, 9);
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('once per day and per version', () {
      expect(due(notice()), isTrue);
      expect(due(notice()), isFalse);
      clock = clock.add(const Duration(hours: 23, minutes: 59));
      expect(due(notice()), isFalse);
      clock = clock.add(const Duration(minutes: 1));
      expect(due(notice()), isTrue);
      expect(due(notice()), isFalse);
      expect(due(notice(latest: '99.2.0')), isTrue);
      expect(due(notice(latest: '99.2.0')), isFalse);
    });

    test('a clock set back does not silence it for longer than a day', () {
      expect(due(notice()), isTrue);
      clock = clock.subtract(const Duration(days: 30));
      expect(due(notice()), isTrue);
      expect(due(notice()), isFalse);
    });

    test('always in a build, and always with a reason', () {
      for (final Map<String, String> env in <Map<String, String>>[
        <String, String>{'CI': 'true'},
        <String, String>{'CI': '1'},
        <String, String>{'TF_BUILD': 'True'},
      ]) {
        expect(due(notice(), env), isTrue);
        expect(due(notice(), env), isTrue, reason: '$env');
      }
      expect(stamp.existsSync(), isFalse);
      expect(due(notice(why: 'Fixes stale strings.')), isTrue);
      expect(due(notice(why: 'Fixes stale strings.')), isTrue);
      expect(stamp.existsSync(), isFalse);
    });

    test('CI set to nothing, 0 or false is a desk', () {
      for (final String value in <String>['', '0', 'false', 'FALSE']) {
        if (stamp.existsSync()) stamp.deleteSync();
        final Map<String, String> env = <String, String>{'CI': value};
        expect(due(notice(), env), isTrue, reason: 'CI=$value');
        expect(due(notice(), env), isFalse, reason: 'CI=$value');
      }
    });

    test('never when switched off', () {
      final Map<String, String> off = <String, String>{
        kNoUpdateNoticeEnvVar: '1',
        'CI': 'true',
      };
      expect(due(notice(why: 'Important.'), off), isFalse);
      expect(stamp.existsSync(), isFalse);
    });

    test('a stamp that is unreadable or unwritable is not an error', () {
      stamp
        ..createSync(recursive: true)
        ..writeAsStringSync('[1, 2');
      expect(due(notice()), isTrue);
      expect(jsonDecode(stamp.readAsStringSync()),
          containsPair('latest', '99.1.0'));

      // A directory where the file should be: nothing can be written.
      final File blocked = File(p.join(tmp.path, 'blocked'));
      Directory(blocked.path).createSync();
      expect(notice().isDue(const <String, String>{}, stamp: blocked), isTrue);
      expect(notice().isDue(const <String, String>{}, stamp: blocked), isTrue);
    });

    test('the default stamp sits beside the credentials', () {
      final Map<String, String> env = <String, String>{'HOME': tmp.path};
      expect(notice().isDue(env), isTrue);
      expect(notice().isDue(env), isFalse);
      expect(
        File(p.join(tmp.path, '.config', 'flutterlocalisation',
                'update_notice.json'))
            .existsSync(),
        isTrue,
      );
    });
  });
}
