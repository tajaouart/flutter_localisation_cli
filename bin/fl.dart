#!/usr/bin/env dart
/// `fl` — FlutterLocalisation management CLI.
///
/// Add / edit / delete translation keys and strings — full parity with the dashboard —
/// straight from the terminal, then `git pull` the regenerated ARBs. Auth uses a scoped
/// `flk_live_…` API token (create one in the dashboard, or `fl login --token ...`).
///
///   dart run flutter_localisation:fl add greeting --value "Hello" --translate
///   dart run flutter_localisation:fl edit greeting --locale fr --value "Bonjour"
///   dart run flutter_localisation:fl delete greeting
///   dart run flutter_localisation:fl translate greeting --missing
///   dart run flutter_localisation:fl status
///   dart run flutter_localisation:fl pull
library;

import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';

import 'package:flutter_localisation_cli/src/config.dart';
import 'package:flutter_localisation_cli/src/exceptions.dart';
import 'package:flutter_localisation_cli/src/guard.dart';
import 'package:flutter_localisation_cli/src/management_client.dart';
import 'package:flutter_localisation_cli/src/operations.dart';
import 'package:flutter_localisation_cli/src/project_resolver.dart';

Future<void> main(final List<String> args) async {
  final CommandRunner<int> runner = CommandRunner<int>(
    'fl',
    'FlutterLocalisation management CLI — manage translation keys from the terminal.',
  )
    ..argParser.addOption('config', help: 'Path to flutterlocalisation.json.')
    ..argParser.addOption('token', help: 'flk_live_ API token (overrides env/file).')
    ..argParser.addOption('project',
        help: 'Project name or id (overrides config; use `fl projects` to list).',)
    ..argParser.addOption('flavor', help: 'Flavor name (if the project has several).')
    ..argParser.addFlag('dry-run',
        negatable: false, help: 'Show what would happen without changing anything.',)
    ..argParser.addFlag('json',
        negatable: false, help: 'Emit machine-readable JSON.',);

  runner.addCommand(LoginCommand());
  runner.addCommand(ProjectsCommand());
  runner.addCommand(AddCommand());
  runner.addCommand(ImportCommand());
  runner.addCommand(EditCommand());
  runner.addCommand(DeleteCommand());
  runner.addCommand(TranslateCommand());
  runner.addCommand(LanguagesCommand());
  runner.addCommand(StatusCommand());
  runner.addCommand(RetranslateCommand());
  runner.addCommand(RepoCommand());
  runner.addCommand(CloneCommand());
  runner.addCommand(PullCommand());
  runner.addCommand(GuardCommand());

  try {
    final int? code = await runner.run(args);
    exit(code ?? 0);
  } on UsageException catch (e) {
    stderr.writeln(e);
    exit(64);
  } on ManagementException catch (e) {
    stderr.writeln('Error: ${e.message}');
    final String msg = e.message.toLowerCase();
    if (msg.contains('re-auth') || msg.contains('token expired')) {
      stderr.writeln('Hint: the backend\'s GitHub connection is disconnected. The change '
          'was saved, but ARB files can\'t sync until you reconnect GitHub in the dashboard '
          '(project → Repo → reconnect).');
    } else if (e is ApiException && e.isForbidden) {
      stderr.writeln('Hint: your token may lack the required scope, or the plan '
          'limit was reached.');
    } else if (e is ApiException && e.isAuth) {
      stderr.writeln('Hint: run `fl login --token flk_live_...` or set \$FL_API_TOKEN.');
    }
    exit(1);
  }
}

