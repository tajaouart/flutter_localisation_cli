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

import 'package:flutter_localisation_cli/src/arb_sync.dart';
import 'package:flutter_localisation_cli/src/config.dart';
import 'package:flutter_localisation_cli/src/exceptions.dart';
import 'package:flutter_localisation_cli/src/guard.dart';
import 'package:flutter_localisation_cli/src/locales.dart';
import 'package:flutter_localisation_cli/src/management_client.dart';
import 'package:flutter_localisation_cli/src/native_sync.dart';
import 'package:flutter_localisation_cli/src/operations.dart';
import 'package:flutter_localisation_cli/src/project_resolver.dart';

Future<void> main(final List<String> args) async {
  final CommandRunner<int> runner = CommandRunner<int>(
    'fl',
    'FlutterLocalisation management CLI — manage translation keys from the terminal.',
  )
    ..argParser.addOption('config', help: 'Path to flutterlocalisation.json.')
    ..argParser
        .addOption('token', help: 'flk_live_ API token (overrides env/file).')
    ..argParser.addOption(
      'project',
      help: 'Project name or id (overrides config; use `fl projects` to list).',
    )
    ..argParser
        .addOption('flavor', help: 'Flavor name (if the project has several).')
    ..argParser.addFlag(
      'dry-run',
      negatable: false,
      help: 'Show what would happen without changing anything.',
    )
    ..argParser.addFlag(
      'json',
      negatable: false,
      help: 'Emit machine-readable JSON.',
    );

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
  runner.addCommand(SyncCommand());
  runner.addCommand(GuardCommand());
  runner.addCommand(NativeCommand());
  runner.addCommand(ExportCommand());

  try {
    final int? code = await runner.run(args);
    exit(code ?? 0);
  } on UsageException catch (e) {
    stderr.writeln(e);
    exit(64);
  } on ManagementException catch (e) {
    stderr.writeln('Error: ${e.message}');
    if (e is ApiException) _writeRowErrors(e);
    final String msg = e.message.toLowerCase();
    if (msg.contains('re-auth') || msg.contains('token expired')) {
      stderr.writeln(
          'Hint: the backend\'s GitHub connection is disconnected. The change '
          'was saved, but ARB files can\'t sync until you reconnect GitHub in the dashboard '
          '(project → Repo → reconnect).');
    } else if (e is ApiException && e.isForbidden) {
      stderr
          .writeln('Hint: your token may lack the required scope, or the plan '
              'limit was reached.');
    } else if (e is ApiException && e.isAuth) {
      stderr.writeln(
          'Hint: run `fl login --token flk_live_...` or set \$FL_API_TOKEN.');
    }
    exit(1);
  }
}

/// Canonicalise a locale typed on the command line.
///
/// `--locale pt_br` and `--locale PT-BR` mean `pt-BR`, which is the spelling
/// the project holds; without this they are three different strings and every
/// comparison against the project's locales misses. Junk is passed through
/// untouched so the API's own error names the field.
String? _locale(final String? code) =>
    code == null ? null : canonicalizeOrKeep(code);

List<String> _locales(final List<String> codes) =>
    codes.map(canonicalizeOrKeep).toList();

