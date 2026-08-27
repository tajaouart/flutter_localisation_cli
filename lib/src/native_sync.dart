/// Tell iOS and Android what languages the app has — and, on iOS, translate the
/// permission alerts the system draws before any app code runs.
///
/// Translating an app is not one job but three, and only the first is the one
/// everybody remembers:
///
///  1. **The UI**, from the ARBs. That is the rest of this package.
///  2. **The declarations.** `CFBundleLocalizations` in `Info.plist` and
///     `res/xml/locales_config.xml` on Android. Neither translates anything.
///     What they buy is the App Store product page's *Languages* row and the
///     per-app language picker in Settings — and with the key absent iOS reads
///     the bundle as English-only, so an app translated into 31 languages
///     advertised one in every storefront.
///  3. **The permission alerts.** `NSCameraUsageDescription` and friends are
///     drawn by iOS itself, from the bundle, before the Dart isolate exists.
///     No runtime lookup can reach them. The only way to translate them is a
///     `<code>.lproj/InfoPlist.strings` per language, and the file has to be
///     registered with the Xcode target or it is never copied into the bundle —
///     right on disk, missing at runtime, indistinguishable from never having
///     done it.
///
/// All three are hand-maintained lists that rot silently: nothing fails, the
/// app just quietly stops being translated in the places nobody looks. So they
/// are generated from the one list that is always right — the locales the
/// project actually ships.
///
/// Pure Dart, no network, no Flutter — safe to run anywhere, including CI.
library;

import 'dart:convert';
import 'dart:io';

/// iOS spells a few locales differently from Flutter.
///
/// Devices report Filipino as `fil`, and modern iOS will not match a bare `zh`
/// — it wants the script. Both spellings are kept for Tagalog so a device on
/// either code is covered.
const Map<String, List<String>> kIosSpelling = <String, List<String>>{
  'tl': <String>['tl', 'fil'],
  'zh': <String>['zh-Hans', 'zh-Hant'],
};

/// The `Info.plist` keys whose value is user-facing copy rather than
/// configuration — the only ones worth translating.
///
/// `CFBundleDisplayName` is deliberately not here: an app's name is usually its
/// brand, and a brand does not get translated.
const List<String> kInfoPlistCopyKeys = <String>[
  'NSCameraUsageDescription',
  'NSMicrophoneUsageDescription',
  'NSPhotoLibraryUsageDescription',
  'NSPhotoLibraryAddUsageDescription',
  'NSLocationWhenInUseUsageDescription',
  'NSLocationAlwaysAndWhenInUseUsageDescription',
  'NSContactsUsageDescription',
  'NSCalendarsUsageDescription',
  'NSFaceIDUsageDescription',
  'NSSpeechRecognitionUsageDescription',
  'NSUserTrackingUsageDescription',
];

/// The copy file a project writes its permission sentences into.
const String kCopyFileName = 'InfoPlist.copy.json';

/// Everything [planNativeSync] worked out, before anything is written.
///
/// Separating the plan from the write is what makes `--check` exact: the same
/// code path decides what the files should contain either way, so "stale" can
/// never mean something different from what a real run would produce.
class NativeSyncPlan {
  NativeSyncPlan({
    required this.root,
    required this.locales,
    required this.iosCodes,
    required this.files,
    required this.obsolete,
    required this.notes,
  });

  final Directory root;

  /// The locales the project ships, as BCP-47 tags, sorted.
  final List<String> locales;

  /// iOS locale code → the tag whose copy it carries. Not the identity: `fil`
  /// takes its text from `tl`, and `zh-Hans` from `zh` unless `zh-Hans` exists
  /// in its own right.
  final Map<String, String> iosCodes;

  /// Absolute path → the contents that path should have.
  final Map<String, String> files;

  /// `.lproj` directories for locales the project no longer ships.
  final List<String> obsolete;

  /// What was skipped, and why — a plan is allowed to be partial (a project
  /// with no iOS folder, or no copy file yet) and must say so out loud.
  final List<String> notes;

  /// The paths whose contents on disk differ from what they should be.
  List<String> get stale => <String>[
        for (final MapEntry<String, String> file in files.entries)
          if (!File(file.key).existsSync() ||
              File(file.key).readAsStringSync() != file.value)
            file.key,
        ...obsolete,
      ];
}