/// Shared helpers for commands that talk to the API.
mixin _ApiCommand on Command<int> {
  bool get jsonOut => (globalResults?['json'] as bool?) ?? false;
  bool get dryRun => (globalResults?['dry-run'] as bool?) ?? false;

  ProjectConfig loadProject() =>
      ProjectConfig.load(path: globalResults?['config'] as String?);

  ManagementClient buildClient(final ProjectConfig cfg) {
    final Credentials creds = Credentials.resolve(
      explicit: globalResults?['token'] as String?,
      baseUrl: cfg.baseUrl,
    );
    return ManagementClient(baseUrl: cfg.baseUrl, token: creds.token);
  }

  /// Resolve the target project (by id/name, or the sole project) and build [Operations].
  Future<({ManagementClient client, Operations ops, String projectName})> build(
    final ProjectConfig cfg,
  ) async {
    final ManagementClient client = buildClient(cfg);
    final String? projectArg = globalResults?['project'] as String?;
    final String? flavor = (globalResults?['flavor'] as String?) ?? cfg.flavor;

    // Fast path: an explicit numeric id in config and no name override — no lookup needed.
    if (projectArg == null && cfg.projectId != null) {
      return (
        client: client,
        ops: Operations(client, cfg.projectId!, flavor: flavor),
        projectName: cfg.project ?? 'project ${cfg.projectId}',
      );
    }

    final ProjectResolver resolver = ProjectResolver(
      client,
      defaultProject: cfg.projectSelector,
      defaultFlavor: flavor,
    );
    final ResolvedTarget target =
        await resolver.resolve(project: projectArg, flavor: flavor);
    return (
      client: client,
      ops: Operations(client, target.projectId, flavor: target.flavor),
      projectName: target.projectName,
    );
  }

  int emit(final OpResult r) {
    if (jsonOut) {
      stdout.writeln(const JsonEncoder.withIndent('  ').convert(r.toJson()));
    } else {
      stdout.writeln(r.ok ? '✓ ${r.message}' : '✗ ${r.message}');
    }
    return r.ok ? 0 : 1;
  }
}

class LoginCommand extends Command<int> {
  LoginCommand() {
    argParser.addOption('token', mandatory: true, help: 'flk_live_ API token.');
    argParser.addOption('base-url',
        defaultsTo: kDefaultBaseUrl, help: 'API base URL to associate the token with.',);
  }

  @override
  String get name => 'login';
  @override
  String get description => 'Store a scoped API token (~/.config, chmod 600).';

  @override
  Future<int> run() async {
    final String token = argResults!['token'] as String;
    final String baseUrl = argResults!['base-url'] as String;
    if (!token.startsWith('flk_')) {
      stderr.writeln('Warning: token does not look like a flk_ key.');
    }
    Credentials.save(token, baseUrl: baseUrl);
    stdout.writeln('✓ Token saved for $baseUrl.');
    return 0;
  }
}

class ProjectsCommand extends Command<int> with _ApiCommand {
  @override
  String get name => 'projects';
  @override
  String get description => 'List the projects (and flavors) you can access.';

  @override
  Future<int> run() async {
    final ManagementClient client = buildClient(loadProject());
    try {
      final List<ProjectSummary> projects = await client.listProjects();
      if (jsonOut) {
        stdout.writeln(const JsonEncoder.withIndent('  ').convert(
          projects
              .map((final ProjectSummary p) => <String, dynamic>{
                    'id': p.id,
                    'name': p.name,
                    'workspace': p.workspace,
                    'flavors': p.flavors
                        .map((final FlavorSummary f) => <String, dynamic>{
                              'name': f.name,
                              'base': f.baseLanguage,
                              'locales': f.languages,
                            },)
                        .toList(),
                  },)
              .toList(),
        ),);
        return 0;
      }
      if (projects.isEmpty) {
        stdout.writeln('No projects accessible with this token.');
        return 0;
      }
      for (final ProjectSummary p in projects) {
        final String warn = p.gitNeedsReauth
            ? '  ⚠️  git sync disconnected — reconnect GitHub in the dashboard'
            : '';
        stdout.writeln('${p.name}  (id ${p.id})$warn');
        for (final FlavorSummary f in p.flavors) {
          final String base =
              f.baseLanguage != null ? '  [base ${f.baseLanguage}]' : '';
          stdout.writeln('  · ${f.name}: ${f.languages.join(", ")}$base');
        }
      }
      return 0;
    } finally {
      client.close();
    }
  }
}