/// Print the per-row errors carried on a failed batch response.
///
/// When the whole batch is rejected, the top-level message is a summary —
/// "All translations failed." — and the useful part is in `results.failed`,
/// one entry per row with the backend's own reason. That detail was already
/// being parsed into [ApiException.body] and then dropped on the floor, so a
/// malformed plural row and a dead service printed the same sentence. One of
/// those is a five-second fix and the other is an outage; the reader could not
/// tell which they had.
void _writeRowErrors(final ApiException e) {
  final Object? results = e.body?['results'];
  if (results is! Map<String, dynamic>) return;
  final Object? failed = results['failed'];
  if (failed is! List || failed.isEmpty) return;
  stderr.writeln('The backend rejected these rows:');
  for (final Object? row in failed.take(20)) {
    if (row is! Map<String, dynamic>) continue;
    stderr.writeln('  id ${row['id']}: ${row['error'] ?? 'no reason given'}');
  }
  if (failed.length > 20) {
    stderr.writeln('  … and ${failed.length - 20} more.');
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
    argParser.addOption(
      'base-url',
      defaultsTo: kDefaultBaseUrl,
      help: 'API base URL to associate the token with.',
    );
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
        stdout.writeln(
          const JsonEncoder.withIndent('  ').convert(
            projects
                .map(
                  (final ProjectSummary p) => <String, dynamic>{
                    'id': p.id,
                    'name': p.name,
                    'workspace': p.workspace,
                    'flavors': p.flavors
                        .map(
                          (final FlavorSummary f) => <String, dynamic>{
                            'name': f.name,
                            'base': f.baseLanguage,
                            'locales': f.languages,
                          },
                        )
                        .toList(),
                  },
                )
                .toList(),
          ),
        );
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
    argParser.addFlag(
      'translate',
      abbr: 't',
      negatable: false,
      help: 'AI-translate all other locales.',
    );
    argParser.addOption(
      'description',
      help: 'Key description (ARB @key.description).',
    );
    argParser.addMultiOption(
      'placeholder',
      help: 'Placeholder as name:type[:format] (repeatable), '
          'e.g. --placeholder count:int:decimalPattern.',
    );
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
    final ({
      ManagementClient client,
      Operations ops,
      String projectName
    }) built = await build(loadProject());
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
    argParser.addOption(
      'language',
      abbr: 'l',
      help: 'Locale the ARB represents (default: the project base language).',
    );
    argParser.addFlag(
      'overwrite',
      negatable: false,
      help: 'Overwrite values of keys that already exist.',
    );
    argParser.addFlag(
      'translate',
      abbr: 't',
      negatable: false,
      help: 'AI-translate the other locales after import (one batch pass).',
    );
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
    final ({
      ManagementClient client,
      Operations ops,
      String projectName
    }) built = await build(loadProject());
    try {
      final OpResult r = await built.ops.importArb(
        content,
        languageCode: _locale(argResults!['language'] as String?),
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
    argParser.addOption('locale',
        mandatory: true, help: 'Locale code, e.g. fr.');
    argParser.addOption('value', help: 'New value.');
    argParser.addFlag(
      'checked',
      defaultsTo: null,
      help: 'Set is_checked true/false.',
    );
    argParser.addOption(
      'description',
      help: 'Key description (ARB @key.description).',
    );
    argParser.addMultiOption(
      'placeholder',
      help: 'Placeholder as name:type[:format] (repeatable), '
          'e.g. --placeholder count:int:decimalPattern.',
    );
    // A plural row cannot be repaired through --value: the backend stores the
    // cases separately and assembles the ICU itself, so it rejects a value
    // carrying `{count}` with "unexpected ['count']". Without these flags the
    // only way to fix a bad plural translation was the web dashboard.
    argParser.addFlag('plural',
        defaultsTo: null, help: 'Set is_plural_enabled true/false.');
    argParser.addOption('singular-case',
        help: 'Plural "one" case. Give the bare text — the placeholder is '
            'added by --plural-param, so pass "image", not "{count} image".');
    argParser.addOption('plural-case',
        help: 'Plural "other" case, e.g. "images".');
    argParser.addOption('zero-case', help: 'Plural "zero" case.');
    // French, Spanish, Polish, Czech and others require CLDR's "many"; the
    // Slavic locales require "few"; Arabic requires "two". A row missing a
    // category its locale requires cannot be saved AT ALL — the backend
    // re-validates the whole row, so even setting is_checked on it fails.
    argParser.addOption('two-case', help: 'Plural "two" case (e.g. Arabic).');
    argParser.addOption('few-case', help: 'Plural "few" case (e.g. Polish).');
    argParser.addOption('many-case',
        help: 'Plural "many" case (required by fr, es, it, pt, pl, cs …).');
    argParser.addOption('plural-param',
        help: 'Name of the count placeholder, e.g. count.');
  }

  @override
  String get name => 'edit';
  @override
  String get description =>
      'Edit a locale\'s value / flags of an existing key.';
  @override
  String get invocation =>
      'fl edit <key> --locale <code> [--value "..."] [--singular-case "..." '
      '--plural-case "..."]';

  @override
  Future<int> run() async {
    final String key = _requireKey(this);
    final Map<String, dynamic>? placeholders =
        parsePlaceholderSpecs(argResults!['placeholder'] as List<String>);
    final ({
      ManagementClient client,
      Operations ops,
      String projectName
    }) built = await build(loadProject());
    try {
      final OpResult r = await built.ops.edit(
        key,
        _locale(argResults!['locale'] as String)!,
        value: argResults!['value'] as String?,
        isChecked: argResults!['checked'] as bool?,
        isPlaceholdersEnabled: placeholders == null ? null : true,
        placeholders: placeholders,
        description: argResults!['description'] as String?,
        isPluralEnabled: argResults!['plural'] as bool?,
        singularCase: argResults!['singular-case'] as String?,
        pluralCase: argResults!['plural-case'] as String?,
        zeroCase: argResults!['zero-case'] as String?,
        twoCase: argResults!['two-case'] as String?,
        fewCase: argResults!['few-case'] as String?,
        manyCase: argResults!['many-case'] as String?,
        pluralParam: argResults!['plural-param'] as String?,
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
    argParser.addOption(
      'locale',
      help: 'Delete only this locale (default: the whole key, all locales).',
    );
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
    final ({
      ManagementClient client,
      Operations ops,
      String projectName
    }) built = await build(loadProject());
    try {
      final OpResult r = await built.ops.delete(
        key,
        locale: _locale(argResults!['locale'] as String?),
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
    argParser.addFlag(
      'all',
      negatable: false,
      help: 'Translate every non-base locale (default: only missing).',
    );
    argParser.addMultiOption('locale',
        help: 'Specific locale(s) to translate.');
  }

  @override
  String get name => 'translate';
  @override
  String get description =>
      'AI-translate a key\'s locales (default: only missing).';
  @override
  String get invocation =>
      'fl translate <key> [--all | --locale fr --locale de]';

  @override
  Future<int> run() async {
    final String key = _requireKey(this);
    final ({
      ManagementClient client,
      Operations ops,
      String projectName
    }) built = await build(loadProject());
    try {
      final OpResult r = await built.ops.translate(
        key,
        all: argResults!['all'] as bool,
        locales: _locales(argResults!['locale'] as List<String>),
        dryRun: dryRun,
      );
      if (jsonOut) return emit(r);
      final int code = emit(r);
      _reportUnchanged(r);
      _reportFailures(r);
      return code;
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
        help: 'Locale(s) to repair — repeatable. OMIT to repair every locale '
            'in one pass, which is almost always what you want; never loop '
            'this command one locale at a time.');
    argParser.addFlag('accept-unchanged',
        negatable: false,
        help: 'Mark every value that came back identical to the source as '
            'checked, so it stops being re-translated on every run. Use after '
            'reviewing the list this command prints.');
  }

  @override
  String get name => 'retranslate';
  @override
  String get description =>
      'AI-translate every empty value, and every unchecked value still identical '
      'to the source.';
  @override
  String get invocation =>
      'fl retranslate [--locale ar --locale ru] [--accept-unchanged]';

  @override
  Future<int> run() async {
    final ({
      ManagementClient client,
      Operations ops,
      String projectName
    }) built = await build(loadProject());
    try {
      final OpResult r = await built.ops.retranslate(
        locales: _locales(argResults!['locale'] as List<String>),
        dryRun: dryRun,
        acceptUnchanged: argResults!['accept-unchanged'] as bool,
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
      _reportUnchanged(r);
      _reportFailures(r);
      _reportAcceptFailures(r);
      return r.ok ? 0 : 1;
    } finally {
      built.client.close();
    }
  }
}

/// Print the rows that refused the checked flag, with the backend's reason.
///
/// A row missing a plural case its locale requires cannot be saved at all —
/// the backend re-validates the whole row, so even an update touching nothing
/// but `is_checked` is rejected. The message names the missing case, which is
/// the difference between a two-minute `fl edit --many-case` and a warning
/// nobody can explain.
void _reportAcceptFailures(final OpResult r) {
  final List<dynamic> rows =
      (r.data['accept_failed'] as List<dynamic>?) ?? const <dynamic>[];
  if (rows.isEmpty) return;
  stderr.writeln('\n${rows.length} value(s) could not be marked checked:');
  for (final dynamic row in rows.take(20)) {
    final Map<String, dynamic> m = row as Map<String, dynamic>;
    stderr.writeln('  ${m['error']}');
  }
  if (rows.length > 20) {
    stderr.writeln('  … and ${rows.length - 20} more (use --json for all).');
  }
}

/// Print the rows that came back identical to their source, and name the
/// remedy.
///
/// These are not failures — most are loanwords that are genuinely the same
/// word in the target language — so they are reported apart from real errors
/// and never change the exit code. What they need is a decision, and the
/// listing is what makes that decision possible: nobody can confirm "Nature is
/// correct in French" from a bare count.
void _reportUnchanged(final OpResult r) {
  final List<dynamic> rows =
      (r.data['unchanged'] as List<dynamic>?) ?? const <dynamic>[];
  if (rows.isEmpty) return;
  final int accepted = (r.data['accepted'] as int?) ?? 0;
  stdout
      .writeln('\n${rows.length} value(s) came back identical to the source.');
  stdout.writeln(
      'That is usually correct — loanwords and product names ("OK", "Premium", '
      '"Normal") are the same word in many languages.');
  const int limit = 20;
  for (final dynamic row in rows.take(limit)) {
    final Map<String, dynamic> m = row as Map<String, dynamic>;
    stdout.writeln('  ${m['locale']}  ${m['key']}');
  }
  if (rows.length > limit) {
    stdout.writeln('  … and ${rows.length - limit} more (use --json for all).');
  }
  if (accepted > 0) {
    stdout.writeln(
        'Marked $accepted as checked; they will not be re-translated again.');
  } else {
    stdout.writeln(
        'Review them, then re-run with --accept-unchanged to mark them checked '
        'and stop re-translating them on every run.');
  }
}

/// Print the real per-row backend errors.
///
/// The reason string is the backend's own — e.g. "When plural is enabled,
/// 'singular_case' must be provided for locale 'hi'" — and it is the whole
/// value of the bucket. A count alone sends people looking for a translator
/// when what is wrong is a malformed plural row.
void _reportFailures(final OpResult r) {
  final List<dynamic> rows =
      (r.data['failed'] as List<dynamic>?) ?? const <dynamic>[];
  if (rows.isEmpty) return;
  stderr.writeln('\n${rows.length} value(s) failed:');
  for (final dynamic row in rows.take(20)) {
    final Map<String, dynamic> m = row as Map<String, dynamic>;
    stderr.writeln('  id ${m['id']}: ${m['error']}');
  }
  if (rows.length > 20) {
    stderr.writeln('  … and ${rows.length - 20} more (use --json for all).');
  }
}

class StatusCommand extends Command<int> with _ApiCommand {
  @override
  String get name => 'status';
  @override
  String get description => 'Show completion % per locale.';

  @override
  Future<int> run() async {
    final ({
      ManagementClient client,
      Operations ops,
      String projectName
    }) built = await build(loadProject());
    try {
      final OpResult r = await built.ops.status();
      if (jsonOut) return emit(r);
      stdout.writeln(r.message);
      var totalUntranslated = 0;
      for (final row in (r.data['locales'] as List)) {
        final Map<String, dynamic> m = row as Map<String, dynamic>;
        final String tag = (m['base'] as bool) ? ' (base)' : '';
        // Show the translated count, not the filled one: a row still holding
        // the source text is otherwise indistinguishable from a finished 100%.
        final int untranslated = (m['untranslated'] as int?) ?? 0;
        totalUntranslated += untranslated;
        final String gap = untranslated > 0
            ? '  ⚠ $untranslated same as source — `fl retranslate`'
            : '';
        stdout.writeln(
          '  ${m['locale']}$tag: ${m['translated'] ?? m['filled']}/${m['total']} '
          '(${m['translated_percent'] ?? m['percent']}%)$gap',
        );
      }
      // Without this, a project whose remaining gap is entirely loanwords shows
      // a warning on most of its locales that `fl retranslate` can never clear
      // — the translator keeps returning the same correct answer. A warning
      // nobody can act on is one everybody learns to ignore, so name the second
      // half of the remedy here.
      if (totalUntranslated > 0) {
        stdout.writeln(
            '\nSome of those are probably correct: a loanword is the same word '
            'in both languages.');
        stdout.writeln('Run `fl retranslate` to fill the real gaps, then '
            '`fl retranslate --accept-unchanged` to mark the deliberate matches '
            'checked and clear these warnings for good.');
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
  String get description =>
      'List the locales and how many keys each has filled.';

  @override
  Future<int> run() async {
    final ({
      ManagementClient client,
      Operations ops,
      String projectName
    }) built = await build(loadProject());
    try {
      final OpResult r = await built.ops.listLanguages();
      if (jsonOut) return emit(r);
      stdout.writeln(r.message);
      for (final row in (r.data['locales'] as List)) {
        final Map<String, dynamic> m = row as Map<String, dynamic>;
        final String tag = (m['base'] as bool) ? ' (base)' : '';
        stdout.writeln(
            '  ${m['locale']}$tag: ${m['filled']}/${m['keys']} filled');
      }
      return 0;
    } finally {
      built.client.close();
    }
  }
}

class LanguagesAddCommand extends Command<int> with _ApiCommand {
  LanguagesAddCommand() {
    argParser.addFlag(
      'auto-translate',
      abbr: 't',
      negatable: false,
      help: 'AI-fill every existing key for the new locale, server-side, in '
          'this same request — and keep translating keys added later.',
    );
  }

  @override
  String get name => 'add';
  @override
  String get description =>
      'Add one or MORE locales in a single call. With --auto-translate the '
      'backend fills every existing key in one pass — pass every locale you '
      'want at once; never loop this command.';
  @override
  String get invocation =>
      'fl languages add <code> [<code> ...] [--auto-translate]';

  @override
  Future<int> run() async {
    final List<String> rest = argResults!.rest;
    if (rest.isEmpty) {
      throw UsageException(
          'Missing <code> argument, e.g. `fl languages add id ja ko`.', usage);
    }
    final ({
      ManagementClient client,
      Operations ops,
      String projectName
    }) built = await build(loadProject());
    try {
      final OpResult r = await built.ops.addLanguages(
        _locales(rest),
        autoTranslate: argResults!['auto-translate'] as bool,
        dryRun: dryRun,
      );
      if (jsonOut) return emit(r);
      stdout.writeln(r.message);
      for (final dynamic row
          in (r.data['results'] as List<dynamic>?) ?? const <dynamic>[]) {
        final Map<String, dynamic> m = row as Map<String, dynamic>;
        stdout.writeln('  ${m['ok'] == true ? '✓' : '✗'} ${m['locale']}  '
            '${m['message'] ?? ''}');
      }
      return r.ok ? 0 : 1;
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
    final ({
      ManagementClient client,
      Operations ops,
      String projectName
    }) built = await build(loadProject());
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
    final ({
      ManagementClient client,
      Operations ops,
      String projectName
    }) built = await build(cfg);
    try {
      final ProjectData p = await built.client.getProject(built.ops.projectId);
      final GitRepository? repo = p.repository;
      if (jsonOut) {
        stdout.writeln(
          const JsonEncoder.withIndent('  ').convert(
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
          ),
        );
        return repo == null ? 1 : 0;
      }
      if (repo == null) {
        stderr.writeln(
          'No git provider linked for "${p.name}". Link one in the dashboard '
          '→ Project → Git, then re-run.',
        );
        return 1;
      }
      stdout.writeln('${repo.url}  (${repo.provider})');
      if (repo.needsReauth) {
        stderr.writeln(
          'Warning: the git token needs reconnecting in the dashboard — '
          'ARB pushes are currently failing.',
        );
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

    final ({
      ManagementClient client,
      Operations ops,
      String projectName
    }) built = await build(cfg);
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
        '→ Project → Git, then re-run.',
      );
      return 1;
    }
    if (Directory(dir).existsSync() && Directory(dir).listSync().isNotEmpty) {
      stderr.writeln(
        'Error: "$dir" already exists and is not empty. Use `fl pull` to '
        'update it, or pass a different <dir>.',
      );
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
    stdout
        .writeln('✓ Cloned. Add "/$dir/" to .gitignore — the backend owns it.');
    return 0;
  }
}

class PullCommand extends Command<int> with _ApiCommand {
  PullCommand() {
    argParser
      ..addFlag(
        'adopt',
        negatable: false,
        help: 'Import keys that exist only on disk before syncing, instead '
            'of refusing.',
      )
      ..addFlag(
        'discard-local',
        negatable: false,
        help: 'Drop keys that exist only on disk (they are recoverable from '
            'the ref the sync prints).',
      )
      ..addFlag(
        'no-git',
        negatable: false,
        help: 'Skip the git mirror and write the ARBs straight from the API.',
      );
  }

  @override
  String get name => 'pull';
  @override
  String get description =>
      'Sync arb_dir with the service (git mirror if there is one, API '
      'otherwise). Never needs a git command.';

  @override
  Future<int> run() async => _pullArbs(
        this,
        adopt: argResults!['adopt'] as bool,
        discardLocal: argResults!['discard-local'] as bool,
        noGit: argResults!['no-git'] as bool,
      );
}

/// Bring `arb_dir` to exactly what the service holds.
///
/// Shared by `fl pull` and `fl sync` so there is one definition of "in sync"
/// and one place where the local-only-key guard lives.
Future<int> _pullArbs(
  final _ApiCommand cmd, {
  final bool adopt = false,
  final bool discardLocal = false,
  final bool noGit = false,
}) async {
  final ProjectConfig cfg = cmd.loadProject();
  final String dir = cfg.arbDir ?? '.';

  final ({ManagementClient client, Operations ops, String projectName}) built =
      await cmd.build(cfg);
  try {
    final ProjectData project =
        await built.client.getProject(built.ops.projectId);
    final LanguageData? base = project.baseLanguage(built.ops.flavor);
    if (base == null) {
      stderr.writeln('Project "${project.name}" has no base language.');
      return 1;
    }
    final String templateName = 'app_${base.code.replaceAll('-', '_')}.arb';
    final File template = File('$dir/$templateName');
    final Set<String> serviceKeys = <String>{
      for (final TranslationEntry t in base.translations)
        if (t.key.isNotEmpty) t.key,
    };

    // The one thing a sync must not do quietly: both refresh paths rewrite
    // the template from the service, so a key staged on disk and never
    // imported would disappear. Stop, name them, and offer both answers.
    final List<String> orphans = localOnlyKeys(template, serviceKeys);
    if (orphans.isNotEmpty && !adopt && !discardLocal) {
      stderr.writeln(
          '$templateName has ${orphans.length} key(s) the service does not '
          'have yet:');
      for (final String k in orphans.take(20)) {
        stderr.writeln('  $k');
      }
      if (orphans.length > 20) {
        stderr.writeln('  … and ${orphans.length - 20} more.');
      }
      stderr.writeln('Syncing would overwrite the file and lose them. Either:\n'
          '  fl pull --adopt           import them first, then sync\n'
          '  fl pull --discard-local   drop them and take the service copy');
      return 1;
    }
    if (orphans.isNotEmpty && adopt) {
      if (cmd.dryRun) {
        stdout.writeln(
            'DRY RUN: would import ${orphans.length} local-only key(s) '
            'before syncing.');
      } else {
        stdout.writeln('Importing ${orphans.length} local-only key(s) from '
            '$templateName …');
        final OpResult imported = await built.ops.importArb(
          template.readAsStringSync(),
          languageCode: base.code,
          translate: true,
        );
        if (!imported.ok) {
          stderr.writeln(imported.message);
          return 1;
        }
        stdout.writeln('  ${imported.message}');
      }
    }

    if (cmd.dryRun) {
      stdout.writeln('DRY RUN: would sync "$dir" to the service.');
      return 0;
    }

    // Git when it can deliver, API when it cannot. Same outcome either way,
    // which is why the fallback is silent enough to be routine and loud
    // enough to explain itself.
    if (!noGit) {
      final GitSyncOutcome outcome = await GitMirror(dir).hardSync();
      if (outcome.ok) {
        stdout.writeln('✓ Synced "$dir" to ${outcome.upstream}.');
        if (outcome.discardedAnything) {
          final List<String> what = <String>[
            if (outcome.discardedWorkingChanges) 'local edits',
            if (outcome.discardedLocalCommits > 0)
              '${outcome.discardedLocalCommits} local commit(s)',
          ];
          stdout.writeln(
              '  Discarded ${what.join(' and ')} — the backend owns this '
              'directory.');
          if (outcome.recoveryRef != null) {
            stdout.writeln('  Recover with: git -C $dir show '
                '${outcome.recoveryRef}');
          }
        }
        if (cmd.jsonOut) {
          stdout.writeln(
            const JsonEncoder.withIndent('  ').convert(
              <String, dynamic>{
                'ok': true,
                'method': ArbSyncMethod.git.name,
                'dir': dir,
                'upstream': outcome.upstream,
                'adopted': adopt ? orphans : <String>[],
              },
            ),
          );
        }
        return 0;
      }
      stdout.writeln('Git mirror unavailable (${_skipReason(outcome)}) — '
          'writing the ARBs from the API instead.');
    }

    final OpResult r = await built.ops.exportArbs(dir);
    if (cmd.jsonOut) {
      return cmd.emit(
        OpResult(
          r.ok,
          r.message,
          <String, dynamic>{
            ...r.data,
            'method': ArbSyncMethod.api.name,
            'adopted': adopt ? orphans : <String>[],
          },
        ),
      );
    }
    stdout.writeln(r.ok ? '✓ ${r.message}' : r.message);
    return r.ok ? 0 : 1;
  } finally {
    built.client.close();
  }
}

String _skipReason(final GitSyncOutcome o) => switch (o.skip) {
      GitSkipReason.gitMissing => 'no git on PATH',
      GitSkipReason.notARepo => 'not a git clone',
      GitSkipReason.noRemote => 'no remote',
      GitSkipReason.unreachable =>
        o.detail.isEmpty ? 'remote unreachable' : o.detail,
      null => 'unknown',
    };

/// The whole round trip in one command: push copy up, bring ARBs down,
/// regenerate the Dart.
///
/// It exists because the three steps were documented as three commands in
/// every consuming repo, which meant every repo also documented its own way
/// of getting them wrong. One command, one order, no git.
class SyncCommand extends Command<int> with _ApiCommand {
  SyncCommand() {
    argParser
      ..addFlag(
        'overwrite',
        negatable: false,
        help: 'Let the imported file change values of keys that exist.',
      )
      ..addFlag(
        'translate',
        defaultsTo: true,
        help: 'AI-translate the other locales after the import.',
      )
      ..addFlag(
        'codegen',
        defaultsTo: true,
        help: 'Regenerate the Dart with the flutter_localisation package.',
      );
  }

  @override
  String get name => 'sync';
  @override
  String get description =>
      'Import an ARB (optional), sync arb_dir, then regenerate the Dart — the '
      'whole flow in one command.';
  @override
  String get invocation => 'fl sync [<file.arb>]';

  @override
  Future<int> run() async {
    final ProjectConfig cfg = loadProject();
    final List<String> rest = argResults!.rest;
    final bool translate = argResults!['translate'] as bool;
    final bool overwrite = argResults!['overwrite'] as bool;
    final bool codegen = argResults!['codegen'] as bool;

    if (rest.isNotEmpty) {
      final File file = File(rest.first);
      if (!file.existsSync()) {
        stderr.writeln('Error: "${rest.first}" not found.');
        return 1;
      }
      final ({
        ManagementClient client,
        Operations ops,
        String projectName
      }) built = await build(cfg);
      try {
        final OpResult r = await built.ops.importArb(
          file.readAsStringSync(),
          overwrite: overwrite,
          translate: translate,
          dryRun: dryRun,
        );
        stdout.writeln(r.message);
        if (!r.ok) return 1;
      } finally {
        built.client.close();
      }
    }

    final int pulled = await _pullArbs(this, adopt: rest.isNotEmpty);
    if (pulled != 0) return pulled;
    if (!codegen || dryRun) return 0;

    final String dir = cfg.arbDir ?? 'arbs';
    // `arb_dir` points at the flavor folder (arbs/Default); the generator
    // takes the root and the flavor as two arguments.
    final List<String> parts = dir.split('/')
      ..removeWhere((final String p) => p.isEmpty);
    final String root =
        parts.length > 1 ? parts.sublist(0, parts.length - 1).join('/') : dir;
    final String flavorDir = parts.length > 1 ? parts.last : 'Default';
    stdout.writeln('Regenerating Dart from $root/$flavorDir …');
    final ProcessResult gen = await Process.run(
      'dart',
      <String>['run', 'flutter_localisation', root, flavorDir],
    );
    stdout.write(gen.stdout);
    if (gen.exitCode != 0) {
      stderr.write(gen.stderr);
      stderr.writeln(
          'Codegen failed. Is flutter_localisation a dependency of this app? '
          'Re-run with --no-codegen to skip it.');
      return gen.exitCode;
    }
    stdout.writeln('✓ In sync: service → ARBs → Dart.');
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
        stdout.writeln(
          const JsonEncoder.withIndent('  ').convert(
            <String, dynamic>{
              'dryRun': true,
              'protected': globs,
              'rules': rules,
              'docs': <String>['AGENTS.md', 'CLAUDE.md'],
            },
          ),
        );
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
      stdout.writeln(
        const JsonEncoder.withIndent('  ').convert(
          <String, dynamic>{...r.toJson(), ...docs.toJson()},
        ),
      );
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

/// `fl native` — the half of localisation that is not the ARBs.
///
/// Offline and tokenless on purpose: it reads the locales the project already
/// ships and writes what iOS and Android need to know about them. Somebody
/// running this in CI to check for drift should not need credentials.
class NativeCommand extends Command<int> {
  NativeCommand() {
    argParser
      ..addFlag(
        'check',
        negatable: false,
        help: 'Fail if anything is stale, without writing. For CI.',
      )
      ..addFlag(
        'init-copy',
        negatable: false,
        help: 'Write a starter InfoPlist.copy.json from the current '
            'Info.plist, then stop.',
      );
  }

  bool get _jsonOut => (globalResults?['json'] as bool?) ?? false;
  bool get _dryRun => (globalResults?['dry-run'] as bool?) ?? false;

  @override
  String get name => 'native';
  @override
  String get description =>
      "Declare the app's locales to iOS and Android, and translate the iOS "
      'permission alerts (Info.plist, locales_config.xml, *.lproj).';
  @override
  String get invocation => 'fl native [--check] [--init-copy]';

  @override
  Future<int> run() async {
    final Directory root = Directory.current;
    String? arbDir;
    try {
      arbDir =
          ProjectConfig.load(path: globalResults?['config'] as String?).arbDir;
    } on Object {
      // No project config is fine: locales come from the generated Dart, and
      // this command has nothing to say to the backend.
      arbDir = null;
    }

    if (argResults?['init-copy'] as bool? ?? false) {
      final Directory? target = findIosTargetDir(root);
      if (target == null) {
        stderr.writeln('No iOS target found under ${root.path}/ios.');
        return 1;
      }
      final File out = File('${target.path}/$kCopyFileName');
      if (out.existsSync()) {
        stderr.writeln('${out.path} already exists — not overwriting it.');
        return 1;
      }
      final NativeSyncPlan plan = planNativeSync(root, arbDir: arbDir);
      out.writeAsStringSync(
        initCopyFile(
            target, plan.locales.contains('en') ? 'en' : plan.locales.first),
      );
      stdout.writeln('✓ Wrote ${out.path}');
      stdout.writeln('  Translate it into: ${plan.locales.join(", ")}');
      stdout.writeln('  Then run `fl native`.');
      return 0;
    }

    final NativeSyncPlan plan;
    try {
      plan = planNativeSync(root, arbDir: arbDir);
    } on StateError catch (e) {
      stderr.writeln(e.message);
      return 1;
    }
    final List<String> stale = plan.stale;

    if (argResults?['check'] as bool? ?? false) {
      if (_jsonOut) {
        stdout.writeln(
          const JsonEncoder.withIndent('  ').convert(
            <String, dynamic>{
              'locales': plan.locales,
              'stale': stale,
              'notes': plan.notes,
            },
          ),
        );
      }
      if (stale.isEmpty) {
        if (!_jsonOut) {
          stdout.writeln('✓ Native locale declarations match '
              '${plan.locales.length} locale(s).');
        }
        return 0;
      }
      if (!_jsonOut) {
        stderr.writeln('Stale for ${plan.locales.length} locale(s):');
        for (final String path in stale) {
          stderr.writeln('  · ${_relative(path, root)}');
        }
        stderr.writeln('Run: fl native');
      }
      return 1;
    }

    if (_dryRun) {
      stdout.writeln('DRY RUN: would write ${stale.length} file(s) for '
          '${plan.locales.length} locale(s):');
      for (final String path in stale) {
        stdout.writeln('  · ${_relative(path, root)}');
      }
      for (final String note in plan.notes) {
        stdout.writeln('  ! $note');
      }
      return 0;
    }

    final List<String> changed = applyNativeSync(plan);
    if (_jsonOut) {
      stdout.writeln(
        const JsonEncoder.withIndent('  ').convert(
          <String, dynamic>{
            'locales': plan.locales,
            'changed': changed,
            'notes': plan.notes,
          },
        ),
      );
      return 0;
    }
    stdout.writeln(changed.isEmpty
        ? '✓ Already current: ${plan.locales.length} locale(s).'
        : '✓ Updated ${changed.length} file(s) for ${plan.locales.length} locale(s).');
    for (final String note in plan.notes) {
      stdout.writeln('  ! $note');
    }
    return 0;
  }

  String _relative(final String path, final Directory root) =>
      path.startsWith(root.path) ? path.substring(root.path.length + 1) : path;
}

String _requireKey(final Command<int> cmd) {
  final List<String> rest = cmd.argResults!.rest;
  if (rest.isEmpty) {
    throw UsageException('Missing <key> argument.', cmd.usage);
  }
  return rest.first;
}

/// Write every locale's ARB straight from the API.
///
/// `clone`/`pull` are the normal path, but they only work when the dashboard
/// has a git provider linked AND the repository it names actually exists. When
/// it does not — an unfinished OAuth step, a deleted repo — the project can be
/// fully translated while the app still ships one language, and until this
/// command there was nothing in the tool that could close the gap. The ARBs are
/// still generated from the backend's data, not hand-written; this is the
/// dashboard's Export, from the terminal.
class ExportCommand extends Command<int> with _ApiCommand {
  ExportCommand() {
    argParser.addFlag('discard-local',
        negatable: false,
        help: 'Write even though the template holds keys the service does '
            'not have (they are lost).',);
  }

  @override
  String get name => 'export';
  @override
  String get description =>
      'Write every locale to app_<locale>.arb in arb_dir, straight from the '
      'API. Use when the ARB git repo is not linked (otherwise prefer `pull`).';
  @override
  String get invocation => 'fl export [<dir>]';

  @override
  Future<int> run() async {
    final ProjectConfig cfg = loadProject();
    final String dir = argResults!.rest.isNotEmpty
        ? argResults!.rest.first
        : (cfg.arbDir ?? 'arbs/Default');
    final ({
      ManagementClient client,
      Operations ops,
      String projectName
    }) built = await build(cfg);
    try {
      // The same hazard `pull` guards: this rewrites the template from the
      // service, so a key staged on disk and never imported disappears. That
      // is how eight onboarding keys were lost once, and why this command
      // carried a "never run it here" warning in a consuming repo instead of
      // a check.
      if (!(argResults!['discard-local'] as bool)) {
        final ProjectData project =
            await built.client.getProject(built.ops.projectId);
        final LanguageData? base = project.baseLanguage(built.ops.flavor);
        if (base != null) {
          final String template =
              'app_${base.code.replaceAll('-', '_')}.arb';
          final List<String> orphans = localOnlyKeys(
            File('$dir/$template'),
            <String>{
              for (final TranslationEntry t in base.translations)
                if (t.key.isNotEmpty) t.key,
            },
          );
          if (orphans.isNotEmpty) {
            stderr.writeln(
                '$template holds ${orphans.length} key(s) the service does '
                'not have: ${orphans.take(10).join(', ')}'
                '${orphans.length > 10 ? ', …' : ''}');
            stderr.writeln(
                'Exporting would overwrite them. Import them first '
                '(`fl import $dir/$template --translate`), or run '
                '`fl pull --adopt`, or force with `--discard-local`.');
            return 1;
          }
        }
      }
      final OpResult r = await built.ops.exportArbs(dir, dryRun: dryRun);
      if (jsonOut) return emit(r);
      stdout.writeln(r.message);
      for (final dynamic row
          in (r.data['files'] as List<dynamic>?) ?? const <dynamic>[]) {
        final Map<String, dynamic> m = row as Map<String, dynamic>;
        stdout.writeln('  ${m['file']}  ${m['keys']} key(s)'
            '${m['base'] == true ? '  (template)' : ''}');
      }
      if (r.ok && !dryRun) {
        stdout.writeln('\nNow regenerate the Dart: `flutter pub get` then '
            '`flutter pub run flutter_localisation:generate <flavor>`.');
      }
      return r.ok ? 0 : 1;
    } finally {
      built.client.close();
    }
  }
}
