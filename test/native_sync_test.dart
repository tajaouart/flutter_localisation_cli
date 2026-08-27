import 'dart:convert';
import 'dart:io';

import 'package:flutter_localisation_cli/src/native_sync.dart';
import 'package:test/test.dart';

/// A pbxproj with the sections `syncPbxproj` anchors on, and nothing else.
const String _minimalPbxproj = '''
// !\$*UTF8*\$!
{
	objects = {

/* Begin PBXBuildFile section */
		97C146FC1CF9000F007C117D /* Main.storyboard in Resources */ = {isa = PBXBuildFile; fileRef = 97C146FA1CF9000F007C117D /* Main.storyboard */; };
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
		97C147021CF9000F007C117D /* Info.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; };
/* End PBXFileReference section */

/* Begin PBXGroup section */
		97C146F01CF9000F007C117D /* Runner */ = {
			isa = PBXGroup;
			children = (
				97C147021CF9000F007C117D /* Info.plist */,
			);
			path = Runner;
			sourceTree = "<group>";
		};
/* End PBXGroup section */

/* Begin PBXResourcesBuildPhase section */
		97C146EC1CF9000F007C117D /* Resources */ = {
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				97C146FC1CF9000F007C117D /* Main.storyboard in Resources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXResourcesBuildPhase section */

/* Begin PBXProject section */
		97C146E61CF9000F007C117D /* Project object */ = {
			isa = PBXProject;
			knownRegions = (
				en,
				Base,
			);
		};
/* End PBXProject section */

/* Begin PBXVariantGroup section */
		97C146FA1CF9000F007C117D /* Main.storyboard */ = {
			isa = PBXVariantGroup;
			children = (
				97C146FB1CF9000F007C117D /* Base */,
			);
			name = Main.storyboard;
			sourceTree = "<group>";
		};
/* End PBXVariantGroup section */
	};
}
''';

const String _minimalPlist = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>runner</string>
	<key>NSCameraUsageDescription</key>
	<string>We need your camera.</string>