class AddCommand extends Command<int> with _ApiCommand {
  AddCommand() {
    argParser.addOption('value', mandatory: true, help: 'Base-language value.');
    argParser.addFlag('translate',
        abbr: 't', negatable: false, help: 'AI-translate all other locales.',);
    argParser.addOption('description',
        help: 'Key description (ARB @key.description).',);
    argParser.addMultiOption('placeholder',
        help: 'Placeholder as name:type[:format] (repeatable), '
            'e.g. --placeholder count:int:decimalPattern.',);
  }

  @override
  String get name => 'add';
  @override
  String get description =>
      'Add ONE translation key with its base value. For 2+ keys use `fl import` '
      '(one request for every key and locale) — never loop this.';
  @override
  String get invocation =>
      'fl add <key> --value "<text>" [--translate] [--description "..."] '
      '[--placeholder name:type[:format]]';

  @override
  Future<int> run() async {
    final String key = _requireKey(this);
    final Map<String, dynamic>? placeholders =
        parsePlaceholderSpecs(argResults!['placeholder'] as List<String>);
    final ({ManagementClient client, Operations ops, String projectName}) built = await build(loadProject());
    try {
      final OpResult r = await built.ops.add(
        key,
        argResults!['value'] as String,
        translate: argResults!['translate'] as bool,
        placeholders: placeholders,
        isPlaceholdersEnabled: placeholders == null ? null : true,
        description: argResults!['description'] as String?,
        dryRun: dryRun,
      );
      return emit(r);
    } finally {
      built.client.close();
    }
  }
}

class ImportCommand extends Command<int> with _ApiCommand {
  ImportCommand() {
    argParser.addOption('language',
        abbr: 'l',
        help: 'Locale the ARB represents (default: the project base language).',);
    argParser.addFlag('overwrite',
        negatable: false,
        help: 'Overwrite values of keys that already exist.',);
    argParser.addFlag('translate',
        abbr: 't',
        negatable: false,
        help: 'AI-translate the other locales after import (one batch pass).',);
  }

  @override
  String get name => 'import';
  @override
  String get description =>
      'Bulk-create keys from an ARB file in ONE request (vs many `add`s).';
  @override
  String get invocation =>
      'fl import <file.arb> [--language <code>] [--overwrite] [--translate]';

  @override
  Future<int> run() async {
    final List<String> rest = argResults!.rest;
    if (rest.isEmpty) {
      throw UsageException('Missing <file.arb> path argument.', usage);
    }
    final File file = File(rest.first);
    if (!file.existsSync()) {
      stderr.writeln('Error: file not found: ${rest.first}');
      return 1;
    }
    final String content = await file.readAsString();
    final ({ManagementClient client, Operations ops, String projectName}) built =
        await build(loadProject());
    try {
      final OpResult r = await built.ops.importArb(
        content,
        languageCode: argResults!['language'] as String?,
        overwrite: argResults!['overwrite'] as bool,
        translate: argResults!['translate'] as bool,
        dryRun: dryRun,
      );
      return emit(r);
    } finally {
      built.client.close();
    }
  }
}

class EditCommand extends Command<int> with _ApiCommand {
  EditCommand() {
    argParser.addOption('locale', mandatory: true, help: 'Locale code, e.g. fr.');
    argParser.addOption('value', help: 'New value.');
    argParser.addFlag('checked', defaultsTo: null, help: 'Set is_checked true/false.',);
    argParser.addOption('description',
        help: 'Key description (ARB @key.description).',);
    argParser.addMultiOption('placeholder',
        help: 'Placeholder as name:type[:format] (repeatable), '
            'e.g. --placeholder count:int:decimalPattern.',);
  }

  @override
  String get name => 'edit';
  @override
  String get description => 'Edit a locale\'s value / flags of an existing key.';
  @override
  String get invocation => 'fl edit <key> --locale <code> [--value "..."]';

