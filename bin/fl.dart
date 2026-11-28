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

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:path/path.dart' as path;

import 'package:flutter_localisation_cli/src/self_update.dart';
import 'package:flutter_localisation_cli/src/angular.dart';
import 'package:flutter_localisation_cli/src/ngx.dart';
import 'package:flutter_localisation_cli/src/arb_sync.dart';
import 'package:flutter_localisation_cli/src/codegen.dart';
import 'package:flutter_localisation_cli/src/config.dart';
import 'package:flutter_localisation_cli/src/exceptions.dart';
import 'package:flutter_localisation_cli/src/file_diff.dart';
import 'package:flutter_localisation_cli/src/glossary.dart';
import 'package:flutter_localisation_cli/src/guard.dart';
import 'package:flutter_localisation_cli/src/init_detect.dart';
import 'package:flutter_localisation_cli/src/l10n_doctor.dart';
import 'package:flutter_localisation_cli/src/locales.dart';
import 'package:flutter_localisation_cli/src/management_client.dart';
import 'package:flutter_localisation_cli/src/platform.dart';
import 'package:flutter_localisation_cli/src/native_sync.dart';
import 'package:flutter_localisation_cli/src/operations.dart';
import 'package:flutter_localisation_cli/src/project_resolver.dart';
import 'package:flutter_localisation_cli/src/repo_locales.dart';
import 'package:flutter_localisation_cli/src/repo_platforms.dart';
import 'package:flutter_localisation_cli/src/repo_url.dart';
import 'package:flutter_localisation_cli/src/version.dart';
import 'package:flutter_localisation_cli/src/xcstrings.dart';

Future<void> main(final List<String> args) async {
  if (!args.contains('upgrade')) {
    final int? newer = await runNewerIfAny(args);
    if (newer != null) exit(newer);
  }
  final CommandRunner<int> runner = CommandRunner<int>(
    'fl',
    'FlutterLocalisation management CLI: manage the strings of a Flutter, iOS or Angular app from the terminal.',
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
    )
    ..argParser.addFlag(
      'version',
      negatable: false,
      help: 'Print the version of fl.',
    );

  runner.addCommand(LoginCommand());
  runner.addCommand(InitCommand());
  runner.addCommand(ProjectsCommand());
  runner.addCommand(AddCommand());
  runner.addCommand(ImportCommand());
  runner.addCommand(DiffCommand());
  runner.addCommand(ShowCommand());
  runner.addCommand(EditCommand());
  runner.addCommand(DeleteCommand());
  runner.addCommand(TranslateCommand());
  runner.addCommand(LanguagesCommand());
  runner.addCommand(StatusCommand());
  runner.addCommand(RetranslateCommand());
  runner.addCommand(ShortenCommand());
  runner.addCommand(RepoCommand());
  runner.addCommand(CloneCommand());
  runner.addCommand(PullCommand());
  runner.addCommand(SyncCommand());
  runner.addCommand(GuardCommand());
  runner.addCommand(DoctorCommand());
  runner.addCommand(NativeCommand());
  runner.addCommand(ExportCommand());
  runner.addCommand(GlossaryCommand());
  runner.addCommand(StyleCommand());
  runner.addCommand(LockCommand(lock: true));
  runner.addCommand(LockCommand(lock: false));
  runner.addCommand(UpgradeCommand());

  try {
    ArgResults top = runner.parse(args);
    if (top['version'] as bool) {
      stdout.writeln('fl $kCliVersion');
      exit(0);
    }
    // `fl style`, `fl languages` and `fl glossary` on their own show what is
    // there, where CommandRunner would answer "Missing subcommand".
    final ArgResults? group = top.command;
    if (group != null &&
        const <String>{'style', 'languages', 'glossary'}.contains(group.name) &&
        group.command == null &&
        group.rest.isEmpty &&
        !(group['help'] as bool)) {
      top = runner.parse(<String>[...args, 'list']);
    }
    final int? code = await runner.runCommand(top);
    _announceUpdate();
    exit(code ?? 0);
  } on UsageException catch (e) {
    stderr.writeln(e);
    exit(64);
  } on ArgumentError catch (e) {
    // What `args` throws for a missing mandatory option, read inside run(),
    // after CommandRunner's own usage handling.
    stderr.writeln('${e.message}\n\n${_usageFor(runner, args)}');
    exit(64);
  } on ManagementException catch (e) {
    stderr.writeln('Error: ${e.message}');
    // A refused version already names the update in its message.
    if (e is ApiException && e.isClientOutdated) exit(1);
    _announceUpdate();
    if (e is ApiException) _writeRowErrors(e);
    final String msg = e.message.toLowerCase();
    if (msg.contains('re-auth') || msg.contains('token expired')) {
      stderr.writeln(
          'Hint: the backend\'s GitHub connection is disconnected. The change '
          'was saved, but ARB files can\'t sync until you reconnect GitHub in the dashboard '
          '(project → Repo → reconnect).');
    } else if (e is ApiException && e.isScopeRefusal) {
      // The message already names the scope and where it is switched on.
    } else if (e is ApiException && e.isForbidden) {
      stderr
          .writeln('Hint: your token may lack the required scope, or the plan '
              'limit was reached.');
    } else if (e is ApiException && e.isAuth) {
      final String from =
          _tokenSource == null ? 'The token' : 'The token from $_tokenSource';
      stderr.writeln(
          'Hint: $from was rejected: revoked, expired, or made for another '
          'workspace. Create one in the dashboard (workspace → API tokens) and '
          'run `fl login --token flk_live_...`, or set \$FL_API_TOKEN.');
    }
    exit(1);
  }
}

/// One line on stderr when the service named a newer version, after the
/// command's own output so a build log ends with it. stdout is left alone:
/// `--json` output stays parseable. At a desk it is said once a day, see
/// [UpdateNotice.isDue].
void _announceUpdate() {
  final UpdateNotice? notice = UpdateNotice.current;
  if (notice == null || !notice.isDue(Platform.environment)) return;
  stderr.writeln('\n${notice.describe('fl')}  (or: fl upgrade)');
}

/// Installs the latest published version over this one.
class UpgradeCommand extends Command<int> {
  @override
  String get name => 'upgrade';
  @override
  String get description =>
      'Install the latest fl and fl_mcp from pub.dev over this version.';

  @override
  Future<int> run() async {
    if ((globalResults?['dry-run'] as bool?) ?? false) {
      stdout.writeln('DRY RUN: would run `${upgradeCommandFor()}`.');
      return 0;
    }
    stdout.writeln('fl $kCliVersion: running `${upgradeCommandFor()}` …');
    if (installedByNpm()) {
      final List<String> words = kNpmUpgradeCommand.split(' ');
      final Process npm = await Process.start(
          words.first, words.skip(1).toList(),
          runInShell: true, mode: ProcessStartMode.inheritStdio);
      return npm.exitCode;
    }
    // The VM that runs this script, unless fl was compiled to a binary of
    // its own, in which case `dart` has to come from the PATH.
    final String self = Platform.resolvedExecutable;
    final bool isDart = path.basenameWithoutExtension(self) == 'dart';
    final Process process = await Process.start(
      isDart ? self : 'dart',
      kUpgradeCommand.split(' ').skip(1).toList(),
      runInShell: !isDart && Platform.isWindows,
      mode: ProcessStartMode.inheritStdio,
    );
    return process.exitCode;
  }
}