</dict>
</plist>
''';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('fl_native_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  /// A project just complete enough to plan against.
  Directory fixture({
    final String locales = "Locale('en'), Locale('fr'), Locale('tl')",
    final Map<String, dynamic>? copy,
  }) {
    Directory('${tmp.path}/lib/localization/generated')
        .createSync(recursive: true);
    File('${tmp.path}/l10n.yaml').writeAsStringSync(
      'output-dir: lib/localization/generated\n'
      'output-localization-file: app_localizations.dart\n',
    );
    File('${tmp.path}/lib/localization/generated/app_localizations.dart')
        .writeAsStringSync(
      'static const List<Locale> supportedLocales = <Locale>[$locales];',
    );
    Directory('${tmp.path}/ios/Runner').createSync(recursive: true);
    File('${tmp.path}/ios/Runner/Info.plist').writeAsStringSync(_minimalPlist);
    File('${tmp.path}/ios/Runner/AppDelegate.swift').writeAsStringSync('');
    Directory('${tmp.path}/ios/Runner.xcodeproj').createSync(recursive: true);
    File('${tmp.path}/ios/Runner.xcodeproj/project.pbxproj')
        .writeAsStringSync(_minimalPbxproj);
    Directory('${tmp.path}/android/app/src/main').createSync(recursive: true);
    File('${tmp.path}/android/app/src/main/AndroidManifest.xml')
        .writeAsStringSync('<manifest>\n    <application android:label="x">\n'
            '    </application>\n</manifest>\n');
    if (copy != null) {
      File('${tmp.path}/ios/Runner/$kCopyFileName')
          .writeAsStringSync(jsonEncode(copy));
    }
    return tmp;
  }

  group('locale spelling', () {
    test('iOS gets fil beside tl, and script codes instead of bare zh', () {
      final Map<String, String> codes =
          iosCodeToLocale(<String>['en', 'tl', 'zh']);

      expect(codes.keys, containsAll(<String>['en', 'tl', 'fil']));
      expect(codes['fil'], 'tl', reason: 'Filipino reads the Tagalog copy');
      expect(codes.containsKey('zh'), isFalse,
          reason: 'modern iOS does not match a bare zh.lproj');
      expect(codes['zh-Hans'], 'zh');
    });

    test('an exact locale beats the expansion that would shadow it', () {
      // Without this, Traditional Chinese is handed the Simplified text —
      // fluent, wrong, and invisible to anyone who does not read Chinese.
      final Map<String, String> codes =
          iosCodeToLocale(<String>['zh', 'zh-Hans', 'zh-Hant']);

      expect(codes['zh-Hant'], 'zh-Hant');
      expect(codes['zh-Hans'], 'zh-Hans');
    });
  });

  group('Info.plist', () {
    test('the locale array is created when the key was never there', () {
      final String out = syncInfoPlist(_minimalPlist, <String>['en', 'fr']);

      expect(out, contains('<key>CFBundleLocalizations</key>'));
      expect(out, contains('<string>fr</string>'));
      expect(out.trim(), endsWith('</plist>'));
    });

    test('rewriting is idempotent and drops locales that were removed', () {
      final String once = syncInfoPlist(_minimalPlist, <String>['en', 'fr']);
      final String twice = syncInfoPlist(once, <String>['en', 'fr']);
      expect(twice, once);

      final String fewer = syncInfoPlist(once, <String>['en']);
      expect(fewer, isNot(contains('<string>fr</string>')));
    });

    test('the development-language copy is generated too', () {
      final String out = syncInfoPlist(
        _minimalPlist,
        <String>['en'],
        englishCopy: <String, String>{
          'NSCameraUsageDescription': 'To trace over what you see.',
        },
      );

      expect(out, contains('<string>To trace over what you see.</string>'));
      expect(out, isNot(contains('We need your camera.')));
    });
  });

  group('.strings rendering', () {
    test('quotes and backslashes are escaped, newlines flattened', () {
      final String out = renderStringsFile(<String, String>{
        'NSCameraUsageDescription': 'She said "hi"\\there\nagain',
      });

      expect(out, contains(r'\"hi\"'));
      expect(out, contains(r'\\there'));
      expect(out, isNot(contains('again\n"NS')));
      expect(out.trimRight(), endsWith(';'));
    });

    test('only the keys the copy actually has are written', () {
      final String out = renderStringsFile(<String, String>{
        'NSCameraUsageDescription': 'x',
      });

      expect(out, contains('NSCameraUsageDescription'));
      expect(out, isNot(contains('NSUserTrackingUsageDescription')));
    });
  });

  group('project.pbxproj', () {
    test('every locale is registered, grouped, and copied by a build phase', () {
      final String out = syncPbxproj(_minimalPbxproj, <String>['en', 'fr']);

      expect(out, contains('path = "fr.lproj/InfoPlist.strings"'));
      expect(out, contains('name = InfoPlist.strings;'));
      expect(out, contains('/* InfoPlist.strings in Resources */,'),
          reason: 'a resource no build phase copies never reaches the bundle');
      expect(out, contains('"fr",'), reason: 'knownRegions');
    });

    test('re-running replaces the previous generation instead of stacking', () {
      final String once = syncPbxproj(_minimalPbxproj, <String>['en', 'fr']);
      final String twice = syncPbxproj(once, <String>['en', 'fr']);
      expect(twice, once);

      final String fewer = syncPbxproj(once, <String>['en']);
      expect(fewer, isNot(contains('fr.lproj/InfoPlist.strings')));
      expect('fr.lproj'.allMatches(fewer).length, 0);
    });

    test('object ids are stable across runs', () {
      // Random ids would rewrite the whole project file on every sync and make
      // the diff unreadable — which is how a generated file stops being read.
      expect(pbxId('InfoPlist.strings/fr'), pbxId('InfoPlist.strings/fr'));
      expect(pbxId('InfoPlist.strings/fr'),
          isNot(pbxId('InfoPlist.strings/de')));
      expect(pbxId('InfoPlist.strings/fr'), matches(RegExp(r'^[0-9A-F]{24}$')));
    });
  });

  group('planNativeSync', () {
    test('declares the locales even with no permission copy at all', () {
      final NativeSyncPlan plan = planNativeSync(fixture());

      expect(plan.locales, <String>['en', 'fr', 'tl']);
      expect(plan.files.keys, contains('${tmp.path}/ios/Runner/Info.plist'));
      expect(
        plan.files.keys,
        contains('${tmp.path}/android/app/src/main/res/xml/locales_config.xml'),
      );
      expect(plan.files.keys.where((final String p) => p.endsWith('.strings')),
          isEmpty);
      expect(plan.notes.join(), contains(kCopyFileName),
          reason: 'a partial run has to say what it skipped');
    });

    test('writes one .strings per iOS code when the copy file is there', () {
      final Directory root = fixture(copy: <String, dynamic>{
        'en': <String, String>{'NSCameraUsageDescription': 'Camera'},
        'fr': <String, String>{'NSCameraUsageDescription': 'Appareil photo'},
        'tl': <String, String>{'NSCameraUsageDescription': 'Kamera'},
      });

      final NativeSyncPlan plan = planNativeSync(root);

      expect(plan.files['${tmp.path}/ios/Runner/fr.lproj/InfoPlist.strings'],
          contains('Appareil photo'));
      expect(plan.files['${tmp.path}/ios/Runner/fil.lproj/InfoPlist.strings'],
          contains('Kamera'),
          reason: 'fil is how devices report Filipino');
    });

    test('a locale with no copy is a hard failure, not English by default', () {
      final Directory root = fixture(copy: <String, dynamic>{
        'en': <String, String>{'NSCameraUsageDescription': 'Camera'},
      });

      // Falling back would ship a French alert written in English and look
      // finished — the exact failure this command exists to make impossible.
      expect(() => planNativeSync(root), throwsA(isA<StateError>()));
    });

    test('the manifest is pointed at the locale config it would otherwise ignore',
        () {
      final NativeSyncPlan plan = planNativeSync(fixture());
      final String manifest =
          plan.files['${tmp.path}/android/app/src/main/AndroidManifest.xml']!;

      expect(manifest, contains('android:localeConfig="@xml/locales_config"'));
      expect(syncAndroidManifest(manifest), manifest,
          reason: 'adding it twice would be an invalid manifest');
    });

    test('stale is empty once applied, and applying twice writes nothing', () {
      final Directory root = fixture(copy: <String, dynamic>{
        'en': <String, String>{'NSCameraUsageDescription': 'Camera'},
        'fr': <String, String>{'NSCameraUsageDescription': 'Appareil photo'},
        'tl': <String, String>{'NSCameraUsageDescription': 'Kamera'},
      });

      expect(applyNativeSync(planNativeSync(root)), isNotEmpty);
      expect(planNativeSync(root).stale, isEmpty);
      expect(applyNativeSync(planNativeSync(root)), isEmpty);
    });

    test('a dropped locale takes its .lproj with it', () {
      final Directory root = fixture(copy: <String, dynamic>{
        'en': <String, String>{'NSCameraUsageDescription': 'Camera'},
        'fr': <String, String>{'NSCameraUsageDescription': 'Appareil photo'},
        'tl': <String, String>{'NSCameraUsageDescription': 'Kamera'},
      });
      applyNativeSync(planNativeSync(root));
      expect(Directory('${tmp.path}/ios/Runner/fr.lproj').existsSync(), isTrue);

      File('${tmp.path}/lib/localization/generated/app_localizations.dart')
          .writeAsStringSync(
        "static const List<Locale> supportedLocales = <Locale>[Locale('en')];",
      );
      applyNativeSync(planNativeSync(root));

      expect(Directory('${tmp.path}/ios/Runner/fr.lproj').existsSync(), isFalse,
          reason: 'a stale .lproj keeps shipping copy for a dead locale');
    });
  });

  test('locales are read from Locale.fromSubtags in any argument order', () {
    // An order-sensitive pattern read `countryCode: 'HK', scriptCode: 'Hant'`
    // as zh-HK and dropped the script, which is a different language.
    final Directory root = fixture(
      locales: "Locale('en'), "
          "Locale.fromSubtags(languageCode: 'zh', countryCode: 'HK', "
          "scriptCode: 'Hant')",
    );

    expect(planNativeSync(root).locales, contains('zh-Hant-HK'));
  });
}