  @override
  Future<int> run() async {
    final String key = _requireKey(this);
    final Map<String, dynamic>? placeholders =
        parsePlaceholderSpecs(argResults!['placeholder'] as List<String>);
    final ({ManagementClient client, Operations ops, String projectName}) built = await build(loadProject());
    try {
      final OpResult r = await built.ops.edit(
        key,
        argResults!['locale'] as String,
        value: argResults!['value'] as String?,
        isChecked: argResults!['checked'] as bool?,
        isPlaceholdersEnabled: placeholders == null ? null : true,
        placeholders: placeholders,
        description: argResults!['description'] as String?,
        dryRun: dryRun,
      );
      return emit(r);
    } finally {
      built.client.close();
    }
  }
}

class DeleteCommand extends Command<int> with _ApiCommand {
  DeleteCommand() {
    argParser.addOption('locale',
        help: 'Delete only this locale (default: the whole key, all locales).',);
  }

  @override
  String get name => 'delete';
  @override
  String get description => 'Delete a key (all locales) or a single locale.';
  @override
  String get invocation => 'fl delete <key> [--locale <code>]';

  @override
  Future<int> run() async {
    final String key = _requireKey(this);
    final ({ManagementClient client, Operations ops, String projectName}) built = await build(loadProject());
    try {
      final OpResult r = await built.ops.delete(
        key,
        locale: argResults!['locale'] as String?,
        dryRun: dryRun,
      );
      return emit(r);
    } finally {
      built.client.close();
    }
  }
}

class TranslateCommand extends Command<int> with _ApiCommand {
  TranslateCommand() {
    argParser.addFlag('all',
        negatable: false, help: 'Translate every non-base locale (default: only missing).',);
    argParser.addMultiOption('locale', help: 'Specific locale(s) to translate.');
  }

  @override
  String get name => 'translate';
  @override
  String get description => 'AI-translate a key\'s locales (default: only missing).';
  @override
  String get invocation => 'fl translate <key> [--all | --locale fr --locale de]';

  @override
  Future<int> run() async {
    final String key = _requireKey(this);
    final ({ManagementClient client, Operations ops, String projectName}) built = await build(loadProject());
    try {
      final OpResult r = await built.ops.translate(
        key,
        all: argResults!['all'] as bool,
        locales: argResults!['locale'] as List<String>,
        dryRun: dryRun,
      );
      return emit(r);
    } finally {
      built.client.close();
    }
  }
}

/// Bulk counterpart to [TranslateCommand], which is per-key.
///
/// Exists because there was no way to repair a locale whose rows were filled
/// with the source text: `translate` defaults to only-missing and those rows
/// are not missing, and `--all` still covers one key per call.
class RetranslateCommand extends Command<int> with _ApiCommand {
  RetranslateCommand() {
    argParser.addMultiOption('locale',
        help: 'Locale(s) to repair. Omit for every non-base locale.');
    argParser.addOption('chunk-size',
        defaultsTo: '100', help: 'Translation ids per batch request.');
  }

  @override
  String get name => 'retranslate';
  @override
  String get description =>
      'AI-translate every empty value, and every unchecked value still identical '
      'to the source.';
  @override
  String get invocation => 'fl retranslate [--locale ar --locale ru]';

  @override
  Future<int> run() async {
    final ({ManagementClient client, Operations ops, String projectName}) built =
        await build(loadProject());
    try {
      final OpResult r = await built.ops.retranslate(
        locales: argResults!['locale'] as List<String>,
        dryRun: dryRun,
        chunkSize: int.parse(argResults!['chunk-size'] as String),
      );
      if (jsonOut) return emit(r);
      stdout.writeln(r.message);
      final Map<String, dynamic>? per =
          (r.data['per_locale'] as Map<String, dynamic>?);
      if (per != null) {
        for (final MapEntry<String, dynamic> e in per.entries) {
          stdout.writeln('  ${e.key}: ${e.value} value(s)');
        }
      }
      return r.ok ? 0 : 1;
    } finally {
      built.client.close();
    }
  }
}

class StatusCommand extends Command<int> with _ApiCommand {
  @override
  String get name => 'status';
  @override
  String get description => 'Show completion % per locale.';

