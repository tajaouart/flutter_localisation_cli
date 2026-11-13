/// Checks a Flutter app's gen-l10n setup against what current Flutter accepts.
///
/// Since Flutter 3.32 the localizations are generated into the source tree,
/// and on 3.47 `synthetic-package: true` is a hard error. Apps written for the
/// old setup still import `package:flutter_gen/gen_l10n/...` and miss
/// `generate: true`, and they stop building on upgrade.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

class L10nIssue {
  L10nIssue(
    this.code,
    this.message, {
    this.file,
    this.fixable = true,
    this.fixed = false,
  });

  /// `intl-utils`, `synthetic-package`, `generate-flag`, `dependencies`,
  /// `flutter-gen-import` or `material-ui-delegates`.
  final String code;
  final String message;
  final String? file;

  /// Whether `--fix` can rewrite it; the rest needs a human.
  final bool fixable;
  bool fixed;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'code': code,
        'message': message,
        if (file != null) 'file': file,
        'fixable': fixable,
        'fixed': fixed,
      };
}

class L10nDoctorReport {
  L10nDoctorReport(this.issues, {required this.applicable});

  /// False when the folder has no gen-l10n setup at all.
  final bool applicable;
  final List<L10nIssue> issues;

  bool get ok => issues.every((final L10nIssue i) => i.fixed);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'applicable': applicable,
        'ok': ok,
        'issues': issues.map((final L10nIssue i) => i.toJson()).toList(),
      };
}

const String intlUtilsGuide =
    'https://flutterlocalisation.com/blog/migrate-intl-utils-flutter-intl-to-gen-l10n';

/// The `flutter_intl:` section or an `intl_utils` dependency.
final RegExp _intlUtils =
    RegExp(r'^(?:flutter_intl:|\s+intl_utils:)', multiLine: true);

/// Only import and export directives: the prefix inside a string or a comment is
/// not a dependency.
final RegExp _flutterGenDirective = RegExp(
  r"""^(\s*(?:import|export)\s+['"])package:flutter_gen/gen_l10n/""",
  multiLine: true,
);

