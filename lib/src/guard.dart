/// Installs a Claude Code guard into a consuming project so AI agents cannot
/// hand-edit the FlutterLocalisation-managed files.
///
/// The ARB repo and the generated Dart are owned by the backend + codegen: they
/// only ever change through `fl` / `flutter_localisation` + git pull. If an AI
/// agent edits them directly the next sync silently overwrites its work (or, for
/// the gitignored ARB repo, the edit is lost entirely). This writes matching
/// `permissions.deny` rules into the project's `.claude/settings.json` — the
/// native, portable Claude Code mechanism — so `Edit`/`Write` on those paths is
/// refused for everyone on the repo.
///
/// Pure Dart, no network — safe to run anywhere.
library;

import 'dart:convert';
import 'dart:io';

class GuardResult {
  GuardResult({
    required this.settingsPath,
    required this.created,
    required this.protected,
    required this.added,
  });

  /// Absolute path to the `.claude/settings.json` that was written.
  final String settingsPath;

  /// True when the settings file was created fresh; false when merged into an
  /// existing one.
  final bool created;

  /// The glob patterns now protected (without the `Edit(...)`/`Write(...)` wrapper).
  final List<String> protected;

  /// The deny rules newly added this run (already-present rules are not repeated).
  final List<String> added;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'settings': settingsPath,
        'created': created,
        'protected': protected,
        'added': added,
      };
}

/// Derive the glob patterns that must be protected from the project layout:
///  * the ARB directory (from `flutterlocalisation.json` `arb_dir` and/or
///    `l10n.yaml` `arb-dir`) — the backend-pushed ARB repo,
///  * the generated localization Dart (`l10n.yaml` `output-dir`),
///  * `lib/generated_translation_methods.dart` — the `flutter_localisation`
///    generated accessors.
///
/// Always returns at least the generated-methods file so the guard is never empty.
List<String> deriveGuardGlobs(
  final Directory projectRoot, {
  final String? arbDirFromConfig,
}) {
  final Set<String> dirs = <String>{};
  if (arbDirFromConfig != null && arbDirFromConfig.trim().isNotEmpty) {
    dirs.add(_normalizeDir(arbDirFromConfig));
  }

  final File l10n = File('${projectRoot.path}/l10n.yaml');
  if (l10n.existsSync()) {
    for (final String line in l10n.readAsLinesSync()) {
      final String? arb = _yamlValue(line, 'arb-dir');
      if (arb != null) dirs.add(_normalizeDir(arb));
      final String? out = _yamlValue(line, 'output-dir');
      if (out != null) dirs.add(_normalizeDir(out));
    }
  }

  final List<String> globs = <String>[
    for (final String d in dirs) '$d/**',
    'lib/generated_translation_methods.dart',
  ];
  // Stable, de-duplicated order.
  return globs.toSet().toList()..sort();
}

/// Merge `Edit`/`Write` deny rules for [globs] into `<projectRoot>/.claude/settings.json`,
/// creating the file (and `.claude/`) if needed. Existing settings and any existing
/// deny rules are preserved; only missing rules are appended.
GuardResult installGuard(
  final Directory projectRoot, {
  required final List<String> globs,
}) {
  final Directory claudeDir = Directory('${projectRoot.path}/.claude');
  final File settings = File('${claudeDir.path}/settings.json');

  final bool created = !settings.existsSync();
  Map<String, dynamic> root = <String, dynamic>{};
  if (!created) {
    try {
      final Object? parsed = jsonDecode(settings.readAsStringSync());
      if (parsed is Map<String, dynamic>) root = parsed;
    } catch (_) {
      // Corrupt/non-object settings: don't clobber — surface via empty merge base
      // would be dangerous, so rethrow-style guard: start from what we can parse.
      root = <String, dynamic>{};
    }
  }

  final Map<String, dynamic> permissions =
      (root['permissions'] as Map<String, dynamic>?) ?? <String, dynamic>{};
  final List<String> deny = <String>[
    ...((permissions['deny'] as List<dynamic>?) ?? const <dynamic>[])
        .map((final dynamic e) => e.toString()),
  ];

  final List<String> wanted = <String>[
    for (final String g in globs) ...<String>['Edit($g)', 'Write($g)'],
  ];
  final List<String> added = <String>[];
  for (final String rule in wanted) {
    if (!deny.contains(rule)) {
      deny.add(rule);
      added.add(rule);
    }
  }

  permissions['deny'] = deny;
  root['permissions'] = permissions;

  claudeDir.createSync(recursive: true);
  settings.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(root)}\n',
  );

  return GuardResult(
    settingsPath: settings.path,
    created: created,
    protected: globs,
    added: added,
  );
}

String _normalizeDir(final String raw) {
  String s = raw.trim();
  if (s.startsWith('./')) s = s.substring(2);
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

/// Extract the value of `key:` from a single YAML line, ignoring comments and
/// quotes. Returns null if the line isn't that key. (Minimal, dependency-free —
/// l10n.yaml is a flat key/value file.)
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