  @override
  Future<int> run() async {
    final ({ManagementClient client, Operations ops, String projectName}) built = await build(loadProject());
    try {
      final OpResult r = await built.ops.status();
      if (jsonOut) return emit(r);
      stdout.writeln(r.message);
      for (final row in (r.data['locales'] as List)) {
        final Map<String, dynamic> m = row as Map<String, dynamic>;
        final String tag = (m['base'] as bool) ? ' (base)' : '';
        // Show the translated count, not the filled one: a row still holding
        // the source text is otherwise indistinguishable from a finished 100%.
        final int untranslated = (m['untranslated'] as int?) ?? 0;
        final String gap = untranslated > 0
            ? '  ⚠ $untranslated same as source — `fl retranslate`'
            : '';
        stdout.writeln(
            '  ${m['locale']}$tag: ${m['translated'] ?? m['filled']}/${m['total']} '
            '(${m['translated_percent'] ?? m['percent']}%)$gap',);
      }
      return 0;
    } finally {
      built.client.close();
    }
  }
}

/// Manage the locales on a flavor.
///
/// `add --auto-translate` is the bulk primitive for a new language: ONE request,
/// after which the backend AI-fills every existing key. Without it, callers
/// reach for a per-key loop — which is how a 115-key project once cost 230
/// requests and a rate-limit ban.
class LanguagesCommand extends Command<int> with _ApiCommand {
  LanguagesCommand() {
    // `list` has to be a real subcommand: CommandRunner requires one whenever a
    // command has any, so a bare `fl languages` never reaches run() below.
    addSubcommand(LanguagesListCommand());
    addSubcommand(LanguagesAddCommand());
    addSubcommand(LanguagesRemoveCommand());
  }

  @override
  String get name => 'languages';
  @override
  String get description =>
      'List the project locales, or add/remove one (`languages add <code> '
      '--auto-translate` back-fills every existing key in one request).';

}

class LanguagesListCommand extends Command<int> with _ApiCommand {
  @override
  String get name => 'list';
  @override
  String get description => 'List the locales and how many keys each has filled.';

  @override
  Future<int> run() async {
    final ({ManagementClient client, Operations ops, String projectName}) built =
        await build(loadProject());
    try {
      final OpResult r = await built.ops.listLanguages();
      if (jsonOut) return emit(r);
      stdout.writeln(r.message);
      for (final row in (r.data['locales'] as List)) {
        final Map<String, dynamic> m = row as Map<String, dynamic>;
        final String tag = (m['base'] as bool) ? ' (base)' : '';
        stdout.writeln('  ${m['locale']}$tag: ${m['filled']}/${m['keys']} filled');
      }
      return 0;
    } finally {
      built.client.close();
    }
  }
}

class LanguagesAddCommand extends Command<int> with _ApiCommand {
  LanguagesAddCommand() {
    argParser.addFlag('auto-translate',
        abbr: 't',
        negatable: false,
        help: 'AI-fill every existing key for the new locale, server-side, in '
            'this same request — and keep translating keys added later.',);
  }

  @override
  String get name => 'add';
  @override
  String get description =>
      'Add a locale. With --auto-translate the backend fills every existing key '
      'in one pass — never loop `fl add`/`fl translate` to populate a locale.';
  @override
  String get invocation => 'fl languages add <code> [--auto-translate]';

  @override
  Future<int> run() async {
    final List<String> rest = argResults!.rest;
    if (rest.isEmpty) {
      throw UsageException('Missing <code> argument, e.g. `fl languages add id`.', usage);
    }
    final ({ManagementClient client, Operations ops, String projectName}) built =
        await build(loadProject());
    try {
      return emit(await built.ops.addLanguage(
        rest.first,
        autoTranslate: argResults!['auto-translate'] as bool,
        dryRun: dryRun,
      ));
    } finally {
      built.client.close();
    }
  }
}

