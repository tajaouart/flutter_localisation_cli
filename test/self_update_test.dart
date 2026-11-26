import 'dart:convert';
import 'dart:io';

import 'package:flutter_localisation_cli/src/self_update.dart';
import 'package:flutter_localisation_cli/src/version.dart';
import 'package:test/test.dart';

void main() {
  const String snapshot =
      '/home/me/.pub-cache/global_packages/flutter_localisation_cli/bin/fl_mcp.dart-3.14.0.snapshot';

  group('which copies update themselves', () {
    test('the snapshot pub global activate installed', () {
      expect(isPubGlobalSnapshot(snapshot), isTrue);
      expect(
          isPubGlobalSnapshot(
              r'C:\Users\me\AppData\Local\Pub\Cache\global_packages\flutter_localisation_cli\bin\fl.dart-3.14.0.snapshot'),
          isTrue);
    });

    test('not a checkout, a binary or another package', () {
      expect(
          isPubGlobalSnapshot('/work/flutter_localisation_cli/bin/fl_mcp.dart'),
          isFalse);
      expect(isPubGlobalSnapshot('/usr/local/bin/fl'), isFalse);
      expect(
          isPubGlobalSnapshot(
              '/home/me/.pub-cache/global_packages/other/bin/x.dart-3.14.0.snapshot'),
          isFalse);
    });

    test('never under CI, npm or the opt-out', () {
      expect(autoUpdateAllowed(<String, String>{}, snapshot), isTrue);
      expect(
          autoUpdateAllowed(<String, String>{'CI': 'true'}, snapshot), isFalse);
      expect(autoUpdateAllowed(<String, String>{'TF_BUILD': 'True'}, snapshot),
          isFalse);
      expect(
          autoUpdateAllowed(
              <String, String>{kInstalledByEnvVar: 'npm'}, snapshot),
          isFalse);
      expect(
          autoUpdateAllowed(
              <String, String>{kNoAutoUpdateEnvVar: '1'}, snapshot),
          isFalse);
    });
  });

  group('runNewerIfAny', () {
    late Directory home;
    setUp(() => home = Directory.systemTemp.createTempSync('fl_self_update_'));
    tearDown(() => home.deleteSync(recursive: true));

    test('goes on when this is the latest, and does not ask again soon',
        () async {
      int asked = 0;
      Future<String?> latest() async {
        asked++;
        return kCliVersion;
      }

      final Map<String, String> env = <String, String>{'HOME': home.path};
      expect(
          await runNewerIfAny(<String>[],
              environment: env, script: snapshot, latest: latest),
          isNull);
      expect(
          await runNewerIfAny(<String>[],
              environment: env, script: snapshot, latest: latest),
          isNull);
      expect(asked, 1);
      final Map<String, dynamic> stamp = jsonDecode(
          File('${home.path}/.config/flutterlocalisation/auto_update.json')
              .readAsStringSync()) as Map<String, dynamic>;
      expect(stamp['version'], kCliVersion);
    });

    test('asks again once the wait is over', () async {
      int asked = 0;
      Future<String?> latest() async {
        asked++;
        return kCliVersion;
      }

      final Map<String, String> env = <String, String>{'HOME': home.path};
      DateTime at = DateTime(2026, 11, 26, 10);
      await runNewerIfAny(<String>[],
          environment: env, script: snapshot, latest: latest, now: () => at);
      at = at.add(kRecheckAfter + const Duration(seconds: 1));
      await runNewerIfAny(<String>[],
          environment: env, script: snapshot, latest: latest, now: () => at);
      expect(asked, 2);
    });

    test('goes on when pub.dev cannot be reached', () async {
      expect(
          await runNewerIfAny(<String>[],
              environment: <String, String>{'HOME': home.path},
              script: snapshot,
              latest: () async => null),
          isNull);
    });

    test('a checkout never looks', () async {
      bool asked = false;
      expect(
          await runNewerIfAny(<String>[],
              environment: <String, String>{'HOME': home.path},
              script: '/work/flutter_localisation_cli/bin/fl.dart',
              latest: () async {
            asked = true;
            return '99.0.0';
          }),
          isNull);
      expect(asked, isFalse);
    });
  });
}