/// Locate the project's iOS target folder — the one holding `Info.plist`.
///
/// `ios/Runner` in every Flutter app anyone has not renamed, but renaming it is
/// allowed, so fall back to whichever `ios/*/Info.plist` sits beside an app
/// delegate. `Flutter/AppFrameworkInfo.plist` and `Pods/` are neither.
Directory? findIosTargetDir(final Directory root) {
  final Directory conventional = Directory('${root.path}/ios/Runner');
  if (File('${conventional.path}/Info.plist').existsSync()) return conventional;

  final Directory ios = Directory('${root.path}/ios');
  if (!ios.existsSync()) return null;
  for (final Directory dir in ios.listSync().whereType<Directory>()) {
    final bool hasDelegate = File('${dir.path}/AppDelegate.swift').existsSync() ||
        File('${dir.path}/AppDelegate.m').existsSync();
    if (hasDelegate && File('${dir.path}/Info.plist').existsSync()) return dir;
  }
  return null;
}

/// The `project.pbxproj` of the app's Xcode project.
File? findPbxproj(final Directory root) {
  final Directory ios = Directory('${root.path}/ios');
  if (!ios.existsSync()) return null;
  for (final Directory dir in ios.listSync().whereType<Directory>()) {
    if (!dir.path.endsWith('.xcodeproj')) continue;
    final File pbxproj = File('${dir.path}/project.pbxproj');
    if (pbxproj.existsSync()) return pbxproj;
  }
  return null;
}

/// The locales the project ships, read from the generated localisations.
///
/// The generated Dart is committed, so this works in a fresh clone with no ARB
/// checkout and no network — which is the difference between a check that can
/// run in CI and one that cannot.
List<String>? localesFromGeneratedDart(final Directory root) {
  final File? generated = _findGeneratedLocalisations(root);
  if (generated == null) return null;

  final String source = generated.readAsStringSync();
  // The declaration, not the first mention: the file's own doc comment shows a
  // `supportedLocales` usage example above it, and matching that yields a slice
  // with no locales in it at all.
  final int start = source.indexOf('supportedLocales = <Locale>[');
  if (start == -1) return null;
  final String body = source.substring(start, source.indexOf('];', start));

  final List<String> locales = <String>[];
  for (final RegExpMatch match
      in RegExp(r"Locale\('([a-z]{2,3})'(?:,\s*'([A-Za-z0-9]+)')?\)")
          .allMatches(body)) {
    locales.add(<String?>[match.group(1), match.group(2)]
        .whereType<String>()
        .join('-'));
  }
  // Named arguments arrive in whatever order the generator felt like, so read
  // them by name: an order-sensitive pattern turned `countryCode: 'HK',
  // scriptCode: 'Hant'` into `zh-HK` and dropped the script.
  for (final RegExpMatch call
      in RegExp(r'Locale\.fromSubtags\(([^)]*)\)').allMatches(body)) {
    final String args = call.group(1)!;
    String? subtag(final String name) =>
        RegExp("$name:\\s*'([A-Za-z0-9]+)'").firstMatch(args)?.group(1);
    locales.add(<String?>[
      subtag('languageCode'),
      subtag('scriptCode'),
      subtag('countryCode'),
    ].whereType<String>().join('-'));
  }
  if (locales.isEmpty) return null;
  return locales.toSet().toList()..sort();
}

File? _findGeneratedLocalisations(final Directory root) {
  final File l10nYaml = File('${root.path}/l10n.yaml');
  String? outputDir;
  String outputFile = 'app_localizations.dart';
  if (l10nYaml.existsSync()) {
    for (final String line in l10nYaml.readAsLinesSync()) {
      final String trimmed = line.trim();
      if (trimmed.startsWith('output-dir:')) {
        outputDir = trimmed.substring('output-dir:'.length).trim();
      } else if (trimmed.startsWith('output-localization-file:')) {
        outputFile =
            trimmed.substring('output-localization-file:'.length).trim();
      }
    }
  }
  for (final String dir in <String>[
    if (outputDir != null) outputDir,
    'lib/localization/generated',
    'lib/l10n/generated',
    'lib/generated/l10n',
    'lib/l10n',
  ]) {
    final File candidate = File('${root.path}/$dir/$outputFile');
    if (candidate.existsSync()) return candidate;
  }
  return null;
}