class LanguagesRemoveCommand extends Command<int> with _ApiCommand {
  @override
  String get name => 'remove';
  @override
  String get description => 'Remove a locale and every translation it holds.';
  @override
  String get invocation => 'fl languages remove <code>';

  @override
  Future<int> run() async {
    final List<String> rest = argResults!.rest;
    if (rest.isEmpty) {
      throw UsageException('Missing <code> argument.', usage);
    }
    final ({ManagementClient client, Operations ops, String projectName}) built =
        await build(loadProject());
    try {
      return emit(await built.ops.removeLanguage(rest.first, dryRun: dryRun));
    } finally {
      built.client.close();
    }
  }
}

/// Print the ARB git repo the backend pushes to, as configured in the dashboard.
///
/// The project *detail* endpoint carries it (`<provider>_repository_url`); the
/// list endpoint does not, so this always costs one extra GET.
class RepoCommand extends Command<int> with _ApiCommand {
  @override
  String get name => 'repo';
  @override
  String get description =>
      'Print the ARB git repo URL the backend pushes to (from the dashboard).';

  @override
  Future<int> run() async {
    final ProjectConfig cfg = loadProject();
    final ({ManagementClient client, Operations ops, String projectName}) built =
        await build(cfg);
    try {
      final ProjectData p = await built.client.getProject(built.ops.projectId);
      final GitRepository? repo = p.repository;
      if (jsonOut) {
        stdout.writeln(const JsonEncoder.withIndent('  ').convert(
          <String, dynamic>{
            'project': p.name,
            'repository': repo == null
                ? null
                : <String, dynamic>{
                    'provider': repo.provider,
                    'url': repo.url,
                    'needs_reauth': repo.needsReauth,
                  },
          },
        ),);
        return repo == null ? 1 : 0;
      }
      if (repo == null) {
        stderr.writeln(
            'No git provider linked for "${p.name}". Link one in the dashboard '
            '→ Project → Git, then re-run.',);
        return 1;
      }
      stdout.writeln('${repo.url}  (${repo.provider})');
      if (repo.needsReauth) {
        stderr.writeln(
            'Warning: the git token needs reconnecting in the dashboard — '
            'ARB pushes are currently failing.',);
      }
      return 0;
    } finally {
      built.client.close();
    }
  }
}

/// Clone the linked ARB repo into `arb_dir` — the first-run counterpart to
/// `pull`, which only works once the repo is already on disk.
class CloneCommand extends Command<int> with _ApiCommand {
  @override
  String get name => 'clone';
  @override
  String get description =>
      'Clone the ARB repo into arb_dir (first-time setup; then use `pull`).';
  @override
  String get invocation => 'fl clone [<dir>]';

  @override
  Future<int> run() async {
    final ProjectConfig cfg = loadProject();
    final List<String> rest = argResults!.rest;
    final String dir = rest.isNotEmpty ? rest.first : (cfg.arbDir ?? 'arbs');

    final ({ManagementClient client, Operations ops, String projectName}) built =
        await build(cfg);
    final ProjectData p;
    try {
      p = await built.client.getProject(built.ops.projectId);
    } finally {
      built.client.close();
    }

    final GitRepository? repo = p.repository;
    if (repo == null) {
      stderr.writeln(
          'No git provider linked for "${p.name}". Link one in the dashboard '
          '→ Project → Git, then re-run.',);
      return 1;
    }
    if (Directory(dir).existsSync() &&
        Directory(dir).listSync().isNotEmpty) {
      stderr.writeln(
          'Error: "$dir" already exists and is not empty. Use `fl pull` to '
          'update it, or pass a different <dir>.',);
      return 1;
    }
    if (dryRun) {
      stdout.writeln('DRY RUN: would clone ${repo.url} into "$dir".');
      return 0;
    }

    stdout.writeln('Cloning ${repo.url} into "$dir" …');
    final ProcessResult res = await Process.run(
      'git',
      <String>['clone', repo.url, dir],
    );
    stdout.write(res.stdout);
    if (res.exitCode != 0) {
      stderr.write(res.stderr);
      return res.exitCode;
    }
    stdout.writeln('✓ Cloned. Add "/$dir/" to .gitignore — the backend owns it.');
    return 0;
  }
}