/// Runs every check under [root]; with [fix] it also rewrites the files.
L10nDoctorReport checkL10nSetup(final Directory root,
    {final bool fix = false}) {
  final File l10nYaml = File(p.join(root.path, 'l10n.yaml'));
  final File pubspec = File(p.join(root.path, 'pubspec.yaml'));
  final List<File> importers = _dartFilesImportingFlutterGen(root);
  final bool intlUtils =
      pubspec.existsSync() && _intlUtils.hasMatch(pubspec.readAsStringSync());
  if (!l10nYaml.existsSync() && importers.isEmpty && !intlUtils) {
    return L10nDoctorReport(<L10nIssue>[], applicable: false);
  }

  final List<L10nIssue> issues = <L10nIssue>[
    if (intlUtils)
      L10nIssue(
        'intl-utils',
        'uses intl_utils (Flutter Intl), which is discontinued on pub.dev. '
            'Move to gen-l10n: $intlUtilsGuide',
        file: 'pubspec.yaml',
        fixable: false,
      ),
  ];
  String arbDir = 'lib/l10n';
  String? outputDir;

  if (l10nYaml.existsSync()) {
    final List<String> lines = l10nYaml.readAsLinesSync();
    int? syntheticLine;
    for (int i = 0; i < lines.length; i++) {
      final String? arb = _yamlValue(lines[i], 'arb-dir');
      if (arb != null) arbDir = _normalizeDir(arb);
      final String? out = _yamlValue(lines[i], 'output-dir');
      if (out != null) outputDir = _normalizeDir(out);
      if (_yamlValue(lines[i], 'synthetic-package') == 'true') {
        syntheticLine = i;
      }
    }
    if (syntheticLine != null) {
      final L10nIssue issue = L10nIssue(
        'synthetic-package',
        'synthetic-package: true was removed from Flutter and now fails the '
            'build. Generated files go into the source tree instead.',
        file: 'l10n.yaml',
      );
      if (fix) {
        lines.removeAt(syntheticLine);
        l10nYaml.writeAsStringSync('${lines.join('\n')}\n');
        issue.fixed = true;
      }
      issues.add(issue);
    }
  }

  if (pubspec.existsSync()) {
    final String body = pubspec.readAsStringSync();
    final String? patched = _withGenerateFlag(body);
    if (patched != null) {
      final L10nIssue issue = L10nIssue(
        'generate-flag',
        'pubspec.yaml needs `generate: true` under `flutter:`, otherwise '
            'gen-l10n refuses to run.',
        file: 'pubspec.yaml',
      );
      if (fix) {
        pubspec.writeAsStringSync(patched);
        issue.fixed = true;
      }
      issues.add(issue);
    }
  }

  if (pubspec.existsSync()) {
    final String body = pubspec.readAsStringSync();
    final List<String> missing = <String>[
      for (final String dep in <String>['flutter_localizations', 'intl'])
        if (!RegExp('^\\s+$dep:', multiLine: true).hasMatch(body)) dep,
    ];
    if (missing.isNotEmpty) {
      issues.add(
        L10nIssue(
          'dependencies',
          'the generated code imports ${missing.join(' and ')}, which '
              'pubspec.yaml does not depend on. Run: '
              '${<String>[
            if (missing.contains('flutter_localizations'))
              'flutter pub add flutter_localizations --sdk=flutter',
            if (missing.contains('intl')) 'flutter pub add intl:any',
          ].join(' && ')}',
          file: 'pubspec.yaml',
          fixable: false,
        ),
      );
    }
  }

  // Without a synthetic package, output-dir falls back to arb-dir.
  final String genDir = outputDir ?? arbDir;
  final String? packageName =
      pubspec.existsSync() ? _packageName(pubspec.readAsLinesSync()) : null;
  final bool underLib = genDir == 'lib' || genDir.startsWith('lib/');
  final String? replacement = packageName != null && underLib
      ? 'package:$packageName/${genDir == 'lib' ? '' : '${genDir.substring(4)}/'}'
      : null;

  for (final File f in importers) {
    final String rel =
        p.relative(f.path, from: root.path).replaceAll(r'\', '/');
    final L10nIssue issue = L10nIssue(
      'flutter-gen-import',
      replacement == null
          ? 'imports package:flutter_gen, which no longer exists. Import the '
              'generated file from $genDir instead.'
          : 'imports package:flutter_gen, which no longer exists. Use '
              '$replacement<file> instead.',
      file: rel,
      fixable: replacement != null,
    );
    if (fix && replacement != null) {
      f.writeAsStringSync(
        f.readAsStringSync().replaceAllMapped(
              _flutterGenDirective,
              (final Match m) => '${m[1]}$replacement',
            ),
      );
      issue.fixed = true;
    }
    issues.add(issue);
  }

  if (pubspec.existsSync() &&
      RegExp(r'^\s+material_ui:', multiLine: true)
          .hasMatch(pubspec.readAsStringSync())) {
    for (final File f in _dartFiles(root, <String>['lib'])) {
      final String rel =
          p.relative(f.path, from: root.path).replaceAll(r'\', '/');
      if (p.isWithin(genDir, rel) || p.dirname(rel) == genDir) continue;
      if (_legacyDelegates.hasMatch(_withoutComments(f.readAsStringSync()))) {
        issues.add(
          L10nIssue(
            'material-ui-delegates',
            'uses the gen-l10n localizationsDelegates list, which registers '
                'the flutter_localizations Material delegates. material_ui '
                'widgets do not read those, so they get no Material strings. '
                'Use [AppLocalizations.delegate, '
                '...GlobalMaterialLocalizations.delegates] from material_ui.',
            file: rel,
            fixable: false,
          ),
        );
      }
    }
  }

  return L10nDoctorReport(issues, applicable: true);
}

/// Whether the pubspec under [root] lacks `flutter: generate: true`, the
/// `generate-flag` check on its own. False when there is no pubspec.
bool lacksGenerateFlag(final Directory root) {
  final File pubspec = File(p.join(root.path, 'pubspec.yaml'));
  return pubspec.existsSync() &&
      _withGenerateFlag(pubspec.readAsStringSync()) != null;
}

/// Whether the pubspec under [root] lists [package] as a dependency of any
/// kind. False when there is no pubspec.
bool dependsOn(final Directory root, final String package) {
  final File pubspec = File(p.join(root.path, 'pubspec.yaml'));
  return pubspec.existsSync() &&
      RegExp('^\\s+${RegExp.escape(package)}:', multiLine: true)
          .hasMatch(pubspec.readAsStringSync());
}

String _withoutComments(final String dart) =>
    dart.replaceAll(RegExp(r'^\s*//.*$', multiLine: true), '');

final RegExp _legacyDelegates = RegExp(
  r'\b\w+\.localizationsDelegates\b|'
  r"package:flutter_localizations/flutter_localizations\.dart",
);

/// [pubspec] with `flutter: generate: true` set, or null when it already is.
String? _withGenerateFlag(final String pubspec) {
  final List<String> lines = pubspec.split('\n');
  final int flutterAt = lines.indexWhere(
      (final String l) => RegExp(r'^flutter:\s*(#.*)?$').hasMatch(l));
  if (flutterAt < 0) {
    final String sep = pubspec.endsWith('\n') ? '' : '\n';
    return '$pubspec$sep\nflutter:\n  generate: true\n';
  }
  String? indent;
  for (int i = flutterAt + 1; i < lines.length; i++) {
    final String l = lines[i];
    if (l.trim().isEmpty || l.trimLeft().startsWith('#')) continue;
    if (!l.startsWith(' ')) break;
    final String lineIndent = l.substring(0, l.length - l.trimLeft().length);
    indent ??= lineIndent;
    if (lineIndent != indent) continue;
    final String? v = _yamlValue(l, 'generate');
    if (v == 'true') return null;
    if (v != null) {
      lines[i] = '${indent}generate: true';
      return lines.join('\n');
    }
  }
  lines.insert(flutterAt + 1, '${indent ?? '  '}generate: true');
  return lines.join('\n');
}

String? _packageName(final List<String> lines) {
  for (final String l in lines) {
    if (l.startsWith(' ')) continue;
    final String? v = _yamlValue(l, 'name');
    if (v != null) return v;
  }
  return null;
}

List<File> _dartFilesImportingFlutterGen(final Directory root) => _dartFiles(
      root,
      <String>['lib', 'test', 'integration_test'],
    )
        .where((final File f) =>
            _flutterGenDirective.hasMatch(f.readAsStringSync()))
        .toList();

List<File> _dartFiles(final Directory root, final List<String> dirs) {
  final List<File> out = <File>[];
  for (final String dir in dirs) {
    final Directory d = Directory(p.join(root.path, dir));
    if (!d.existsSync()) continue;
    for (final FileSystemEntity e in d.listSync(recursive: true)) {
      if (e is File && e.path.endsWith('.dart')) out.add(e);
    }
  }
  out.sort((final File a, final File b) => a.path.compareTo(b.path));
  return out;
}

String _normalizeDir(final String raw) {
  String s = raw.trim();
  if (s.startsWith('./')) s = s.substring(2);
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

String? _yamlValue(final String line, final String key) {
  final String trimmed = line.trim();
  if (trimmed.startsWith('#') || !trimmed.startsWith('$key:')) return null;
  String v = trimmed.substring(key.length + 1).trim();
  final int hash = v.indexOf('#');
  if (hash >= 0) v = v.substring(0, hash).trim();
  if (v.length >= 2 &&
      ((v.startsWith('"') && v.endsWith('"')) ||
          (v.startsWith("'") && v.endsWith("'")))) {
    v = v.substring(1, v.length - 1);
  }
  return v.isEmpty ? null : v;
}