/// Fallback locale discovery: the ARB filenames themselves.
///
/// Used when the generated Dart is absent — a project mid-setup, or one that
/// has not run codegen yet.
List<String>? localesFromArbDir(final Directory root, {final String? arbDir}) {
  for (final String dir in <String>[
    if (arbDir != null) arbDir,
    'arbs/Default',
    'lib/l10n',
    'l10n',
  ]) {
    final Directory candidate = Directory('${root.path}/$dir');
    if (!candidate.existsSync()) continue;
    final List<String> locales = <String>[];
    for (final File file in candidate.listSync().whereType<File>()) {
      final RegExpMatch? match =
          RegExp(r'_([A-Za-z]{2,3}(?:_[A-Za-z0-9]+){0,2})\.arb$')
              .firstMatch(file.path);
      if (match != null) locales.add(match.group(1)!.replaceAll('_', '-'));
    }
    if (locales.isNotEmpty) return locales..sort();
  }
  return null;
}

/// Every iOS code the app ships, mapped back to the locale whose copy it takes.
Map<String, String> iosCodeToLocale(final List<String> locales) {
  final Map<String, String> byCode = <String, String>{};
  for (final String locale in locales) {
    for (final String code in kIosSpelling[locale] ?? <String>[locale]) {
      // Only an exact match may overwrite an earlier claim, or Traditional
      // Chinese gets handed the Simplified translation.
      if (!byCode.containsKey(code) || code == locale) {
        byCode[code] = locale;
      }
    }
  }
  return byCode;
}

/// Read `<target>/InfoPlist.copy.json`: locale → plist key → sentence.
///
/// Absent is not an error. Plenty of apps ask for no permissions at all, and
/// the declarations half of this command is worth having on its own.
Map<String, Map<String, String>>? readCopyFile(final Directory targetDir) {
  final File file = File('${targetDir.path}/$kCopyFileName');
  if (!file.existsSync()) return null;
  final Map<String, dynamic> raw =
      jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  return <String, Map<String, String>>{
    // `//` is the file's own doc comment: JSON has nowhere else to put one.
    for (final MapEntry<String, dynamic> entry in raw.entries)
      if (!entry.key.startsWith('//'))
        entry.key: Map<String, String>.from(entry.value as Map<String, dynamic>),
  };
}