class PullCommand extends Command<int> with _ApiCommand {
  @override
  String get name => 'pull';
  @override
  String get description => 'git pull the ARB repo (arb_dir in config).';

  @override
  Future<int> run() async {
    final ProjectConfig cfg = loadProject();
    final String dir = cfg.arbDir ?? '.';
    stdout.writeln('Pulling ARBs in $dir …');
    final ProcessResult res =
        await Process.run('git', <String>['pull', '--rebase'], workingDirectory: dir);
    stdout.write(res.stdout);
    if (res.exitCode != 0) {
      stderr.write(res.stderr);
      return res.exitCode;
    }
    stdout.writeln('✓ Pulled.');
    return 0;
  }
}

/// Install a Claude Code guard so AI agents cannot hand-edit the
/// FlutterLocalisation-managed files (the ARB repo + generated Dart). Purely
/// local — writes `.claude/settings.json` deny rules in the current project.
class GuardCommand extends Command<int> {
  bool get _jsonOut => (globalResults?['json'] as bool?) ?? false;
  bool get _dryRun => (globalResults?['dry-run'] as bool?) ?? false;

  @override
  String get name => 'guard';
  @override
  String get description =>
      'Protect ARBs + generated Dart from AI edits: writes .claude deny rules '
      'and AI-guidance docs (AGENTS.md / CLAUDE.md).';
  @override
  String get invocation => 'fl guard';

  @override
  Future<int> run() async {
    final ProjectConfig cfg =
        ProjectConfig.load(path: globalResults?['config'] as String?);
    final Directory root = Directory.current;
    final List<String> globs =
        deriveGuardGlobs(root, arbDirFromConfig: cfg.arbDir);
    final String projectLabel = cfg.project ??
        (cfg.projectId != null ? 'project ${cfg.projectId}' : 'this workspace');

    if (_dryRun) {
      final List<String> rules = <String>[
        for (final String g in globs) ...<String>['Edit($g)', 'Write($g)'],
      ];
      if (_jsonOut) {
        stdout.writeln(const JsonEncoder.withIndent('  ').convert(
          <String, dynamic>{
            'dryRun': true,
            'protected': globs,
            'rules': rules,
            'docs': <String>['AGENTS.md', 'CLAUDE.md'],
          },
        ),);
      } else {
        stdout.writeln('DRY RUN: would deny AI edits to:');
        for (final String g in globs) {
          stdout.writeln('  · $g');
        }
        stdout.writeln('in ${root.path}/.claude/settings.json');
        stdout.writeln('and write AI-guidance docs: AGENTS.md, CLAUDE.md');
      }
      return 0;
    }

    final GuardResult r = installGuard(root, globs: globs);
    final AgentDocsResult docs =
        installAgentDocs(root, projectLabel: projectLabel, globs: globs);
    if (_jsonOut) {
      stdout.writeln(const JsonEncoder.withIndent('  ').convert(
        <String, dynamic>{...r.toJson(), ...docs.toJson()},
      ),);
      return 0;
    }
    stdout.writeln(r.created
        ? '✓ Created ${r.settingsPath}'
        : '✓ Updated ${r.settingsPath}');
    if (r.added.isEmpty) {
      stdout.writeln('  (already protected — no new rules)');
    } else {
      stdout.writeln('  Protected from AI Edit/Write:');
      for (final String g in r.protected) {
        stdout.writeln('    · $g');
      }
    }
    for (final String path in docs.files) {
      stdout.writeln(docs.created.contains(path)
          ? '✓ Wrote AI guidance → $path'
          : '✓ Updated AI guidance → $path');
    }
    return 0;
  }
}

String _requireKey(final Command<int> cmd) {
  final List<String> rest = cmd.argResults!.rest;
  if (rest.isEmpty) {
    throw UsageException('Missing <key> argument.', cmd.usage);
  }
  return rest.first;
}
