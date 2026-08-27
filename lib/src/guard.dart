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

// --------------------------------------------------------------------------- //
// Agent-facing docs
//
// The deny rules above stop an AI from writing the managed files, but a bare
// refusal teaches nothing — an agent that hits it tends to route *around* the
// guard (write the string elsewhere) instead of using the SaaS. These docs turn
// the block into an instruction: they state that FlutterLocalisation is the
// source of truth and show the correct `fl` workflow. Written to the two files
// coding agents read by convention — `AGENTS.md` (cross-tool) and `CLAUDE.md`
// (Claude Code, loaded automatically).
// --------------------------------------------------------------------------- //

/// Markers delimiting the `fl guard`-managed region inside AGENTS.md / CLAUDE.md.
/// Re-running the guard rewrites only what's between them, so a project's own
/// notes in those files survive.
const String kGuardDocStart = '<!-- fl:guard:start -->';
const String kGuardDocEnd = '<!-- fl:guard:end -->';

/// Result of writing/merging the agent guidance docs.
class AgentDocsResult {
  AgentDocsResult({required this.files, required this.created});

  /// Absolute paths of the doc files written (AGENTS.md, CLAUDE.md).
  final List<String> files;

  /// Subset of [files] that were created fresh (vs. merged into an existing file).
  final List<String> created;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'docs': files,
        'docsCreated': created,
      };
}

/// Render the managed guidance block. [projectLabel] is a human name/id for the
/// SaaS project; [globs] are the write-protected paths, listed for reference.
String renderAgentDocBlock({
  required final String projectLabel,
  required final List<String> globs,
}) {
  final String protectedList =
      globs.map((final String g) => '  - `$g`').join('\n');
  return '''
$kGuardDocStart
## Localization is managed by FlutterLocalisation — do not hand-edit strings

**Source of truth: the FlutterLocalisation SaaS (project "$projectLabel"), NOT this repo.**
Dashboard: https://app.flutterlocalisation.com · CLI: `fl`

The ARB files and the generated localization Dart are produced by the backend and
`fl` codegen. They are write-protected in `.claude/settings.json` (Edit/Write are
denied) because the next sync silently overwrites any manual change — or drops it
entirely, for the git-ignored ARB repo. Protected paths:
$protectedList

**Never hand-edit, create, or regenerate those files, and never route around the
write-guard** (e.g. by writing the string into some other file). If an edit is
refused, that is the guard working as intended.

To add or change a user-facing string:
1. Author it in the SaaS — the dashboard, or the `fl` CLI:
   - `fl add <key> --value "Hello" --translate`
   - `fl edit <key> --value "Hi" --locale en`
2. Pull the regenerated ARBs into the repo: `fl pull`.
3. Reference the key through the generated accessor in code.

**Work in bulk. Never loop a `fl` command.** Every one of these commands already
takes the whole job; running it once per item is what exhausts the daily API
budget, and it is refused after a few calls:

| Instead of looping…                    | Run once                                        |
| -------------------------------------- | ----------------------------------------------- |
| `fl add` per key                        | `fl import <file>.arb --translate`               |
| `fl languages add <code>` per locale    | `fl languages add <c1> <c2> <c3> --auto-translate` |
| `fl retranslate --locale <one>` per locale | `fl retranslate` (no `--locale` = every locale) |
| `fl translate <key>` per key            | `fl retranslate`                                 |

A 429 or a refusal is never a signal to sleep and retry: backing off runs the
same wrong algorithm slower. Switch to the bulk call. If a request times out, do
not shrink the batch — the client halves and retries on its own.

If the SaaS project is not connected to this git repo, `fl pull` (or the dashboard
Export) is how the ARBs land here — ask the maintainer to connect the repo in the
dashboard so it syncs automatically. Do not fabricate the ARB by hand instead.

<!-- Managed by `fl guard`; content between these markers is regenerated. -->
$kGuardDocEnd''';
}

/// Write/merge the managed guidance block into `AGENTS.md` and `CLAUDE.md` at
/// [projectRoot]. Idempotent: an existing managed block is replaced in place,
/// surrounding project content is preserved, a file without the block gets it
/// appended, and a missing file is created with just the block.
AgentDocsResult installAgentDocs(
  final Directory projectRoot, {
  required final String projectLabel,
  required final List<String> globs,
}) {
  final String block =
      renderAgentDocBlock(projectLabel: projectLabel, globs: globs);
  final List<String> written = <String>[];
  final List<String> created = <String>[];
  for (final String name in <String>['AGENTS.md', 'CLAUDE.md']) {
    final File f = File('${projectRoot.path}/$name');
    final bool existed = f.existsSync();
    final String next =
        _mergeManagedBlock(existed ? f.readAsStringSync() : null, block);
    f.writeAsStringSync(next);
    written.add(f.path);
    if (!existed) created.add(f.path);
  }
  return AgentDocsResult(files: written, created: created);
}

/// Splice [block] into [existing]: replace a prior `kGuardDocStart..kGuardDocEnd`
/// region if present, else append the block to non-empty content, else return
/// just the block for a fresh file.
String _mergeManagedBlock(final String? existing, final String block) {
  if (existing == null || existing.trim().isEmpty) {
    return '$block\n';
  }
  final int start = existing.indexOf(kGuardDocStart);
  final int end = existing.indexOf(kGuardDocEnd);
  if (start >= 0 && end > start) {
    final String before = existing.substring(0, start);
    final String after = existing.substring(end + kGuardDocEnd.length);
    return '$before$block$after';
  }
  return '${existing.trimRight()}\n\n$block\n';
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