/// Render one `.strings` file — an old-style plist: quoted key, quoted value,
/// semicolon, UTF-8.
String renderStringsFile(final Map<String, String> copy) {
  String escape(final String value) => value
      .replaceAll(r'\', r'\\')
      .replaceAll('"', r'\"')
      .replaceAll('\n', r'\n');

  final StringBuffer out = StringBuffer()
    ..writeln('/* GENERATED by `fl native` from $kCopyFileName — do not edit.')
    ..writeln('   iOS draws these sentences itself, in the permission alert,')
    ..writeln('   before the app is allowed to run any of its own code. */');
  for (final String key in kInfoPlistCopyKeys) {
    final String? value = copy[key];
    if (value != null) out.writeln('"$key" = "${escape(value)}";');
  }
  return out.toString();
}

/// Replace the body of a block, keeping everything around it — including the
/// comments above the list, which are usually the only record of why it exists.
String _replaceBetween(
  final String source,
  final String openMarker,
  final String closeMarker,
  final String body,
) {
  final int open = source.indexOf(openMarker);
  if (open == -1) return source;
  final int bodyStart = open + openMarker.length;
  final int bodyEnd = source.indexOf(closeMarker, bodyStart);
  return '${source.substring(0, bodyStart)}\n$body\n${source.substring(bodyEnd)}';
}

/// The `Info.plist` with its `CFBundleLocalizations` array rewritten, and the
/// key created if the project never had one.
String syncInfoPlist(
  final String plist,
  final List<String> iosCodes, {
  final Map<String, String> englishCopy = const <String, String>{},
}) {
  const String comment = '''
	<!-- GENERATED by `fl native` — do not hand-edit the array.
	     Every locale the app ships, in iOS's spelling.

	     Without this key iOS reads the bundle as English-only, which is what
	     the App Store product page's Languages row reports. It is not what
	     makes the UI translate — Flutter reads the device language from
	     NSLocale.preferredLanguages, which this does not gate — and it does not
	     translate the permission alerts either: those need a
	     <code>.lproj/InfoPlist.strings each. -->''';
  final String body =
      iosCodes.map((final String c) => '\t\t<string>$c</string>').join('\n');

  String out = plist;
  if (!out.contains('<key>CFBundleLocalizations</key>')) {
    // Insert before the closing </dict>, the one place that is always there.
    final int close = out.lastIndexOf('</dict>');
    out = '${out.substring(0, close)}$comment\n'
        '\t<key>CFBundleLocalizations</key>\n\t<array>\n$body\n\t</array>\n'
        '${out.substring(close)}';
  } else {
    out = _replaceBetween(
      out,
      '<key>CFBundleLocalizations</key>\n\t<array>',
      '\t</array>',
      body,
    );
  }

  // The development-region copy is generated too, so English cannot drift away
  // from the text the other locales were translated from.
  englishCopy.forEach((final String key, final String value) {
    final RegExp pair =
        RegExp('(<key>$key</key>\\s*<string>).*?(</string>)', dotAll: true);
    if (!pair.hasMatch(out)) return;
    final String escaped = value
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
    out = out.replaceFirstMapped(
      pair,
      (final Match m) => '${m.group(1)}$escaped${m.group(2)}',
    );
  });
  return out;
}

/// The Android `locales_config.xml`, written from scratch when absent.
String renderLocalesConfig(final List<String> locales) {
  final StringBuffer out = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="utf-8"?>')
    ..writeln('<!--')
    ..writeln('  GENERATED by `fl native` — do not hand-edit the list.')
    ..writeln('  Every locale the app ships, sorted.')
    ..writeln('')
    ..writeln('  This is what puts "App language" in the app\'s page in Android')
    ..writeln('  Settings on Android 13+. Without it Android has no idea the')
    ..writeln('  app is translated at all: the translations live in the ARBs,')
    ..writeln('  and nothing in res/values-*/ ever tells the platform they')
    ..writeln('  exist. An in-app picker works either way, which is why the')
    ..writeln('  absence goes unnoticed.')
    ..writeln('-->')
    ..writeln('<locale-config xmlns:android="http://schemas.android.com/apk/res/android">');
  for (final String locale in locales) {
    out.writeln('    <locale android:name="$locale" />');
  }
  out.writeln('</locale-config>');
  return out.toString();
}

/// Point the manifest's `<application>` at the locale config.
///
/// The file existing is not enough — an unreferenced `locales_config.xml` is
/// the same as not having one.
String syncAndroidManifest(final String manifest) {
  if (manifest.contains('android:localeConfig=')) return manifest;
  final RegExpMatch? app = RegExp(r'<application\b').firstMatch(manifest);
  if (app == null) return manifest;
  return manifest.replaceFirst(
    '<application',
    '<application\n        android:localeConfig="@xml/locales_config"',
  );
}

/// A stable 24-hex Xcode object id, derived from what it names.
///
/// Deterministic rather than random so re-running does not churn the project
/// file and two people generating it get the same diff. Three 32-bit FNV-1a
/// passes: Dart's 64-bit ints are signed and wrap, which makes hex of them
/// awkward.
String pbxId(final String seed) {
  int fnv(final int start) {
    int h = start;
    for (final int c in seed.codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0xFFFFFFFF;
    }
    return h;
  }

  return <int>[0x811C9DC5, 0x01000193, 0xDEADBEEF]
      .map((final int s) =>
          fnv(s).toRadixString(16).padLeft(8, '0').toUpperCase())
      .join();
}

/// Register the `.lproj/InfoPlist.strings` files with the app target.
///
/// Entries are found and replaced by what they contain rather than by marker
/// comments: Xcode rewrites this file from its own model whenever the project
/// is edited in the IDE, and any comment it did not write is dropped. The
/// `/* Begin … section */` headers are Xcode's own and do survive.
String syncPbxproj(final String source, final List<String> iosCodes) {
  final String variantId = pbxId('InfoPlist.strings/variant-group');
  final String buildId = pbxId('InfoPlist.strings/build-file');

  // Drop the previous generation. The variant group goes first, as a block: its
  // children are `/* fr */`-style lines the line filter cannot recognise alone.
  String out = source.replaceAll(
    RegExp(
      r'\n\t\t[0-9A-F]{24} /\* InfoPlist\.strings \*/ = \{\n'
      r'(?:\t\t\t.*\n|\t\t\t\t.*\n)*?\t\t\};',
    ),
    '',
  );
  out = out
      .split('\n')
      .where((final String line) => !line.contains('InfoPlist.strings'))
      .join('\n');

  String insertAfter(final String haystack, final String anchor, final String body) {
    final int at = haystack.indexOf(anchor);
    if (at == -1) return haystack;
    final int end = at + anchor.length;
    return '${haystack.substring(0, end)}\n$body${haystack.substring(end)}';
  }

  out = insertAfter(
    out,
    '/* Begin PBXBuildFile section */',
    '\t\t$buildId /* InfoPlist.strings in Resources */ = {isa = PBXBuildFile; '
        'fileRef = $variantId /* InfoPlist.strings */; };',
  );
  out = insertAfter(
    out,
    '/* Begin PBXFileReference section */',
    iosCodes
        .map((final String c) =>
            '\t\t${pbxId('InfoPlist.strings/$c')} /* $c */ = {isa = PBXFileReference; '
            'lastKnownFileType = text.plist.strings; name = "$c"; '
            'path = "$c.lproj/InfoPlist.strings"; sourceTree = "<group>"; };')
        .join('\n'),
  );

  // The variant group section is optional in a project that has none — a
  // Flutter app always has the storyboards, but do not assume it.
  const String variantHeader = '/* Begin PBXVariantGroup section */';
  final String variantGroup = <String>[
    '\t\t$variantId /* InfoPlist.strings */ = {',
    '\t\t\tisa = PBXVariantGroup;',
    '\t\t\tchildren = (',
    ...iosCodes.map((final String c) =>
        '\t\t\t\t${pbxId('InfoPlist.strings/$c')} /* $c */,'),
    '\t\t\t);',
    '\t\t\tname = InfoPlist.strings;',
    '\t\t\tsourceTree = "<group>";',
    '\t\t};',
  ].join('\n');
  if (out.contains(variantHeader)) {
    out = insertAfter(out, variantHeader, variantGroup);
  } else {
    out = insertAfter(
      out,
      '/* End PBXTargetDependency section */',
      '\n$variantHeader\n$variantGroup\n/* End PBXVariantGroup section */',
    );
  }

  // Anchor the group entry on Info.plist's own file reference: it is in the
  // same group, in every Flutter project, whatever the target is called.
  final String? plistRef = RegExp(r'([0-9A-F]{24}) /\* Info\.plist \*/ = \{isa = PBXFileReference')
      .firstMatch(out)
      ?.group(1);
  if (plistRef != null) {
    out = insertAfter(
      out,
      '\t\t\t\t$plistRef /* Info.plist */,',
      '\t\t\t\t$variantId /* InfoPlist.strings */,',
    );
  }

  // And the build entry on the resources phase, which is what actually copies
  // the files into the bundle.
  final int phase = out.indexOf('isa = PBXResourcesBuildPhase;');
  if (phase != -1) {
    final int files = out.indexOf('files = (', phase);
    if (files != -1) {
      final int end = files + 'files = ('.length;
      out = '${out.substring(0, end)}\n'
          '\t\t\t\t$buildId /* InfoPlist.strings in Resources */,'
          '${out.substring(end)}';
    }
  }

  return _replaceBetween(
    out,
    'knownRegions = (',
    '\t\t\t);',
    <String>['Base', ...iosCodes].map((final String c) => '\t\t\t\t"$c",').join('\n'),
  );
}

/// Work out every file that should change, without touching the disk.
NativeSyncPlan planNativeSync(
  final Directory root, {
  final String? arbDir,
}) {
  final List<String>? locales =
      localesFromGeneratedDart(root) ?? localesFromArbDir(root, arbDir: arbDir);
  if (locales == null || locales.isEmpty) {
    throw StateError(
      'Could not work out which locales this project ships. Expected generated '
      'localisations (l10n.yaml output-dir) or a directory of .arb files.',
    );
  }

  final Map<String, String> byCode = iosCodeToLocale(locales);
  final List<String> codes = byCode.keys.toList()..sort();
  final Map<String, String> files = <String, String>{};
  final List<String> obsolete = <String>[];
  final List<String> notes = <String>[];

  // ---- iOS ----------------------------------------------------------------
  final Directory? target = findIosTargetDir(root);
  if (target == null) {
    notes.add('no iOS target found — skipped Info.plist and InfoPlist.strings');
  } else {
    final Map<String, Map<String, String>>? copy = readCopyFile(target);
    if (copy == null) {
      notes.add(
        'no ${target.path}/$kCopyFileName — declared the locales, but the '
        'permission alerts stay in the development language. `fl native '
        '--init-copy` writes a starter from the current Info.plist.',
      );
    } else {
      final List<String> missing =
          codes.where((final String c) => !copy.containsKey(byCode[c])).toList();
      if (missing.isNotEmpty) {
        throw StateError(
          'No permission copy for ${missing.map((final String c) => byCode[c]).toSet().join(", ")} '
          'in ${target.path}/$kCopyFileName. Every locale needs an entry, or '
          'iOS asks that language for its camera in the development language.',
        );
      }
      for (final String code in codes) {
        files['${target.path}/$code.lproj/InfoPlist.strings'] =
            renderStringsFile(copy[byCode[code]]!);
      }
      for (final Directory dir in target.listSync().whereType<Directory>()) {
        final String name = dir.path.split(Platform.pathSeparator).last;
        if (!name.endsWith('.lproj') || name == 'Base.lproj') continue;
        if (!codes.contains(name.substring(0, name.length - '.lproj'.length))) {
          obsolete.add(dir.path);
        }
      }
    }

    final File plist = File('${target.path}/Info.plist');
    files[plist.path] = syncInfoPlist(
      plist.readAsStringSync(),
      codes,
      englishCopy: copy?[_developmentLocale(locales)] ?? const <String, String>{},
    );

    final File? pbxproj = findPbxproj(root);
    if (pbxproj == null) {
      notes.add('no .xcodeproj found — the .strings files are not registered, '
          'so Xcode will not copy them into the bundle');
    } else if (copy != null) {
      files[pbxproj.path] = syncPbxproj(pbxproj.readAsStringSync(), codes);
    }
  }

  // ---- Android ------------------------------------------------------------
  final Directory android = Directory('${root.path}/android/app/src/main');
  if (!android.existsSync()) {
    notes.add('no android/app/src/main — skipped locales_config.xml');
  } else {
    final File config = File('${android.path}/res/xml/locales_config.xml');
    files[config.path] = config.existsSync()
        ? _replaceBetween(
            config.readAsStringSync(),
            '<locale-config xmlns:android="http://schemas.android.com/apk/res/android">',
            '</locale-config>',
            locales
                .map((final String c) => '    <locale android:name="$c" />')
                .join('\n'),
          )
        : renderLocalesConfig(locales);
    final File manifest = File('${android.path}/AndroidManifest.xml');
    if (manifest.existsSync()) {
      files[manifest.path] = syncAndroidManifest(manifest.readAsStringSync());
    }
  }

  return NativeSyncPlan(
    root: root,
    locales: locales,
    iosCodes: byCode,
    files: files,
    obsolete: obsolete,
    notes: notes,
  );
}

/// The locale the plist's own strings are written in — `en` when it ships one.
String _developmentLocale(final List<String> locales) =>
    locales.contains('en') ? 'en' : locales.first;

/// Write the plan. Returns the paths that changed.
List<String> applyNativeSync(final NativeSyncPlan plan) {
  final List<String> changed = plan.stale;
  plan.files.forEach((final String path, final String contents) {
    final File file = File(path);
    if (file.existsSync() && file.readAsStringSync() == contents) return;
    file
      ..createSync(recursive: true)
      ..writeAsStringSync(contents);
  });
  for (final String dir in plan.obsolete) {
    Directory(dir).deleteSync(recursive: true);
  }
  return changed;
}

/// Write a starter copy file from the `Info.plist` the project already has.
///
/// Only the development language: translating it is the caller's job, and a
/// machine-filled placeholder that reads as done is worse than an obvious gap.
String initCopyFile(final Directory targetDir, final String developmentLocale) {
  final String plist = File('${targetDir.path}/Info.plist').readAsStringSync();
  final Map<String, String> found = <String, String>{};
  for (final String key in kInfoPlistCopyKeys) {
    final RegExpMatch? match =
        RegExp('<key>$key</key>\\s*<string>(.*?)</string>', dotAll: true)
            .firstMatch(plist);
    if (match != null) {
      found[key] = match
          .group(1)!
          .replaceAll('&amp;', '&')
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>');
    }
  }
  final Map<String, dynamic> out = <String, dynamic>{
    '//': 'The Info.plist strings iOS shows in its own permission alerts, per '
        'locale. Not app strings: these never reach Dart — the system draws '
        'them from the bundle before the app runs — so they are translated '
        'once and committed. `fl native` turns this into '
        '<code>.lproj/InfoPlist.strings and registers them with the Xcode '
        'target. Every locale the app ships needs an entry here.',
    developmentLocale: found,
  };
  return '${const JsonEncoder.withIndent('  ').convert(out)}\n';
}