/// The usage of the deepest command named in [args], else the runner's.
String _usageFor(final CommandRunner<int> runner, final List<String> args) {
  Map<String, Command<int>> commands = runner.commands;
  Command<int>? found;
  for (final String arg in args) {
    final Command<int>? next = commands[arg];
    if (next == null) continue;
    found = next;
    commands = next.subcommands;
  }
  return found?.usage ?? runner.usage;
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
/// Where the last resolved token came from, named in the 401 hint.
String? _tokenSource;

mixin _ApiCommand on Command<int> {
  bool get jsonOut => (globalResults?['json'] as bool?) ?? false;
  bool get dryRun => (globalResults?['dry-run'] as bool?) ?? false;

  ProjectConfig loadProject() =>
      ProjectConfig.load(path: globalResults?['config'] as String?);

  ManagementClient buildClient(final ProjectConfig cfg) {
    final Credentials creds = Credentials.resolve(
      explicit: globalResults?['token'] as String?,
      baseUrl: cfg.baseUrl,
      tokenFile: cfg.tokenFile,
    );
    _tokenSource = creds.source;
    final ManagementClient client = ManagementClient(
        baseUrl: cfg.baseUrl, token: creds.token, reuseProjectReads: true);
    narrowToRepo(client, cfg, stderr.writeln);
    return client;
  }

  /// Live progress goes to stderr, so `--json` output on stdout stays clean.
  void Function(String)? get _progressSink =>
      jsonOut ? null : (final String line) => stderr.writeln(line);

  /// Resolve the target project (by id/name, or the sole project) and build [Operations].
  Future<({ManagementClient client, Operations ops, String projectName})> build(
    final ProjectConfig cfg,
  ) async {
    final ManagementClient client = buildClient(cfg);
    final String? projectArg = globalResults?['project'] as String?;
    final String? flavor = (globalResults?['flavor'] as String?) ?? cfg.flavor;

    // Fast path: an explicit numeric id in config and no name override, no
    // lookup needed. Without a flavor, `arb_dir` may name it, and only the
    // project's flavor list can tell.
    if (projectArg == null &&
        cfg.projectId != null &&
        (flavor != null || cfg.arbDir == null)) {
      return (
        client: client,
        ops: Operations(client, cfg.projectId!, flavor: flavor)
          ..onProgress = _progressSink,
        projectName: cfg.project ?? 'project ${cfg.projectId}',
      );
    }

    final ProjectResolver resolver = ProjectResolver(
      client,
      defaultProject: cfg.projectSelector,
      defaultFlavor: flavor,
      flavorHint: cfg.arbDirFlavor,
    );
    final ResolvedTarget target =
        await resolver.resolve(project: projectArg, flavor: flavor);
    return (
      client: client,
      ops: Operations(client, target.projectId, flavor: target.flavor)
        ..onProgress = _progressSink,
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
    argParser.addFlag(
      'verify',
      defaultsTo: true,
      help: 'Check the token against the API before saving it.',
    );
  }

  @override
  String get name => 'login';
  @override
  String get description =>
      'Check a scoped API token against the API and store it (~/.config, chmod 600).';

  @override
  Future<int> run() async {
    final String token = argResults!['token'] as String;
    final String baseUrl = argResults!['base-url'] as String;
    if (!token.startsWith('flk_')) {
      stderr.writeln('Warning: token does not look like a flk_ key.');
    }
    if (argResults!['verify'] as bool) {
      final ManagementClient client =
          ManagementClient(baseUrl: baseUrl, token: token);
      try {
        final List<ProjectSummary> projects = await client.listProjects();
        stdout.writeln(
            '✓ $baseUrl accepts the token (${projects.length} project(s)).');
      } on ApiException catch (e) {
        if (!e.isAuth) rethrow;
        stderr.writeln(
            'Error: $baseUrl rejected the token (HTTP 401). Nothing saved. '
            'Create one in the dashboard (workspace → API tokens), or pass '
            '--no-verify to store it anyway.');
        return 1;
      } finally {
        client.close();
      }
    }
    Credentials.save(token, baseUrl: baseUrl);
    stdout.writeln('✓ Token saved for $baseUrl.');
    return 0;
  }
}

const String kDashboardUrl = 'https://app.flutterlocalisation.com';

/// First run on a repository: token, project, folders, then the first pull.
///
/// Everything it does exists as its own command (`login`, `projects`,
/// `pull`, `guard`, `native`, `status`); the wizard only strings them
/// together and writes `flutterlocalisation.json` so none of them needs
/// `--project` afterwards. Every question has a default, so `--yes` (or a
/// pipe for stdin) runs it without a human; what cannot be defaulted, like
/// which of several projects, must then come from a flag.
class InitCommand extends Command<int> with _ApiCommand {
  InitCommand() {
    argParser
      ..addOption('base-url',
          defaultsTo: kDefaultBaseUrl, help: 'API base URL.')
      ..addOption('arb-dir',
          help: 'Where the ARBs go (default: l10n.yaml arb-dir, else '
              'arbs/<flavor>).')
      ..addOption('xcstrings-dir',
          help: 'Where the String Catalogs go (default: the folder of an '
              'existing Localizable.xcstrings, else beside Info.plist).')
      ..addOption('angular-dir',
          help: 'Where Angular\'s messages.<locale>.arb files go (default: '
              'the outputPath of extract-i18n in angular.json, else '
              'src/locale), or the <locale>.json files of an ngx-translate '
              'project (default: an existing src/assets/i18n or public/i18n).')
      ..addOption('platforms',
          help: 'The platforms of the project this repository holds, for a '
              'project that ships to several (ios, or flutter,ios). Default: '
              'what the repository shows (pubspec.yaml, an Xcode project, '
              'angular.json).')
      ..addOption('token-file',
          help: 'A file holding this project\'s token (~ allowed), written '
              'into the config as "token_file": the repo then uses that token '
              'whatever `fl login` stored.')
      ..addFlag('yes',
          abbr: 'y',
          negatable: false,
          help: 'Take every default without asking.')
      ..addFlag('pull',
          defaultsTo: true,
          help:
              'Pull the strings (and, for Flutter, regenerate the Dart) once configured.')
      ..addFlag('guard',
          negatable: false,
          help: 'Also write the AI guard rules (asked for when interactive).')
      ..addFlag('force',
          negatable: false,
          help: 'Overwrite an existing flutterlocalisation.json.');
  }

  @override
  String get name => 'init';
  @override
  String get description =>
      'Set up this repository: store the token, pick the project and '
      'folders, write flutterlocalisation.json, then pull the strings.';
  @override
  String get invocation =>
      'fl init [--project <name|id>] [--flavor <name>] [-y]';

  @override
  Future<int> run() async {
    final bool yes = argResults!['yes'] as bool;
    // FL_INTERACTIVE=1 asks the questions even when stdin is a pipe, so a
    // script (or a test) can feed the answers line by line.
    final Prompter ask = Prompter(
        interactive: !yes &&
            (stdin.hasTerminal ||
                Platform.environment['FL_INTERACTIVE'] == '1'));
    final String baseUrl = (argResults!['base-url'] as String).trimRight();
    final Directory root = Directory.current;
    final File configFile = File('${root.path}/$kProjectConfigName');

    if (configFile.existsSync() && !(argResults!['force'] as bool)) {
      if (!ask.confirm('$kProjectConfigName already exists here. Overwrite it?',
          fallback: false)) {
        stderr.writeln('Nothing changed. Pass --force to overwrite it.');
        return 1;
      }
    }

    // 1. Token: whatever `fl` already resolves, else ask for a paste.
    Credentials creds;
    try {
      creds = Credentials.resolve(
        explicit: globalResults?['token'] as String?,
        baseUrl: baseUrl,
        tokenFile: argResults!['token-file'] as String?,
      );
    } on AuthConfigException {
      if (argResults!['token-file'] != null) rethrow;
      if (!ask.interactive) rethrow;
      stdout.writeln('No API token stored yet. Create one in the dashboard:\n'
          '  $kDashboardUrl  →  workspace  →  API keys\n'
          'then paste it here (it is kept in ~/.config, chmod 600).');
      final String pasted = ask.secret('flk_live_ token');
      if (pasted.isEmpty) {
        stderr.writeln('No token given.');
        return 1;
      }
      creds = Credentials(pasted, source: 'the prompt');
    }
    _tokenSource = creds.source;
    final ManagementClient client =
        ManagementClient(baseUrl: baseUrl, token: creds.token);

    try {
      // 2. Project, then flavor.
      final List<ProjectSummary> projects = await client.listProjects();
      if (creds.source == 'the prompt') {
        Credentials.save(creds.token, baseUrl: baseUrl);
        stdout.writeln('✓ Token saved for $baseUrl.');
      }
      if (projects.isEmpty) {
        stderr.writeln('This token sees no project. Create one in the '
            'dashboard ($kDashboardUrl/projects), then run `fl init` again.');
        return 1;
      }
      final ProjectSummary project = _pickProject(ask, projects);
      final FlavorSummary flavor = _pickFlavor(ask, project);
      stdout.writeln(
          'Project: ${project.name} (${platformLabels(project.platforms)})'
          '${project.flavors.length > 1 ? ', flavor ${flavor.name}' : ''}');
      final List<AppPlatform>? held = _heldPlatforms(ask, project, root);
      if (held == null) return 1;
      final bool flutter = held.contains(AppPlatform.flutter);
      final bool ios = held.contains(AppPlatform.ios);
      final bool angular = held.contains(AppPlatform.angular);
      final bool ngx = held.contains(AppPlatform.ngx);

      // 3. Folders, prefilled from the repository.
      String? arbDir;
      if (flutter) {
        arbDir = (argResults!['arb-dir'] as String?) ??
            ask.ask('ARB folder', l10nArbDir(root) ?? 'arbs/${flavor.name}');
      }
      String? catalogDir;
      List<String>? catalogs;
      if (ios) {
        final List<String>? found =
            argResults!['xcstrings-dir'] == null ? catalogEntries(root) : null;
        if (found != null &&
            ask.confirm('This app has ${found.length} String Catalogs '
                '(${found.join(', ')}). Give each one its own keys '
                '(xcstrings_catalogs)?')) {
          catalogs = found;
        } else {
          catalogDir = (argResults!['xcstrings-dir'] as String?) ??
              ask.ask('String Catalog folder',
                  existingCatalogDir(root) ?? defaultCatalogDir(root));
        }
      }
      String? angularDir;
      if (angular) {
        angularDir = (argResults!['angular-dir'] as String?) ??
            ask.ask('Angular locale folder',
                angularExtractDir(root.path) ?? kAngularDefaultDir);
      } else if (ngx) {
        angularDir = (argResults!['angular-dir'] as String?) ??
            ask.ask(
                'ngx-translate folder', ngxDirIn(root.path) ?? kNgxDefaultDir);
      }
      if (!project.platforms.contains(AppPlatform.ngx) &&
          usesNgxTranslate(root.path)) {
        stdout.writeln('This app loads its strings with ngx-translate. Set the '
            'project\'s platform to ngx-translate in the dashboard (project '
            'settings) so `fl pull` writes <locale>.json files.');
      }

      // 4. The config every later command reads.
      final Map<String, dynamic> cfg = <String, dynamic>{
        if (baseUrl != kDefaultBaseUrl) 'base_url': baseUrl,
        'project': project.name,
        'project_id': project.id,
        if (project.flavors.isNotEmpty) 'flavor': flavor.name,
        if (project.platforms.length > 1 || argResults!['platforms'] != null)
          'platforms': platformWires(held),
        if (arbDir != null) 'arb_dir': arbDir,
        if (catalogDir != null) 'xcstrings_dir': catalogDir,
        if (catalogs != null) 'xcstrings_catalogs': catalogs,
        if (angularDir != null) 'angular_dir': angularDir,
        if (argResults!['token-file'] != null)
          'token_file': argResults!['token-file'],
      };
      configFile.writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert(cfg)}\n');
      stdout.writeln('✓ Wrote $kProjectConfigName.');
      if (jsonOut) {
        stdout.writeln(const JsonEncoder.withIndent('  ').convert(
            <String, dynamic>{'ok': true, 'config': configFile.path, ...cfg}));
      }
      if (dryRun || !(argResults!['pull'] as bool)) return 0;
    } finally {
      client.close();
    }

    // 5. First pull. A key that exists only on disk stops `pull`; the wizard
    // is the one place where "import it" is the obvious answer, so offer it.
    final List<String> passthrough = <String>[
      if (globalResults?['token'] != null) ...<String>[
        '--token',
        globalResults!['token'] as String,
      ],
    ];
    int code =
        await runner!.run(<String>[...passthrough, 'pull', '--from-init']) ?? 0;
    if (code == _kLocalOnlyKeys) {
      if (!ask.confirm('Import them (and the translations in the ARBs beside '
          'them), then pull?')) {
        stderr.writeln('Nothing was imported or pulled. Later, run '
            '`fl pull --adopt` to import them or `fl pull --discard-local` to '
            'take the service copy.');
        return 1;
      }
      code =
          await runner!.run(<String>[...passthrough, 'pull', '--adopt']) ?? 0;
    }
    if (code != 0) return code;

    final ProjectConfig written = ProjectConfig.load(path: configFile.path);
    if (written.arbDir != null && looksLikeFlutterApp(root)) {
      final int gen = await _regenerateDart(written,
          skipHint: '$kProjectConfigName is written and the strings are '
              'pulled; run `fl sync` once the generator works.');
      if (gen != 0) return gen;
    }

    // 6. The optional extras, each its own command.
    // Enter means yes at the prompt; `--yes` means no unless --guard says so.
    final bool guard = (argResults!['guard'] as bool) ||
        ask.confirm(
            'Write rules for Claude Code and GitHub Copilot so AI edits go '
            'through fl, not the ARBs (fl guard)?',
            fallback: ask.interactive);
    if (guard) await runner!.run(<String>['guard']);
    if (findIosTargetDir(root) != null &&
        ask.confirm('Declare the locales to iOS and Android now (fl native)?',
            fallback: false)) {
      await runner!.run(<String>['native']);
    }

    stdout.writeln();
    return await runner!.run(<String>[...passthrough, 'status']) ?? 0;
  }

  /// The platforms of [project] this repository holds: `--platforms`, else
  /// asked with what the repository shows as the answer, which `--yes`
  /// takes. Null, with the reason printed, when none can be settled on.
  List<AppPlatform>? _heldPlatforms(
      final Prompter ask, final ProjectSummary project, final Directory root) {
    final String? given = argResults!['platforms'] as String?;
    if (given == null && project.platforms.length < 2) return project.platforms;
    final Map<AppPlatform, String> seen = detectRepoPlatforms(root.path);
    final List<AppPlatform> shown = <AppPlatform>[
      for (final AppPlatform pl in project.platforms)
        if (seen.containsKey(pl)) pl,
    ];
    String answer = given ?? platformWires(shown).join(',');
    if (given == null) {
      if (shown.isNotEmpty) {
        stdout.writeln('This repository shows ${<String>[
          for (final AppPlatform pl in shown) '${pl.label} (${seen[pl]})',
        ].join(', ')}.');
      }
      answer = ask.ask(
          'Platforms this repository holds '
          '(${platformWires(project.platforms).join(', ')})',
          answer.isEmpty ? platformWires(project.platforms).join(',') : answer);
      if (!ask.interactive && shown.isEmpty) {
        stderr.writeln('The project ships '
            '${platformLabels(project.platforms, separator: ', ')} and nothing '
            'here shows which of them this repository holds. Pass '
            '--platforms (for example --platforms '
            '${project.platforms.first.wire}).');
        return null;
      }
    }
    final List<AppPlatform> wanted;
    try {
      wanted = <AppPlatform>[
        for (final String w in parsePlatformList(<String>[answer]))
          AppPlatform.fromWire(w)!,
      ];
    } on ArgumentError catch (e) {
      stderr.writeln(e.message);
      return null;
    }
    final List<AppPlatform> held = <AppPlatform>[
      for (final AppPlatform pl in project.platforms)
        if (wanted.contains(pl)) pl,
    ];
    if (held.isEmpty || held.length < wanted.toSet().length) {
      stderr.writeln('The project ships '
          '${platformLabels(project.platforms, separator: ', ')}; "$answer" '
          'names ${held.isEmpty ? 'none of them' : 'others too'}.');
      return null;
    }
    return held;
  }

  ProjectSummary _pickProject(
      final Prompter ask, final List<ProjectSummary> projects) {
    final String? wanted = globalResults?['project'] as String?;
    if (wanted != null) {
      final int? id = int.tryParse(wanted);
      return projects.firstWhere(
        (final ProjectSummary p) =>
            p.id == id || p.name.toLowerCase() == wanted.toLowerCase(),
        orElse: () => throw UsageException(
            'No project "$wanted". `fl projects` lists them.', usage),
      );
    }
    final int? i = ask.choose(
      'Which project?',
      <String>[
        for (final ProjectSummary p in projects)
          '${p.name}  (${platformLabels(p.platforms)}, ${p.workspace})',
      ],
    );
    if (i == null) {
      throw UsageException(
          '${projects.length} projects are reachable; pass --project <name|id>.',
          usage);
    }
    return projects[i];
  }

  FlavorSummary _pickFlavor(final Prompter ask, final ProjectSummary project) {
    final String? wanted = globalResults?['flavor'] as String?;
    if (wanted != null) {
      return project.flavors.firstWhere(
        (final FlavorSummary f) => f.name.toLowerCase() == wanted.toLowerCase(),
        orElse: () => throw UsageException(
            'Project "${project.name}" has no flavor "$wanted".', usage),
      );
    }
    if (project.flavors.isEmpty) {
      return FlavorSummary(
          name: 'Default', baseLanguage: null, languages: const <String>[]);
    }
    final int i = ask.choose(
          'Which flavor?',
          <String>[
            for (final FlavorSummary f in project.flavors)
              '${f.name}  (${f.languages.join(', ')})',
          ],
          fallback: 0,
        ) ??
        0;
    return project.flavors[i];
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
                    'platforms': platformWires(p.platforms),
                    'flavors': p.flavors
                        .map(
                          (final FlavorSummary f) => <String, dynamic>{
                            'id': f.id,
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
        stdout.writeln(
            '${p.name}  (id ${p.id}, platforms: ${platformLabels(p.platforms, separator: ', ')})$warn');
        for (final FlavorSummary f in p.flavors) {
          final String base =
              f.baseLanguage != null ? '  [base ${f.baseLanguage}]' : '';
          final String id = f.id == null ? '' : ' (id ${f.id})';
          stdout.writeln('  · ${f.name}$id: ${f.languages.join(", ")}$base');
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
    _addKeySettingOptions(argParser);
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
      '[--placeholder name:type[:format]] [--platforms ios,angular] '
      '[--max-length ios=40]';

  @override
  Future<int> run() async {
    final String key = _requireKey(this);
    final Map<String, dynamic>? placeholders =
        parsePlaceholderSpecs(argResults!['placeholder'] as List<String>);
    final ({List<String>? platforms, Map<String, int>? maxLength}) settings =
        _keySettings(argResults!);
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
        platforms: settings.platforms,
        maxLength: settings.maxLength,
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
      help: 'Locale the ARB represents (default: the one the file names in '
          '@@locale or its file name, else the project base language). '
          'Ignored for a String Catalog, which carries every locale.',
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
    argParser.addFlag(
      'prune',
      negatable: false,
      help: 'Source file only: after the import, delete the keys the service '
          'has and the file no longer does. --dry-run lists them first.',
    );
  }

  @override
  String get name => 'import';
  @override
  String get description =>
      'Bulk-create keys from an ARB file, an Xcode String Catalog '
      '(.xcstrings) or an ngx-translate <locale>.json in ONE request (vs many '
      '`add`s).';
  @override
  String get invocation =>
      'fl import <file.arb|file.xcstrings|locale.json> [--language <code>] '
      '[--overwrite] [--translate] [--prune]';

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
    final ProjectConfig cfg = loadProject();
    String fileName = file.uri.pathSegments.last;
    final List<CatalogTarget>? targets = cfg.xcstringsCatalogs;
    if (targets != null && fileName.endsWith('.xcstrings')) {
      final List<CatalogTarget> named = catalogsNamed(file.path, targets);
      if (targets.contains(named.single)) {
        final int? refused = _refuseConflicts(this, targets,
            only: catalogKeys(_jsonOrNull(content)).toSet());
        if (refused != null) return refused;
        // A named table's keys live in the service's one Localizable table.
        fileName = kLocalizableCatalog;
      }
    }
    final ({
      ManagementClient client,
      Operations ops,
      String projectName
    }) built = await build(cfg);
    try {
      final OpResult r = await built.ops.importArb(
        content,
        languageCode: _locale(argResults!['language'] as String?),
        overwrite: argResults!['overwrite'] as bool,
        translate: argResults!['translate'] as bool,
        dryRun: dryRun,
        prune: argResults!['prune'] as bool,
        fileName: fileName,
      );
      return emit(r);
    } finally {
      built.client.close();
    }
  }
}

/// A file on disk against the service, before an import or an export
/// overwrites one side.
class DiffCommand extends Command<int> with _ApiCommand {
  DiffCommand() {
    argParser.addOption(
      'language',
      abbr: 'l',
      help: 'Locale the file stands for (default: what the file says).',
    );
  }

  @override
  String get name => 'diff';
  @override
  String get description =>
      'Compare a translation file (Flutter or Angular ARB, ngx-translate '
      'json, String Catalog) with the service: keys only the file has, keys '
      'whose text differs, keys only the service has. Changes nothing. '
      'Without a file, every catalog of "xcstrings_catalogs".';
  @override
  String get invocation => 'fl diff [<file>] [--language <code>]';

  @override
  Future<int> run() async {
    final List<String> rest = argResults!.rest;
    final ProjectConfig cfg = loadProject();
    final List<CatalogTarget>? targets = cfg.xcstringsCatalogs;
    if (rest.isEmpty && targets == null) {
      throw UsageException('Missing <file> path argument.', usage);
    }
    final File? file = rest.isEmpty ? null : File(rest.first);
    if (file != null && !file.existsSync()) {
      stderr.writeln('Error: file not found: ${rest.first}');
      return 1;
    }
    final ({
      ManagementClient client,
      Operations ops,
      String projectName
    }) built = await build(cfg);
    try {
      if (file == null || file.path.endsWith('.xcstrings')) {
        return emit(await built.ops.compareCatalogs(
          file == null ? targets! : catalogsNamed(file.path, targets),
          all: targets,
          shown: path.relative,
        ));
      }
      final String name = file.uri.pathSegments.last;
      final FileDiff d = await built.ops.compareFile(file.readAsStringSync(),
          fileName: name,
          languageCode: _locale(argResults!['language'] as String?));
      return emit(OpResult(true, describeDiff(d, name), d.toJson()));
    } finally {
      built.client.close();
    }
  }
}

class ShowCommand extends Command<int> with _ApiCommand {
  @override
  String get name => 'show';
  @override
  String get description =>
      'Print one key: its text in every locale, its target texts (ios, ...), '
      'platforms and max lengths. Changes nothing.';
  @override
  String get invocation => 'fl show <key>';

  @override
  Future<int> run() async {
    final String key = _requireKey(this);
    final ({
      ManagementClient client,
      Operations ops,
      String projectName
    }) built = await build(loadProject());
    try {
      final OpResult r = await built.ops.show(key);
      if (jsonOut) return emit(r);
      stdout.writeln(r.message);
      return 0;
    } finally {
      built.client.close();
    }
  }
}

class EditCommand extends Command<int> with _ApiCommand {
  EditCommand() {
    argParser.addOption('locale',
        help: 'Locale code, e.g. fr (default: the base language).');
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
    argParser.addOption('target',
        help: 'Write the text of one target instead of the full text: a '
            'platform (flutter, ios, angular, ngx) or an Apple device '
            '(ios/iphone, ios/ipad, ios/ipod, ios/mac, ios/applewatch, '
            'ios/applevision, ios/appletv, ios/other). Targets without one get the full text.');
    argParser.addFlag('clear',
        negatable: false,
        help: 'With --target: remove that target\'s text, so it gets the '
            'full text again.');
    _addKeySettingOptions(argParser);
  }

  @override
  String get name => 'edit';
  @override
  String get description =>
      'Edit a locale\'s value / flags of an existing key, the text of one '
      'target (--target ios), or the key\'s platforms and max lengths.';
  @override
  String get invocation =>
      'fl edit <key> [--locale <code>] [--value "..."] [--singular-case "..." '
      '--plural-case "..."]\n'
      '       fl edit <key> --target ios [--locale <code>] ("..." | --clear)\n'
      '       fl edit <key> [--platforms ios,angular] [--max-length ios=40]\n'
      'A String Catalog key may be given by its stem: "done_body" finds '
      '"done_body %@ %lld". Placeholders are written {arg1}, {arg2} in the value.';

  @override
  Future<int> run() async {
    final String key = _requireKey(this);
    final Map<String, dynamic>? placeholders =
        parsePlaceholderSpecs(argResults!['placeholder'] as List<String>);
    final ({List<String>? platforms, Map<String, int>? maxLength}) settings =
        _keySettings(argResults!);
    final ({
      ManagementClient client,
      Operations ops,
      String projectName
    }) built = await build(loadProject());
    try {
      final List<String> rest = argResults!.rest;
      final OpResult r = await built.ops.edit(
        key,
        _locale(argResults!['locale'] as String?),
        // `fl edit <key> "text"`, as `fl edit <key> --value "text"`.
        value: argResults!['value'] as String? ??
            (rest.length > 1 ? rest[1] : null),
        isChecked: argResults!['checked'] as bool?,
        isPlaceholdersEnabled: placeholders == null ? null : true,
        placeholders: placeholders,
        description: argResults!['description'] as String?,
        // `--description ""` typed on purpose clears it.
        clearDescription: argResults!.wasParsed('description') &&
            (argResults!['description'] as String).isEmpty,
        isPluralEnabled: argResults!['plural'] as bool?,
        singularCase: argResults!['singular-case'] as String?,
        pluralCase: argResults!['plural-case'] as String?,
        zeroCase: argResults!['zero-case'] as String?,
        twoCase: argResults!['two-case'] as String?,
        fewCase: argResults!['few-case'] as String?,
        manyCase: argResults!['many-case'] as String?,
        pluralParam: argResults!['plural-param'] as String?,
        target: argResults!['target'] as String?,
        clear: argResults!['clear'] as bool,
        platforms: settings.platforms,
        maxLength: settings.maxLength,
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
    argParser.addFlag(
      'yes',
      abbr: 'y',
      negatable: false,
      help: 'Do not ask first (asked only at a terminal).',
    );
  }

  @override
  String get name => 'delete';
  @override
  String get description => 'Delete a key (all locales) or a single locale.';
  @override
  String get invocation => 'fl delete <key> [--locale <code>] [--yes]';

  @override
  Future<int> run() async {
    final String key = _requireKey(this);
    final String? locale = _locale(argResults!['locale'] as String?);
    final Prompter ask = Prompter(
        interactive: !(argResults!['yes'] as bool) &&
            !jsonOut &&
            !dryRun &&
            (stdin.hasTerminal ||
                Platform.environment['FL_INTERACTIVE'] == '1'));
    if (ask.interactive &&
        !ask.confirm(
            locale == null
                ? 'Delete "$key" in every locale? This cannot be undone.'
                : 'Delete the $locale text of "$key"?',
            fallback: false)) {
      stderr.writeln('Nothing deleted.');
      return 1;
    }
    final ({
      ManagementClient client,
      Operations ops,
      String projectName
    }) built = await build(loadProject());
    try {
      final OpResult r = await built.ops.delete(
        key,
        locale: locale,
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
    argParser.addOption('target',
        help: 'Translate the text of one target (e.g. ios) from the base '
            'language\'s: by default where it is missing or outdated.');
  }

  @override
  String get name => 'translate';
  @override
  String get description =>
      'AI-translate a key\'s locales (default: only missing).';
  @override
  String get invocation =>
      'fl translate <key> [--all | --locale fr --locale de] [--target ios]';

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
        target: argResults!['target'] as String?,
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
    argParser.addFlag('include-variants',
        negatable: false,
        help: 'Also send values that match the source in variants of the base '
            'language (en-GB, en-US for an en base). Skipped by default: '
            'there, matching the source is usually correct.');
    argParser.addFlag('changed',
        negatable: false,
        help: 'Also redo every value whose base text was changed after it was '
            'translated (`fl status` counts them). Off by default: the old '
            'translation is overwritten, reviewed or not.');
    argParser.addOption('target',
        help: 'Translate the texts of one target (e.g. ios) instead: every '
            'one the base language has and a locale is missing, or that is '
            'outdated.');
  }

  @override
  String get name => 'retranslate';
  @override
  String get description =>
      'AI-translate every empty value, and every unchecked value still identical '
      'to the source. With --changed, also every value whose base text changed '
      'since.';
  @override
  String get invocation =>
      'fl retranslate [--changed] [--locale ar --locale ru] '
      '[--accept-unchanged] [--include-variants] [--target ios]';

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
        includeVariants: argResults!['include-variants'] as bool,
        changed: argResults!['changed'] as bool,
        target: argResults!['target'] as String?,
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
      _reportWritten(r);
      _reportUnchanged(r);
      _reportFailures(r);
      _reportAcceptFailures(r);
      return r.ok ? 0 : 1;
    } finally {
      built.client.close();
    }
  }
}

/// Print what was written, each beside its source, so a run can be read
/// without exporting the files.
void _reportWritten(final OpResult r) {
  final List<dynamic> rows =
      (r.data['written'] as List<dynamic>?) ?? const <dynamic>[];
  if (rows.isEmpty) return;
  String short(final Object? text) {
    final String line = '$text'.replaceAll(RegExp(r'\s+'), ' ');
    return line.length > 80 ? '${line.substring(0, 79)}…' : line;
  }

  const int limit = 60;
  stdout.writeln('');
  for (final dynamic row in rows.take(limit)) {
    final Map<String, dynamic> m = row as Map<String, dynamic>;
    stdout.writeln('  ${m['locale']}  ${m['key']}: "${short(m['source'])}" '
        '-> "${short(m['value'])}"');
  }
  if (rows.length > limit) {
    stdout.writeln('  … and ${rows.length - limit} more (use --json for all).');
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

class ShortenCommand extends Command<int> with _ApiCommand {
  ShortenCommand() {
    argParser.addOption('target',
        help: 'Target to write a shorter text for, e.g. ios (default: the one '
            'target the keys have a max length for).');
    argParser.addMultiOption('locale',
        help: 'Also shorten in these locale(s); the base language always.');
  }

  @override
  String get name => 'shorten';
  @override
  String get description =>
      'Write, from the full text, a text that fits the max length of a target: '
      'for the keys named, or every key over the limit.';
  @override
  String get invocation =>
      'fl shorten [--target ios] [--locale fr] [<key> ...]';

  @override
  Future<int> run() async {
    final ({
      ManagementClient client,
      Operations ops,
      String projectName
    }) built = await build(loadProject());
    try {
      return emit(await built.ops.shorten(
        target: argResults!['target'] as String?,
        keys: argResults!.rest,
        locales: _locales(argResults!['locale'] as List<String>),
        dryRun: dryRun,
      ));
    } finally {
      built.client.close();
    }
  }
}

class StatusCommand extends Command<int> with _ApiCommand {
  @override
  String get name => 'status';
  @override
  String get description =>
      'Show completion % per locale, platform texts to check and texts over '
      'their max length.';

  @override
  Future<int> run() async {
    final ProjectConfig cfg = loadProject();
    final ({
      ManagementClient client,
      Operations ops,
      String projectName
    }) built = await build(cfg);
    try {
      OpResult r = await built.ops.status();
      final List<CatalogTarget>? targets = cfg.xcstringsCatalogs;
      final List<Map<String, dynamic>> catalogs = <Map<String, dynamic>>[];
      List<CatalogConflict> conflicts = <CatalogConflict>[];
      if (targets != null) {
        final ProjectData project =
            await built.client.getProject(built.ops.projectId);
        final Set<String> serviceKeys = <String>{
          for (final TranslationEntry t
              in project.baseLanguage(built.ops.flavor)?.translations ??
                  const <TranslationEntry>[])
            t.key,
        };
        for (final CatalogTarget t in targets) {
          final List<String> keys = <String>[
            for (final String k in catalogKeys(t.localizable.existsSync()
                ? _jsonOrNull(t.localizable.readAsStringSync())
                : null))
              if (k.isNotEmpty) k,
          ];
          catalogs.add(<String, dynamic>{
            'file': path.relative(t.localizable.path),
            'exists': t.localizable.existsSync(),
            'keys': keys.length,
            'not_on_service': <String>[
              for (final String k in keys)
                if (!serviceKeys.contains(k)) k,
            ],
          });
        }
        conflicts = catalogConflicts(targets);
        r = OpResult(r.ok, r.message, <String, dynamic>{
          ...r.data,
          'catalogs': catalogs,
          'catalog_conflicts': <Map<String, dynamic>>[
            for (final CatalogConflict c in conflicts) c.toJson(),
          ],
        });
      }
      if (jsonOut) return emit(r);
      stdout.writeln(r.message);
      var totalUntranslated = 0;
      var totalOutdated = 0;
      var totalToCheck = 0;
      final Map<String, int> totalOver = <String, int>{};
      for (final row in (r.data['locales'] as List)) {
        final Map<String, dynamic> m = row as Map<String, dynamic>;
        final String tag = (m['base'] as bool)
            ? ' (base)'
            : m['variant_of'] != null
                ? ' (variant of ${m['variant_of']})'
                : '';
        // Show the translated count, not the filled one: a row still holding
        // the source text is otherwise indistinguishable from a finished 100%.
        final int untranslated = (m['untranslated'] as int?) ?? 0;
        totalUntranslated += untranslated;
        final String gap = untranslated > 0
            ? '  ⚠ $untranslated not translated yet (still the source text): `fl retranslate`'
            : '';
        final int outdated = (m['outdated'] as int?) ?? 0;
        totalOutdated += outdated;
        final String old =
            outdated > 0 ? '  ⚠ $outdated translate an older base text' : '';
        final int toCheck = (m['platform_text_to_check'] as int?) ?? 0;
        totalToCheck += toCheck;
        final String check =
            toCheck > 0 ? '  ⚠ $toCheck platform text(s) to check' : '';
        final Map<String, dynamic> over =
            (m['over_limit'] as Map<String, dynamic>?) ?? <String, dynamic>{};
        over.forEach((final String t, final dynamic n) =>
            totalOver[t] = (totalOver[t] ?? 0) + (n as int));
        final String long = over.isEmpty
            ? ''
            : '  ⚠ over the limit: ${over.entries.map((final MapEntry<String, dynamic> e) => '${e.value} on ${e.key}').join(', ')}';
        stdout.writeln(
          '  ${m['locale']}$tag: ${m['translated'] ?? m['filled']}/${m['total']} '
          '(${m['translated_percent'] ?? m['percent']}%)$gap$old$check$long',
        );
      }
      if (catalogs.isNotEmpty) {
        stdout.writeln('\nString Catalogs:');
        for (final Map<String, dynamic> c in catalogs) {
          final int fresh = (c['not_on_service'] as List<String>).length;
          stdout.writeln(c['exists'] as bool
              ? '  ${c['file']}: ${c['keys']} key(s)'
                  '${fresh == 0 ? '' : ', $fresh not on the service yet (`fl pull --adopt`)'}'
              : '  ${c['file']}: missing');
        }
        if (conflicts.isNotEmpty) {
          stdout.writeln(
              '\n${describeCatalogConflicts(conflicts, shown: path.relative, refused: false)}');
        }
      }
      if (totalToCheck > 0) {
        stdout.writeln(
            '\n$totalToCheck platform text(s) were written for a full text or '
            'a base text that has changed since: `fl retranslate --target '
            '<target>` redoes the outdated ones, `fl edit <key> --target '
            '<target>` rewrites one.');
      }
      for (final MapEntry<String, int> e in totalOver.entries) {
        stdout.writeln('\n${e.value} text(s) are longer than the ${e.key} '
            'limit: `fl shorten --target ${e.key}` writes ones that fit.');
      }
      if (totalOutdated > 0) {
        stdout.writeln(
            '\n$totalOutdated value(s) were translated before their base text '
            'changed. Run `fl retranslate --changed` to redo them.');
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
            '  ${m['locale']}$tag: ${m['filled']}/${m['keys']} filled'
            '${m['here'] == false ? '  (not shipped by this repository)' : ''}');
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
          'this same request. Keys added later are not translated by '
          'themselves: import them with `fl import <file> --translate`.',
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
    final ProjectConfig cfg = loadProject();
    final ({
      ManagementClient client,
      Operations ops,
      String projectName
    }) built = await build(cfg);
    try {
      // A repository keeping to some of the project's languages takes the
      // ones added from it.
      final ProjectData before =
          await built.client.getProject(built.ops.projectId);
      final Set<String>? held = before.repoProblem != null
          ? null
          : resolveRepoLocales(cfg, before, before.flavor(built.ops.flavor))
              .held;
      final OpResult r = await built.ops.addLanguages(
        _locales(splitLocaleArgs(rest)),
        autoTranslate: argResults!['auto-translate'] as bool,
        dryRun: dryRun,
      );
      if (!dryRun) {
        final List<String> added = pinAddedLocales(
            cfg, held, r.data['results'] as List<dynamic>?,
            configPath: globalResults?['config'] as String?);
        if (added.isNotEmpty) {
          stderr.writeln('Listed ${added.join(', ')} under "locales" in '
              '$kProjectConfigName: this repository ships '
              '${added.length == 1 ? 'it' : 'them'}.');
        }
      }
      if (jsonOut) return emit(r);
      // A real run already printed each locale as it landed.
      if (dryRun) {
        for (final dynamic row
            in (r.data['results'] as List<dynamic>?) ?? const <dynamic>[]) {
          final Map<String, dynamic> m = row as Map<String, dynamic>;
          stdout.writeln('  ${m['ok'] == true ? '✓' : '✗'} ${m['locale']}  '
              '${m['message'] ?? ''}');
        }
      }
      stdout.writeln(r.message);
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

/// Clone the linked ARB repo for `arb_dir`, the first-run counterpart to
/// `pull`, which only works once the repo is already on disk.
///
/// The backend keeps one folder per flavor at the repo root (Default/,
/// staging/) and `arb_dir` points at one of them, so the clone goes into
/// the folder above it. `pull` runs git from inside `arb_dir`, which finds
/// the same clone.
class CloneCommand extends Command<int> with _ApiCommand {
  @override
  String get name => 'clone';
  @override
  String get description =>
      'Clone the ARB repo so arb_dir is its flavor folder (first-time setup; '
      'then use `pull`).';
  @override
  String get invocation => 'fl clone [<dir>]';

  @override
  Future<int> run() async {
    final ProjectConfig cfg = loadProject();
    final List<String> rest = argResults!.rest;

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
    final String arbDir = cfg.arbDir ?? 'arbs';
    final String folder = path.basename(arbDir).toLowerCase();
    final bool flavorFolder =
        p.flavors.any((final FlavorData f) => f.name.toLowerCase() == folder);
    final String dir = rest.isNotEmpty
        ? rest.first
        : flavorFolder
            ? path.dirname(arbDir)
            : arbDir;
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
    final CloneOutcome outcome = await cloneRepo(repo.url, dir);
    if (!outcome.ok) {
      for (final ({String url, int exitCode, String output}) a
          in outcome.attempts) {
        stderr.writeln('git clone ${redactCredentials(a.url)} failed:');
        stderr.writeln(tail(a.output, lines: 5));
      }
      final String? ssh = sshFormOf(repo.url);
      stderr.writeln(looksLikeAccessDenied(outcome.attempts.last.output)
          ? 'Hint: git has no credential that can read this repo. Sign git in '
              'to ${repo.provider} (a credential helper for https'
              '${ssh == null ? '' : ', or an SSH key for $ssh'}), or run '
              '`fl pull --no-git`, which writes the files from the API with '
              'your fl token.'
          : 'Hint: `fl pull --no-git` writes the files from the API without '
              'git.');
      return outcome.attempts.last.exitCode;
    }
    if (outcome.url != repo.url) {
      stdout.writeln('https was refused; cloned over SSH from ${outcome.url}.');
    }
    if (rest.isEmpty && flavorFolder && !Directory(arbDir).existsSync()) {
      stderr.writeln('Warning: the repo has no ${path.basename(arbDir)}/ '
          'folder yet, which arb_dir ($arbDir) points at.');
    }
    final String? root = cfg.root;
    final String shown = root != null && path.isWithin(root, dir)
        ? path.relative(dir, from: root)
        : dir;
    stdout.writeln(
        '✓ Cloned. Add "/$shown/" to .gitignore: the backend owns it.');
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
        help: 'Skip the git mirror and write the files straight from the API.',
      )
      // What `fl init` runs: it asks about local-only keys itself.
      ..addFlag('from-init', negatable: false, hide: true);
  }

  @override
  String get name => 'pull';
  @override
  String get description =>
      'Sync arb_dir (and the String Catalogs of an iOS project) with the '
      'service: git mirror if there is one, API otherwise. Never needs a git '
      'command.';

  @override
  Future<int> run() async => _pullArbs(
        this,
        adopt: argResults!['adopt'] as bool,
        discardLocal: argResults!['discard-local'] as bool,
        noGit: argResults!['no-git'] as bool,
        fromInit: argResults!['from-init'] as bool,
      );
}

/// What [_pullArbs] answers to `fl init` when local-only keys stopped it.
/// Never an exit code.
const int _kLocalOnlyKeys = -1;

/// Bring `arb_dir` to exactly what the service holds.
///
/// Shared by `fl pull` and `fl sync` so there is one definition of "in sync"
/// and one place where the local-only-key guard lives. [fromInit] names the
/// local-only keys without the two-command advice: the wizard asks instead.
Future<int> _pullArbs(
  final _ApiCommand cmd, {
  final bool adopt = false,
  final bool discardLocal = false,
  final bool noGit = false,
  final bool fromInit = false,
}) async {
  final ProjectConfig cfg = cmd.loadProject();
  final String arbDir = cfg.arbDir ?? '.';
  final String catalogDir = cfg.catalogDir;
  final List<CatalogTarget>? targets = cfg.xcstringsCatalogs;

  final ({ManagementClient client, Operations ops, String projectName}) built =
      await cmd.build(cfg);
  try {
    final ProjectData project =
        await built.client.getProject(built.ops.projectId);
    if (project.repoProblem != null) {
      stderr.writeln(project.repoProblem);
      return 1;
    }
    final LanguageData? base = project.baseLanguage(built.ops.flavor);
    if (base == null) {
      stderr.writeln('Project "${project.name}" has no base language.');
      return 1;
    }
    // An iOS-only project has no ARBs anywhere, so its "directory" is the
    // one holding the catalog; in a mixed project both sit in one clone.
    final String dir = project.shipsFlutter ? arbDir : catalogDir;
    final String templateName = 'app_${base.code.replaceAll('-', '_')}.arb';
    final File template = File('$arbDir/$templateName');
    final File catalog = File('$catalogDir/$kLocalizableCatalog');
    final Set<String> serviceKeys = <String>{
      for (final TranslationEntry t in base.translations)
        if (t.key.isNotEmpty) t.key,
    };
    // A key two catalogs give two texts would come back with the service's
    // one text in both, or be imported with whichever was read first.
    if (project.shipsIos && targets != null && !discardLocal) {
      final int? refused = _refuseConflicts(cmd, targets);
      if (refused != null) return refused;
    }

    // Checked before anything reads the files: a clone of the old repo
    // holds the old repo's keys, and offering to adopt them would import
    // strings from a repository the project left.
    final GitMirror mirror = GitMirror(dir);
    final GitRepository? linked = project.repository;
    // The mirror holds the ARBs and the one catalog the service writes; an
    // app that cuts the catalog into several is written from the API, and so
    // is an Angular app, whose files live in the app's own repository.
    final bool mirrorHasFiles =
        project.shipsFlutter || (project.shipsIos && targets == null);
    final bool skipGit = noGit || !mirrorHasFiles;
    final ({String name, String url, String root})? local =
        skipGit || linked == null ? null : await mirror.remote();
    final bool appRepo = local != null &&
        _contains(local.root, cfg.root ?? Directory.current.path);
    // Relinking the project in the dashboard leaves the old clone behind,
    // and it would go on syncing fine from a repo nobody pushes to.
    if (local != null && !appRepo && !sameRepo(local.url, linked!.url)) {
      final String fix =
          'git -C ${local.root} remote set-url ${local.name} ${linked.url}';
      if (cmd.jsonOut) {
        stdout.writeln(const JsonEncoder.withIndent('  ').convert(
          <String, dynamic>{
            'ok': false,
            'error': 'repo_mismatch',
            'dir': dir,
            'clone': local.root,
            'local_origin': redactCredentials(local.url),
            'project_repo': linked.url,
            'fix': fix,
          },
        ));
      } else {
        stderr.writeln('Error: the clone in ${local.root} pulls from\n'
            '  ${redactCredentials(local.url)}\n'
            'but "${project.name}" is now linked to\n'
            '  ${linked.url}\n'
            'Nothing was pulled. Point the clone at the new repo:\n'
            '  $fix\n'
            'or delete ${local.root} and run `fl clone`. `fl pull --no-git` '
            'writes the files from the API meanwhile.');
      }
      return 1;
    }

    // The one thing a sync must not do quietly: both refresh paths rewrite
    // the files from the service, so a key staged on disk and never
    // imported would disappear. Stop, name them, and offer both answers.
    // Each platform's file is checked on its own; the catalog is the only
    // place an iOS developer's new key can be.
    final List<String> orphans = project.shipsFlutter
        ? localOnlyKeys(template, serviceKeys)
        : <String>[];
    final List<String> catalogOrphans = !project.shipsIos
        ? <String>[]
        : targets != null
            ? localOnlyTargetKeys(targets, serviceKeys)
            : localOnlyCatalogKeys(catalog, serviceKeys);
    final String catalogName = targets == null
        ? kLocalizableCatalog
        : 'The ${targets.length} catalogs of "xcstrings_catalogs"';
    // ngx-translate's base file is written by the pull like a Flutter
    // template, so a key only it holds is at risk the same way.
    final String ngxDir = cfg.ngxLocaleDir;
    final File ngxBase = File('$ngxDir/${ngxFileName(base.code)}');
    final List<String> ngxOrphans =
        project.shipsNgx ? localOnlyNgxKeys(ngxBase, serviceKeys) : <String>[];
    final String ngxBaseName = path.relative(ngxBase.path);
    final List<({String file, List<String> keys})> staged =
        <({String file, List<String> keys})>[
      if (orphans.isNotEmpty) (file: templateName, keys: orphans),
      if (catalogOrphans.isNotEmpty) (file: catalogName, keys: catalogOrphans),
      if (ngxOrphans.isNotEmpty) (file: ngxBaseName, keys: ngxOrphans),
    ];
    if (staged.isNotEmpty && !adopt && !discardLocal && fromInit) {
      for (final ({String file, List<String> keys}) entry in staged) {
        stdout.writeln(
            '${entry.file} ${entry.file.startsWith('The ') ? 'have' : 'has'} '
            '${entry.keys.length} key(s) the service does not have yet.');
      }
      return _kLocalOnlyKeys;
    }
    if (staged.isNotEmpty && !adopt && !discardLocal) {
      for (final ({String file, List<String> keys}) entry in staged) {
        stderr.writeln(
            '${entry.file} ${entry.file.startsWith('The ') ? 'have' : 'has'} '
            '${entry.keys.length} key(s) the service does not have yet:');
        for (final String k in entry.keys.take(20)) {
          stderr.writeln('  $k');
        }
        if (entry.keys.length > 20) {
          stderr.writeln('  … and ${entry.keys.length - 20} more.');
        }
      }
      stderr.writeln('Syncing would overwrite the file and lose them. Either:\n'
          '  fl pull --adopt           import them first, then sync\n'
          '  fl pull --discard-local   drop them and take the service copy');
      return 1;
    }
    // With --json stdout carries the object and nothing else, so a script
    // can pipe it straight into a parser.
    final IOSink say = cmd.jsonOut ? stderr : stdout;

    // Angular's source file is the developer's and a pull never writes it, so
    // strings only it holds are not at risk: they are named, or imported
    // with --adopt, but they never stop the pull.
    final String angularDir = cfg.angularLocaleDir;
    final File angularSource = File('$angularDir/$kAngularSource');
    if (project.shipsAngular && angularSource.existsSync()) {
      final Map<String, dynamic> extracted =
          jsonDecode(angularSource.readAsStringSync()) as Map<String, dynamic>;
      final Set<String> refused = <String>{
        for (final String problem in angularImportProblems(extracted))
          problem.split(':').first,
      };
      final List<String> fresh = <String>[
        // An id that is all digits is Angular's hash of the text: the service
        // never takes one, whatever the message.
        for (final String k in localOnlyKeys(angularSource, serviceKeys))
          if (!refused.contains(k) && !RegExp(r'^\d+$').hasMatch(k)) k,
      ];
      if (fresh.isNotEmpty && adopt && !cmd.dryRun) {
        say.writeln('Importing ${fresh.length} new string(s) from '
            '${path.relative(angularSource.path)} …');
        final OpResult imported = await built.ops.importArb(
            angularSource.readAsStringSync(),
            fileName: kAngularSource);
        if (!imported.ok) {
          stderr.writeln(imported.message);
          return 1;
        }
        say.writeln('  ${imported.message.replaceAll('\n', '\n  ')}');
      } else if (fresh.isNotEmpty) {
        final String shown = path.relative(angularSource.path);
        say.writeln('$shown has ${fresh.length} string(s) the service does '
            'not have yet (${fresh.take(5).join(', ')}'
            '${fresh.length > 5 ? ', …' : ''}). Import them with '
            '`fl import $shown --translate` or `fl pull --adopt`.');
      }
    }

    if (staged.isNotEmpty && adopt) {
      if (cmd.dryRun) {
        stdout.writeln(
            'DRY RUN: would import ${staged.map((final e) => e.keys.length).reduce((final a, final b) => a + b)} '
            'local-only key(s) before syncing.');
      } else {
        if (orphans.isNotEmpty) {
          say.writeln('Importing ${orphans.length} local-only key(s) from '
              '$templateName …');
          final OpResult imported = await built.ops.adoptArbs(template);
          if (!imported.ok) {
            stderr.writeln(imported.message);
            return 1;
          }
          say.writeln('  ${imported.message.replaceAll('\n', '\n  ')}');
        }
        if (catalogOrphans.isNotEmpty) {
          say.writeln('Importing ${catalogOrphans.length} local-only key(s) '
              'from ${targets == null ? kLocalizableCatalog : 'the catalogs'} …');
          final OpResult imported = await built.ops.adoptCatalog(
            targets == null
                ? catalog.readAsStringSync()
                : jsonEncode(mergeTargetCatalogs(targets,
                    sourceLanguage: base.code, only: catalogOrphans.toSet())),
            fileName: kLocalizableCatalog,
          );
          if (!imported.ok) {
            stderr.writeln(imported.message);
            return 1;
          }
          say.writeln('  ${imported.message.replaceAll('\n', '\n  ')}');
        }
        if (ngxOrphans.isNotEmpty) {
          say.writeln('Importing ${ngxOrphans.length} local-only key(s) from '
              '$ngxBaseName …');
          final OpResult imported = await built.ops.importArb(
            ngxBase.readAsStringSync(),
            languageCode: base.code,
            fileName: path.basename(ngxBase.path),
          );
          if (!imported.ok) {
            stderr.writeln(imported.message);
            return 1;
          }
          say.writeln('  ${imported.message.replaceAll('\n', '\n  ')}');
        }
      }
    }

    if (cmd.dryRun) {
      stdout.writeln('DRY RUN: would sync "$dir" to the service.');
      if (project.shipsIos && targets != null) {
        final OpResult plan = await built.ops.exportCatalogs(catalogDir,
            dryRun: true, fetched: project, targets: targets);
        stdout.writeln(plan.message);
        _printFiles(plan);
      }
      return 0;
    }

    // Git when it can deliver, API when it cannot. Same outcome either way,
    // which is why the fallback is silent enough to be routine and loud
    // enough to explain itself.
    if (!skipGit) {
      final GitSyncOutcome outcome = await mirror.syncMirrorOf(
        linked?.url,
        appRoot: cfg.root ?? Directory.current.path,
      );
      if (outcome.ok) {
        say.writeln('✓ Synced "$dir" to ${outcome.upstream}.');
        if (outcome.discardedAnything) {
          final List<String> what = <String>[
            if (outcome.discardedWorkingChanges) 'local edits',
            if (outcome.discardedLocalCommits > 0)
              '${outcome.discardedLocalCommits} local commit(s)',
          ];
          say.writeln(
              '  Discarded ${what.join(' and ')} — the backend owns this '
              'directory.');
          if (outcome.recoveryRef != null) {
            say.writeln('  Recover with: git -C $dir show '
                '${outcome.recoveryRef}');
          }
        }
        if (project.shipsNgx) {
          final OpResult ngxFiles = await built.ops
              .exportNgx(ngxDir, keepLocalOnly: ngxOrphans.isNotEmpty && adopt);
          if (!ngxFiles.ok) {
            stderr.writeln(ngxFiles.message);
            return 1;
          }
          say.writeln('✓ ${ngxFiles.message}');
        }
        OpResult? angularFiles;
        if (project.shipsAngular) {
          angularFiles = await built.ops.exportAngular(angularDir,
              appRoot: cfg.root ?? Directory.current.path);
          if (!angularFiles.ok) {
            stderr.writeln(angularFiles.message);
            return 1;
          }
          say.writeln('✓ ${angularFiles.message}');
        }
        if (cmd.jsonOut) {
          stdout.writeln(
            const JsonEncoder.withIndent('  ').convert(
              <String, dynamic>{
                'ok': true,
                if (angularFiles != null) ...angularFiles.data,
                'method': ArbSyncMethod.git.name,
                'dir': dir,
                'upstream': outcome.upstream,
                'adopted': adopt
                    ? <String>[...orphans, ...catalogOrphans, ...ngxOrphans]
                    : <String>[],
              },
            ),
          );
        }
        return 0;
      }
      say.writeln('Git mirror unavailable (${_skipReason(outcome)}) — '
          'writing the files from the API instead.');
    }

    final OpResult r = await _exportFromApi(
      built.ops,
      project,
      arbDir: arbDir,
      catalogDir: catalogDir,
      angularDir: angularDir,
      ngxDir: ngxDir,
      appRoot: cfg.root ?? Directory.current.path,
      targets: targets,
      stale: (staged.isNotEmpty || project.shipsAngular) && adopt,
      // The import above took what it could; the rest it refused.
      ngxKeepLocalOnly: ngxOrphans.isNotEmpty && adopt,
    );
    if (cmd.jsonOut) {
      return cmd.emit(
        OpResult(
          r.ok,
          r.message,
          <String, dynamic>{
            ...r.data,
            'method': ArbSyncMethod.api.name,
            'adopted': adopt
                ? <String>[...orphans, ...catalogOrphans, ...ngxOrphans]
                : <String>[],
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

/// Refuses, with every key and file named, when [targets] declare a key
/// with two texts. Null when there is none.
int? _refuseConflicts(
  final _ApiCommand cmd,
  final List<CatalogTarget> targets, {
  final Set<String>? only,
}) {
  final List<CatalogConflict> conflicts = catalogConflicts(targets, only: only);
  if (conflicts.isEmpty) return null;
  final String message =
      describeCatalogConflicts(conflicts, shown: path.relative);
  if (cmd.jsonOut) {
    return cmd.emit(OpResult(false, message, <String, dynamic>{
      'error': 'catalog_conflicts',
      'conflicts': <Map<String, dynamic>>[
        for (final CatalogConflict c in conflicts) c.toJson(),
      ],
    }));
  }
  stderr.writeln(message);
  return 1;
}

/// The files of an export, one line each.
void _printFiles(final OpResult r) {
  for (final dynamic row
      in (r.data['files'] as List<dynamic>?) ?? const <dynamic>[]) {
    final Map<String, dynamic> m = row as Map<String, dynamic>;
    stdout.writeln('  ${m['file']}  ${m['keys']} key(s)'
        '${m['base'] == true ? '  (template)' : ''}');
  }
}

Object? _jsonOrNull(final String content) {
  try {
    return jsonDecode(content);
  } on FormatException {
    return null;
  }
}

/// Every file the project ships, written from the API: ARBs for Flutter,
/// String Catalogs for iOS, both for a project that has both.
Future<OpResult> _exportFromApi(
  final Operations ops,
  final ProjectData project, {
  required final String arbDir,
  required final String catalogDir,
  required final String angularDir,
  required final String ngxDir,
  final String? appRoot,
  final List<CatalogTarget>? targets,
  final bool dryRun = false,
  final bool stale = false,
  final bool ngxKeepLocalOnly = false,
}) async {
  // [project] is what the caller just fetched; asking again downloaded every
  // translation a second time. [stale] says an import ran since.
  if (project.repoProblem != null) return OpResult(false, project.repoProblem!);
  final ProjectData? fetched = stale ? null : project;
  final List<OpResult> results = <OpResult>[
    for (final AppPlatform platform in project.localPlatforms)
      switch (platform) {
        AppPlatform.flutter =>
          await ops.exportArbs(arbDir, dryRun: dryRun, fetched: fetched),
        AppPlatform.ios => await ops.exportCatalogs(catalogDir,
            dryRun: dryRun, fetched: fetched, targets: targets),
        AppPlatform.angular => await ops.exportAngular(angularDir,
            dryRun: dryRun, fetched: fetched, appRoot: appRoot),
        AppPlatform.ngx => await ops.exportNgx(ngxDir,
            dryRun: dryRun, fetched: fetched, keepLocalOnly: ngxKeepLocalOnly),
      },
  ];
  final OpResult? failed = results
      .cast<OpResult?>()
      .firstWhere((final OpResult? r) => !r!.ok, orElse: () => null);
  if (failed != null) return failed;
  return OpResult(
    true,
    results.map((final OpResult r) => r.message).join('\n'),
    <String, dynamic>{
      'files': <dynamic>[
        for (final OpResult r in results)
          ...?(r.data['files'] as List<dynamic>?),
      ],
      if (project.shipsFlutter) 'template': results.first.data['template'],
      if (project.shipsFlutter) 'dir': arbDir,
      if (project.shipsIos) 'catalog_dir': catalogDir,
      if (project.shipsAngular) 'angular_dir': angularDir,
      if (project.shipsNgx) 'ngx_dir': ngxDir,
    },
  );
}

/// Whether [dir] is [other] or one of its ancestors, symlinks resolved.
bool _contains(final String dir, final String other) {
  try {
    final String a = Directory(dir).resolveSymbolicLinksSync();
    final String b = Directory(other).resolveSymbolicLinksSync();
    return path.equals(a, b) || path.isWithin(a, b);
  } on FileSystemException {
    return false;
  }
}

String _skipReason(final GitSyncOutcome o) => switch (o.skip) {
      GitSkipReason.gitMissing => 'no git on PATH',
      GitSkipReason.notARepo => o.detail.isEmpty ? 'not a git clone' : o.detail,
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
      'Import an ARB or String Catalog (optional), sync arb_dir, then '
      'regenerate the Dart (Flutter), the whole flow in one command. With '
      '"ios_permission_keys" in flutterlocalisation.json it ends with '
      '`fl native`.';
  @override
  String get invocation => 'fl sync [<file.arb|file.xcstrings>]';

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
          fileName: file.uri.pathSegments.last,
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
    final ({
      ManagementClient client,
      Operations ops,
      String projectName
    }) target = await build(cfg);
    try {
      final ProjectData project =
          await target.client.getProject(target.ops.projectId);
      // Xcode compiles the catalog itself; there is no Dart to regenerate.
      if (!project.shipsFlutter) return 0;
    } finally {
      target.client.close();
    }

    final int gen = await _regenerateDart(cfg,
        skipHint: 'Re-run with --no-codegen to skip this step.');
    if (gen != 0) return gen;
    // A project that keeps its iOS permission alerts in translation keys has
    // one more thing fed by the ARBs.
    if (cfg.iosPermissionKeys != null) {
      final NativeSyncPlan plan;
      try {
        plan = planNativeSync(
          Directory(cfg.root ?? Directory.current.path),
          arbDir: cfg.arbDir,
          permissionKeys: cfg.iosPermissionKeys,
        );
      } on StateError catch (e) {
        stderr.writeln(e.message);
        return 1;
      }
      final int changed = applyNativeSync(plan).length;
      stdout.writeln(changed == 0
          ? 'Native locale declarations and iOS permission alerts are current.'
          : 'Updated $changed native file(s): locale declarations and iOS '
              'permission alerts.');
      for (final String note in plan.notes) {
        stdout.writeln('  ! $note');
      }
      stdout.writeln('✓ In sync: service → ARBs → Dart → native.');
      return 0;
    }
    stdout.writeln('✓ In sync: service → ARBs → Dart.');
    return 0;
  }
}

/// Run the flutter_localisation generator over `arb_dir`.
///
/// Shared by `fl sync` and `fl init`; both end with the Dart matching the ARBs.
/// [skipHint] is the last line of a failure: how to get past it.
Future<int> _regenerateDart(final ProjectConfig cfg,
    {required final String skipHint}) async {
  final String projectRoot = cfg.root ?? Directory.current.path;
  final Directory rootDir = Directory(projectRoot);
  if (usesPlainGenL10n(rootDir)) return _runGenL10n(projectRoot);
  final ({String flavorsFolder, String flavor}) target =
      generatorTarget(cfg.arbDir ?? 'arbs/Default', projectRoot);
  if (lacksGenerateFlag(rootDir)) {
    stderr.writeln('Warning: pubspec.yaml has no `generate: true` under '
        '`flutter:`, so gen-l10n may refuse to run. `fl doctor --fix` adds it.');
  }
  stdout.writeln(
      'Regenerating Dart from ${target.flavorsFolder}/${target.flavor} …');
  final ProcessResult gen = await Process.run(
    'dart',
    <String>[
      'run',
      'flutter_localisation',
      target.flavorsFolder,
      target.flavor
    ],
    workingDirectory: projectRoot,
  );
  if (gen.exitCode != 0) {
    // The generator logs its errors to stdout as often as to stderr.
    final String output = tail('${gen.stdout}\n${gen.stderr}');
    stderr.writeln('Codegen failed (exit ${gen.exitCode}) in $projectRoot:');
    if (output.isNotEmpty) stderr.writeln(output);
    if (!dependsOn(rootDir, 'flutter_localisation')) {
      stderr.writeln('pubspec.yaml does not list flutter_localisation; add it '
          'with `flutter pub add flutter_localisation`.');
    }
    stderr.writeln(skipHint);
    return gen.exitCode;
  }
  stdout.write(gen.stdout);
  return 0;
}

/// An app that reads its ARBs with Flutter's own gen-l10n and does not use the
/// flutter_localisation package: its generator is `flutter gen-l10n`.
Future<int> _runGenL10n(final String projectRoot) async {
  stdout.writeln('Regenerating Dart with `flutter gen-l10n` …');
  const String missing = '`flutter` is not on the PATH here. The ARB files are '
      'up to date; run `flutter gen-l10n` where Flutter is installed.';
  // On Windows flutter is a .bat that only a shell can start, and a shell
  // answers a missing command with an exit code, not an exception.
  if (Platform.isWindows &&
      (await Process.run('where', <String>['flutter'], runInShell: true))
              .exitCode !=
          0) {
    stdout.writeln(missing);
    return 0;
  }
  final ProcessResult gen;
  try {
    gen = await Process.run('flutter', <String>['gen-l10n'],
        workingDirectory: projectRoot, runInShell: Platform.isWindows);
  } on ProcessException {
    stdout.writeln(missing);
    return 0;
  }
  if (gen.exitCode != 0) {
    final String output = tail('${gen.stdout}\n${gen.stderr}');
    stderr.writeln('`flutter gen-l10n` failed (exit ${gen.exitCode}) in '
        '$projectRoot:');
    if (output.isNotEmpty) stderr.writeln(output);
    return gen.exitCode;
  }
  return 0;
}

/// Install the guard so AI agents cannot hand-edit the
/// FlutterLocalisation-managed files (the ARB repo + generated Dart). Purely
/// local: `.claude/settings.json` deny rules for Claude Code, a
/// `.github/hooks` hook for GitHub Copilot, and the guidance docs.
class GuardCommand extends Command<int> {
  bool get _jsonOut => (globalResults?['json'] as bool?) ?? false;
  bool get _dryRun => (globalResults?['dry-run'] as bool?) ?? false;

  @override
  String get name => 'guard';
  @override
  String get description =>
      'Protect ARBs + generated Dart from AI edits: Claude Code deny rules, a '
      'GitHub Copilot hook and AI-guidance docs (AGENTS.md, CLAUDE.md, '
      '.github/copilot-instructions.md).';
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
        for (final String g in globs) 'Edit($g)',
      ];
      if (_jsonOut) {
        stdout.writeln(
          const JsonEncoder.withIndent('  ').convert(
            <String, dynamic>{
              'dryRun': true,
              'protected': globs,
              'rules': rules,
              'copilot': <String>[
                kCopilotHookFile,
                kCopilotHookSh,
                kCopilotHookPs1,
              ],
              'docs': kAgentDocFiles,
            },
          ),
        );
      } else {
        stdout.writeln('DRY RUN: would deny AI edits to:');
        for (final String g in globs) {
          stdout.writeln('  · $g');
        }
        stdout.writeln('in ${root.path}/.claude/settings.json (Claude Code)');
        stdout.writeln('and ${root.path}/$kCopilotHookFile (GitHub Copilot)');
        stdout.writeln(
            'and write AI-guidance docs: ${kAgentDocFiles.join(', ')}');
      }
      return 0;
    }

    final GuardResult r = installGuard(root, globs: globs);
    final CopilotGuardResult copilot = installCopilotGuard(root, globs: globs);
    final AgentDocsResult docs =
        installAgentDocs(root, projectLabel: projectLabel, globs: globs);
    if (_jsonOut) {
      stdout.writeln(
        const JsonEncoder.withIndent('  ').convert(
          <String, dynamic>{
            ...r.toJson(),
            ...copilot.toJson(),
            ...docs.toJson(),
          },
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
      stdout.writeln('  Protected from AI edits:');
      for (final String g in r.protected) {
        stdout.writeln('    · $g');
      }
    }
    stdout.writeln(copilot.created.isEmpty
        ? '✓ Updated the GitHub Copilot hook → ${root.path}/$kCopilotHookFile'
        : '✓ Wrote the GitHub Copilot hook → ${root.path}/$kCopilotHookFile');
    for (final String path in docs.files) {
      stdout.writeln(docs.created.contains(path)
          ? '✓ Wrote AI guidance → $path'
          : '✓ Updated AI guidance → $path');
    }
    return 0;
  }
}

/// `fl doctor`: the gen-l10n setup that stops building after a Flutter upgrade.
class DoctorCommand extends Command<int> {
  DoctorCommand() {
    argParser.addFlag(
      'fix',
      negatable: false,
      help: 'Rewrite l10n.yaml, pubspec.yaml and the imports.',
    );
  }

  bool get _jsonOut => (globalResults?['json'] as bool?) ?? false;

  @override
  String get name => 'doctor';
  @override
  String get description =>
      'Flutter only: check l10n.yaml, pubspec.yaml and imports against current Flutter '
      '(synthetic-package, generate: true, package:flutter_gen).';
  @override
  String get invocation => 'fl doctor [--fix]';

  @override
  Future<int> run() async {
    final bool fix = argResults!['fix'] as bool;
    final String root = Directory.current.path;
    final List<AppPlatform>? pinned = pinnedPlatformsAt(root);
    final L10nDoctorReport r = holdsPlatform(pinned, AppPlatform.flutter)
        ? checkL10nSetup(Directory.current, fix: fix)
        : L10nDoctorReport(<L10nIssue>[], applicable: false);
    final bool angularApp = holdsPlatform(pinned, AppPlatform.angular) &&
        looksLikeLocalizeApp(root);
    if (!angularApp &&
        holdsPlatform(pinned, AppPlatform.ngx) &&
        usesNgxTranslate(root) &&
        !_jsonOut) {
      stdout.writeln('✓ ngx-translate app: its <locale>.json files need no '
          'build setup.');
      if (!r.applicable) return 0;
    }
    final List<String> angularIssues = angularApp
        ? angularSetupIssues(root, _angularDirHere(root))
        : const <String>[];
    if (_jsonOut) {
      stdout
          .writeln(const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
        ...r.toJson(),
        if (angularApp) 'angular': <String, dynamic>{'issues': angularIssues},
      }));
      return r.ok && angularIssues.isEmpty ? 0 : 1;
    }
    if (angularApp) {
      if (angularIssues.isEmpty) {
        stdout.writeln('✓ Angular i18n setup is in place.');
      } else {
        for (final String i in angularIssues) {
          stdout.writeln('✗ $i');
        }
      }
      if (!r.applicable) return angularIssues.isEmpty ? 0 : 1;
    }
    if (!r.applicable) {
      stdout.writeln('No l10n.yaml and no package:flutter_gen import here.');
      return 0;
    }
    if (r.issues.isEmpty) {
      stdout.writeln('✓ gen-l10n setup is current.');
      return 0;
    }
    for (final L10nIssue i in r.issues) {
      stdout.writeln('${i.fixed ? '✓ fixed' : '✗'} ${i.file}: ${i.message}');
    }
    if (r.ok) {
      stdout
          .writeln('Run flutter gen-l10n (or flutter pub get) to regenerate.');
      return 0;
    }
    if (!fix && r.issues.any((final L10nIssue i) => i.fixable)) {
      stdout.writeln('Run fl doctor --fix to apply the fixable ones.');
    }
    return 1;
  }
}

/// `angular_dir` from the config here if there is one, else where
/// `ng extract-i18n` writes, else Angular's default.
String _angularDirHere(final String root) {
  try {
    final ProjectConfig cfg = ProjectConfig.load();
    if (cfg.angularDir != null) {
      return path.relative(cfg.angularDir!, from: root);
    }
  } on ConfigException {
    // No config yet: doctor works before `fl init`.
  }
  return angularExtractDir(root) ?? kAngularDefaultDir;
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
    Map<String, String>? permissionKeys;
    try {
      final ProjectConfig cfg =
          ProjectConfig.load(path: globalResults?['config'] as String?);
      arbDir = cfg.arbDir;
      permissionKeys = cfg.iosPermissionKeys;
    } on ConfigException catch (e) {
      // A config that is there and wrong is said; a missing one is fine:
      // locales come from the generated Dart, and this command has nothing to
      // say to the backend.
      if (e.message.contains('ios_permission_keys')) {
        stderr.writeln('Error: ${e.message}');
        return 1;
      }
    } on Object {
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
      // The starter is for a project that keeps its sentences in the file.
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
      plan =
          planNativeSync(root, arbDir: arbDir, permissionKeys: permissionKeys);
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

/// `--platforms` and `--max-length`, the settings of a key.
void _addKeySettingOptions(final ArgParser parser) {
  parser.addOption('platforms',
      help: 'Platforms the key ships to, e.g. ios,angular; "all" for every '
          'platform of the project (the default).');
  parser.addMultiOption('max-length',
      help: 'Longest text of a target in characters, e.g. ios=40 '
          '(repeatable; 0 removes the limit).');
}

({List<String>? platforms, Map<String, int>? maxLength}) _keySettings(
    final ArgResults args) {
  final List<String> limits = args['max-length'] as List<String>;
  return (
    platforms: args.wasParsed('platforms')
        ? parsePlatformList(<String>[args['platforms'] as String])
        : null,
    maxLength: limits.isEmpty ? null : parseMaxLengths(limits),
  );
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
    argParser.addFlag(
      'discard-local',
      negatable: false,
      help: 'Write even though the template holds keys the service does '
          'not have (they are lost).',
    );
  }

  @override
  String get name => 'export';
  @override
  String get description =>
      'Write every locale straight from the API: app_<locale>.arb files in '
      'arb_dir for Flutter, Localizable.xcstrings in xcstrings_dir for iOS, '
      'messages.<locale>.arb in angular_dir for Angular. '
      'Use when the git repo is not linked (otherwise prefer `pull`).';
  @override
  String get invocation => 'fl export [<dir>]';

  @override
  Future<int> run() async {
    final ProjectConfig cfg = loadProject();
    final String? positional =
        argResults!.rest.isNotEmpty ? argResults!.rest.first : null;
    final ({
      ManagementClient client,
      Operations ops,
      String projectName
    }) built = await build(cfg);
    try {
      final ProjectData project =
          await built.client.getProject(built.ops.projectId);
      if (project.repoProblem != null) {
        stderr.writeln(project.repoProblem);
        return 1;
      }
      // A given directory is where the files go, whichever kind they are;
      // without one each kind has its own configured home.
      final String arbDir = positional ?? cfg.arbDir ?? 'arbs/Default';
      // Into a given directory the catalog is written whole, as served.
      final List<CatalogTarget>? targets =
          positional == null ? cfg.xcstringsCatalogs : null;
      final String catalogDir = positional ??
          (project.shipsFlutter || targets != null
              ? cfg.catalogDir
              : cfg.xcstringsDir ?? cfg.arbDir ?? '.');
      // The same hazard `pull` guards: this rewrites the files from the
      // service, so a key staged on disk and never imported disappears. That
      // is how eight onboarding keys were lost once, and why this command
      // carried a "never run it here" warning in a consuming repo instead of
      // a check.
      if (project.shipsIos &&
          targets != null &&
          !(argResults!['discard-local'] as bool)) {
        final int? refused = _refuseConflicts(this, targets);
        if (refused != null) return refused;
      }
      if (!(argResults!['discard-local'] as bool)) {
        final LanguageData? base = project.baseLanguage(built.ops.flavor);
        if (base != null) {
          final Set<String> serviceKeys = <String>{
            for (final TranslationEntry t in base.translations)
              if (t.key.isNotEmpty) t.key,
          };
          final String template = 'app_${base.code.replaceAll('-', '_')}.arb';
          final List<({String file, List<String> keys})> staged =
              <({String file, List<String> keys})>[
            if (project.shipsFlutter)
              (
                file: '$arbDir/$template',
                keys: localOnlyKeys(File('$arbDir/$template'), serviceKeys),
              ),
            if (project.shipsIos && targets != null)
              (
                file: 'the catalogs of "xcstrings_catalogs"',
                keys: localOnlyTargetKeys(targets, serviceKeys),
              )
            else if (project.shipsIos)
              (
                file: '$catalogDir/$kLocalizableCatalog',
                keys: localOnlyCatalogKeys(
                    File('$catalogDir/$kLocalizableCatalog'), serviceKeys),
              ),
            if (project.shipsNgx)
              (
                file: '${positional ?? cfg.ngxLocaleDir}/'
                    '${ngxFileName(base.code)}',
                keys: localOnlyNgxKeys(
                    File('${positional ?? cfg.ngxLocaleDir}/'
                        '${ngxFileName(base.code)}'),
                    serviceKeys),
              ),
          ];
          for (final ({String file, List<String> keys}) entry in staged) {
            if (entry.keys.isEmpty) continue;
            stderr.writeln(
                '${entry.file} holds ${entry.keys.length} key(s) the service '
                'does not have: ${entry.keys.take(10).join(', ')}'
                '${entry.keys.length > 10 ? ', …' : ''}');
            stderr.writeln('Exporting would overwrite them. '
                '${targets != null ? 'Run `fl pull --adopt` to import them '
                    'first' : 'Import them first (`fl import ${entry.file} '
                    '--translate`), or run `fl pull --adopt`'}, or force '
                'with `--discard-local`.');
            return 1;
          }
        }
      }
      final OpResult r = await _exportFromApi(
        built.ops,
        project,
        arbDir: arbDir,
        catalogDir: catalogDir,
        angularDir: positional ?? cfg.angularLocaleDir,
        ngxDir: positional ?? cfg.ngxLocaleDir,
        appRoot: positional == null ? cfg.root ?? Directory.current.path : null,
        targets: targets,
        dryRun: dryRun,
      );
      if (jsonOut) return emit(r);
      stdout.writeln(r.message);
      _printFiles(r);
      if (r.ok && !dryRun && project.shipsFlutter) {
        stdout.writeln('\nNow regenerate the Dart: '
            '`dart run flutter_localisation ${path.dirname(arbDir)} '
            '${path.basename(arbDir)}`, then restart the app.');
      }
      return r.ok ? 0 : 1;
    } finally {
      built.client.close();
    }
  }
}

// --------------------------------------------------------------------------- //
// Glossary, language styles, locked keys
// --------------------------------------------------------------------------- //

/// Runs [body] with a [GlossaryOperations] for the resolved project, closing
/// the client afterwards.
mixin _GlossaryCommand on Command<int>, _ApiCommand {
  Future<int> withGlossary(
    final Future<int> Function(GlossaryOperations g, Operations ops) body,
  ) async {
    final ({
      ManagementClient client,
      Operations ops,
      String projectName
    }) built = await build(loadProject());
    try {
      return await body(
          GlossaryOperations(built.client, built.ops.projectId), built.ops);
    } finally {
      built.client.close();
    }
  }
}

class GlossaryCommand extends Command<int> {
  GlossaryCommand() {
    addSubcommand(GlossaryListCommand());
    addSubcommand(GlossaryAddCommand());
    addSubcommand(GlossaryRemoveCommand());
    addSubcommand(GlossaryImportCommand());
    addSubcommand(GlossaryExportCommand());
    addSubcommand(GlossarySuggestCommand());
    addSubcommand(GlossaryApplyCommand());
  }

  @override
  String get name => 'glossary';
  @override
  String get description =>
      'Terms the translator must handle the same way everywhere: kept as '
      'written (brand names) or pinned to one translation per locale.';
}

class GlossaryListCommand extends Command<int>
    with _ApiCommand, _GlossaryCommand {
  @override
  String get name => 'list';
  @override
  String get description =>
      'List the glossary and how many strings use each term.';

  @override
  Future<int> run() =>
      withGlossary((final GlossaryOperations g, final _) async {
        final OpResult r = await g.list();
        if (jsonOut) return emit(r);
        stdout.writeln(r.message);
        for (final dynamic t in r.data['terms'] as List<dynamic>) {
          stdout.writeln(
              '  ${GlossaryOperations.describeTerm(t as Map<String, dynamic>)}');
        }
        return 0;
      });
}

class GlossaryAddCommand extends Command<int>
    with _ApiCommand, _GlossaryCommand {
  GlossaryAddCommand() {
    argParser
      ..addFlag('keep',
          negatable: false,
          help: 'Never translate it: every locale keeps it exactly as written '
              '(brand and product names).')
      ..addMultiOption('as',
          help: 'Pinned translation, <locale>=<text>; repeatable. de-AT falls '
              'back to de.',
          valueHelp: 'de=Schnipsel')
      ..addOption('note', help: 'What the term means, for the translator.')
      ..addFlag('case-sensitive',
          help: 'Match only this exact capitalisation.', defaultsTo: null);
  }

  @override
  String get name => 'add';
  @override
  String get description =>
      'Add a term, or update it if it exists. Pass every term of a big '
      'glossary with `fl glossary import` instead of looping this.';
  @override
  String get invocation =>
      'fl glossary add <term> (--keep | --as de=Schnipsel ...) [--note "..."]';

  @override
  Future<int> run() {
    final List<String> rest = argResults!.rest;
    if (rest.isEmpty) {
      throw UsageException(
          'Missing <term>, e.g. `fl glossary add Dictee --keep`.', usage);
    }
    return withGlossary(
        (final GlossaryOperations g, final _) async => emit(await g.add(
              rest.join(' '),
              keep: argResults!['keep'] as bool,
              translations:
                  parseTermTranslations(argResults!['as'] as List<String>),
              note: argResults!['note'] as String?,
              caseSensitive: argResults!['case-sensitive'] as bool?,
              dryRun: dryRun,
            )));
  }
}

class GlossaryRemoveCommand extends Command<int>
    with _ApiCommand, _GlossaryCommand {
  @override
  String get name => 'remove';
  @override
  String get description => 'Remove a term from the glossary.';
  @override
  String get invocation => 'fl glossary remove <term>';

  @override
  Future<int> run() {
    final List<String> rest = argResults!.rest;
    if (rest.isEmpty) throw UsageException('Missing <term>.', usage);
    return withGlossary((final GlossaryOperations g, final _) async =>
        emit(await g.remove(rest.join(' '), dryRun: dryRun)));
  }
}

class GlossaryImportCommand extends Command<int>
    with _ApiCommand, _GlossaryCommand {
  @override
  String get name => 'import';
  @override
  String get description =>
      'Add or update every term of a JSON file ({"terms": [...]}, as `fl '
      'glossary export` writes) or a CSV (header: term,keep,note,de,fr,...).';
  @override
  String get invocation => 'fl glossary import <file.json|file.csv>';

  @override
  Future<int> run() {
    final List<String> rest = argResults!.rest;
    if (rest.isEmpty) throw UsageException('Missing <file>.', usage);
    return withGlossary((final GlossaryOperations g, final _) async =>
        emit(await g.importFile(rest.first, dryRun: dryRun)));
  }
}

class GlossaryExportCommand extends Command<int>
    with _ApiCommand, _GlossaryCommand {
  @override
  String get name => 'export';
  @override
  String get description =>
      'Write the glossary to a JSON file `fl glossary import` reads.';
  @override
  String get invocation => 'fl glossary export [<file.json>]';

  @override
  Future<int> run() =>
      withGlossary((final GlossaryOperations g, final _) async => emit(
          await g.export(argResults!.rest.isEmpty
              ? 'glossary.json'
              : argResults!.rest.first)));
}

class GlossarySuggestCommand extends Command<int>
    with _ApiCommand, _GlossaryCommand {
  GlossarySuggestCommand() {
    argParser.addFlag('apply',
        negatable: false,
        help: 'Add every suggestion (acronyms and the project name kept as '
            'written, other names without a fixed translation).');
  }

  @override
  String get name => 'suggest';
  @override
  String get description =>
      'Terms worth adding: the project name, names that recur capitalised '
      'mid-sentence, acronyms.';

  @override
  Future<int> run() =>
      withGlossary((final GlossaryOperations g, final _) async {
        final OpResult r = await g.suggest(
            apply: argResults!['apply'] as bool, dryRun: dryRun);
        if (jsonOut) return emit(r);
        stdout.writeln(r.message);
        for (final dynamic s
            in (r.data['suggestions'] as List<dynamic>?) ?? const <dynamic>[]) {
          final Map<String, dynamic> m = s as Map<String, dynamic>;
          stdout
              .writeln('  ${m['term']}  (${m['reason']}, ${m['string_count']} '
                  'string(s)${m['do_not_translate'] == true ? ', keep' : ''})');
        }
        return 0;
      });
}

class GlossaryApplyCommand extends Command<int>
    with _ApiCommand, _GlossaryCommand {
  GlossaryApplyCommand() {
    argParser
      ..addMultiOption('term',
          help: 'Only strings containing this term; repeatable.')
      ..addMultiOption('locale', help: 'Only these locales; repeatable.')
      ..addFlag('all',
          negatable: false,
          help: 'Every string, not only those with glossary terms: after '
              'changing a language style.');
  }

  @override
  String get name => 'apply';
  @override
  String get description =>
      'Re-translate the strings that contain glossary terms, in every locale, '
      'so translations made before a term was added follow it.';
  @override
  String get invocation =>
      'fl glossary apply [--term Dictee] [--locale de] [--all] [--dry-run]';

  @override
  Future<int> run() =>
      withGlossary((final GlossaryOperations g, final Operations ops) async =>
          emit(await g.apply(
            ops,
            only: argResults!['term'] as List<String>,
            all: argResults!['all'] as bool,
            locales: _locales(argResults!['locale'] as List<String>),
            dryRun: dryRun,
          )));
}

class StyleCommand extends Command<int> {
  StyleCommand() {
    addSubcommand(StyleListCommand());
    addSubcommand(StyleSetCommand());
    addSubcommand(StyleClearCommand());
  }

  @override
  String get name => 'style';
  @override
  String get description =>
      'How translations address the reader per language: formal (Sie, vous, '
      'usted) or informal (du, tu, tú), plus instructions of your own, for one '
      'language or for all of them.';
}

class StyleListCommand extends Command<int> with _ApiCommand, _GlossaryCommand {
  @override
  String get name => 'list';
  @override
  String get description => 'Show the style each locale is translated in.';

  @override
  Future<int> run() =>
      withGlossary((final GlossaryOperations g, final _) async {
        final OpResult r = await g.styles();
        if (jsonOut) return emit(r);
        final String everywhere = r.data['project_instructions'] as String;
        if (everywhere.isNotEmpty) {
          stdout.writeln('  every language: $everywhere');
        }
        for (final dynamic row in r.data['languages'] as List<dynamic>) {
          final Map<String, dynamic> m = row as Map<String, dynamic>;
          final String f = (m['formality'] as String? ?? '').isEmpty
              ? "translator's choice"
              : m['formality'] as String;
          final String from = m['inherited_from'] == null
              ? ''
              : ' (from ${m['inherited_from']})';
          final String extra = (m['instructions'] as String? ?? '').isEmpty
              ? ''
              : ' + instructions';
          stdout.writeln('  ${m['code']}: $f$extra$from');
        }
        return 0;
      });
}

class StyleSetCommand extends Command<int> with _ApiCommand, _GlossaryCommand {
  StyleSetCommand() {
    argParser
      ..addFlag('formal',
          negatable: false, help: 'Formal address (Sie, vous, usted, Lei...).')
      ..addFlag('informal',
          negatable: false, help: 'Informal address (du, tu, tú...).')
      ..addOption('instructions',
          help: 'Anything else the translator should follow for this locale, '
              'or with --all for every language.')
      ..addFlag('all',
          negatable: false,
          help: 'Set --instructions for every language of the project at '
              'once, present and future ("Never use a dash").');
  }

  @override
  String get name => 'set';
  @override
  String get description =>
      'Set the style of a locale. Regional variants (de-AT) follow their '
      'language (de) unless they have their own. With --all, set one '
      'instruction for every language.';
  @override
  String get invocation =>
      'fl style set <locale> (--formal | --informal) [--instructions "..."]\n'
      '       fl style set --all --instructions "..."';

  @override
  Future<int> run() {
    final List<String> rest = argResults!.rest;
    final bool formal = argResults!['formal'] as bool;
    final bool informal = argResults!['informal'] as bool;
    if (argResults!['all'] as bool) {
      final String text =
          ((argResults!['instructions'] as String?) ?? '').trim();
      if (rest.isNotEmpty) {
        throw UsageException('Pass a locale or --all, not both.', usage);
      }
      if (formal || informal) {
        throw UsageException(
            'Formal and informal are set per language: '
            '`fl style set de --formal`.',
            usage);
      }
      if (text.isEmpty) {
        throw UsageException(
            'Missing --instructions "...". To remove them: '
            '`fl style clear --all`.',
            usage);
      }
      return withGlossary((final GlossaryOperations g, final _) async =>
          emit(await g.setProjectInstructions(text, dryRun: dryRun)));
    }
    if (rest.isEmpty) throw UsageException('Missing <locale>.', usage);
    if (formal && informal) {
      throw UsageException('Pass --formal or --informal, not both.', usage);
    }
    return withGlossary(
        (final GlossaryOperations g, final _) async => emit(await g.setStyle(
              rest.first,
              formality: formal ? 'formal' : (informal ? 'informal' : ''),
              instructions: (argResults!['instructions'] as String?) ?? '',
              dryRun: dryRun,
            )));
  }
}

class StyleClearCommand extends Command<int>
    with _ApiCommand, _GlossaryCommand {
  StyleClearCommand() {
    argParser.addFlag('all',
        negatable: false,
        help: 'Remove the instructions set for every language. Each '
            "language's own style stays.");
  }

  @override
  String get name => 'clear';
  @override
  String get description =>
      "Remove a locale's style; it then follows its parent, if any.";
  @override
  String get invocation => 'fl style clear (<locale> | --all)';

  @override
  Future<int> run() {
    final List<String> rest = argResults!.rest;
    if (argResults!['all'] as bool) {
      if (rest.isNotEmpty) {
        throw UsageException('Pass a locale or --all, not both.', usage);
      }
      return withGlossary((final GlossaryOperations g, final _) async =>
          emit(await g.setProjectInstructions('', dryRun: dryRun)));
    }
    if (rest.isEmpty) throw UsageException('Missing <locale>.', usage);
    return withGlossary((final GlossaryOperations g, final _) async =>
        emit(await g.clearStyle(rest.first, dryRun: dryRun)));
  }
}

/// `fl lock` / `fl unlock`: keys that are never translated.
class LockCommand extends Command<int> with _ApiCommand, _GlossaryCommand {
  LockCommand({required this.lock});

  final bool lock;

  @override
  String get name => lock ? 'lock' : 'unlock';
  @override
  String get description => lock
      ? 'Never translate these keys: every locale shows the base text as '
          'written (a URL, a code sample, a name). Same as Xcode\'s '
          '"shouldTranslate": false.'
      : 'Translate these keys again (then run `fl retranslate`).';
  @override
  String get invocation => 'fl $name <key> [<key> ...]';

  @override
  Future<int> run() {
    final List<String> rest = argResults!.rest;
    if (rest.isEmpty) throw UsageException('Missing <key>.', usage);
    return withGlossary((final GlossaryOperations g, final _) async =>
        emit(await g.lock(rest, on: lock, dryRun: dryRun)));
  }
}
