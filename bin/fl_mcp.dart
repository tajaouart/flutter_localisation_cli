#!/usr/bin/env dart
/// `fl_mcp` — Model Context Protocol server for FlutterLocalisation.
///
/// Exposes translation-key management to Claude (or any MCP client) over stdio, reusing the
/// same `Operations` core as the `fl` CLI. The token is a *workspace* credential, so the
/// server discovers projects itself — users pick a project **by name** (via `list_projects`
/// or a `project` argument); they never hand-type a numeric id.
///
/// Mutating tools follow a **preview → apply** split: dry-run unless called with
/// `"apply": true`, so the human confirms the diff before anything is written.
///
/// Configuration via environment (set in the MCP client config):
///   FL_API_TOKEN   scoped flk_live_ token. Optional if you've run `fl login`
///                  (the token in ~/.config/flutterlocalisation/credentials.json
///                  is used as a fallback, same resolution as the `fl` CLI).
///   FL_BASE_URL    (optional)  defaults to https://api.flutterlocalisation.com
///   FL_PROJECT     (optional)  default project name or id, if you don't want to pass it per call
///   FL_FLAVOR      (optional)  default flavor
///
/// Run: `dart run flutter_localisation:fl_mcp`
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_localisation_cli/src/config.dart';
import 'package:flutter_localisation_cli/src/exceptions.dart';
import 'package:flutter_localisation_cli/src/management_client.dart';
import 'package:flutter_localisation_cli/src/operations.dart';
import 'package:flutter_localisation_cli/src/project_resolver.dart';

const String _protocolVersion = '2024-11-05';
const String _serverName = 'flutter-localisation';
const String _serverVersion = '1.0.0';

/// Top-level guidance handed to the AI client in the `initialize` reply (the MCP
/// `instructions` field). Frames the whole tool set so a model understands the
/// SaaS is the source of truth before it touches a single string.
const String _serverInstructions =
    'FlutterLocalisation is the SOURCE OF TRUTH for this project\'s UI strings. '
    'The ARB files and generated localization Dart in the consuming repo are '
    'produced by this backend + `fl` codegen and are write-protected there — '
    'never tell the user to hand-edit them, and never edit them yourself. '
    'To add or change a string, use these tools (add_string / edit_string / '
    'import_arb) or the dashboard, then have the user run `fl pull` to sync the '
    'ARBs into their repo. '
    'WORK IN BULK. Adding or translating N strings must cost O(1) requests, not '
    'O(N): collect them into an .arb file and call import_arb ONCE with '
    'translate=true — it creates every key across every locale and '
    'batch-translates server-side. To populate a NEW locale, call add_language '
    'with auto_translate=true — that back-fills every existing key in one '
    'server-side pass; never walk the keys yourself. '
    'add_string is for a SINGLE one-off key. A loop over add_string, edit_string '
    'or translate_key is always the wrong shape, and it is enforced in two '
    'places: this server refuses add_string after a handful of applied calls, '
    'and the backend rate-limits single-key creation to 10/min and answers with '
    'a 429 naming the bulk endpoint. Neither is a signal to sleep and retry — '
    'backing off just runs the same wrong algorithm slower. Switch to the bulk '
    'call. '
    'If a bulk call reports that nothing was translated, FIX THE BULK CALL — its '
    'message says how (usually: import against the base language so every locale '
    'is seeded) — rather than falling back to per-key writes. A silent "nothing '
    'to translate" used to be the trap that pushed callers into ~700-request '
    'loops; it is now a hard error for exactly that reason. '
    'Mutating tools are preview-by-default: pass '
    '"apply": true only after the user confirms the diff. If git sync is '
    'disconnected (see the warning in list_projects), the change is saved '
    'server-side but ARBs will not update until the user reconnects GitHub in '
    'the dashboard — surface that rather than editing files directly.';

/// How many single-key `add_string` writes one session may make before the
/// server stops it and points at `import_arb`.
///
/// Prose in a tool description does not survive a model that has decided to
/// loop, so the limit is enforced rather than documented. Five is above any
/// genuine one-off edit session and far below the hundreds that a bulk import
/// should have been.
const int _kAddStringLoopLimit = 5;

int _appliedAddStrings = 0;

late final ManagementClient _client;
late final ProjectResolver _resolver;

Future<void> main(final List<String> args) async {
  _bootstrap();

  final Stream<String> lines =
      stdin.transform(utf8.decoder).transform(const LineSplitter());

  await for (final String line in lines) {
    final String trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(trimmed) as Map<String, dynamic>;
    } catch (_) {
      continue;
    }
    await _handle(msg);
  }
}

void _bootstrap() {
  final Map<String, String> env = Platform.environment;
  final String baseUrl = env['FL_BASE_URL'] ?? kDefaultBaseUrl;
  final String token;
  try {
    // Resolve the token the same way the `fl` CLI does: $FL_API_TOKEN first,
    // then ~/.config/flutterlocalisation/credentials.json (written by
    // `fl login`). Previously fl_mcp only read $FL_API_TOKEN, forcing users to
    // duplicate the token into their MCP config even after `fl login`.
    token = Credentials.resolve(baseUrl: baseUrl).token;
  } on AuthConfigException {
    stderr.writeln(
      'fl_mcp: no API token found. Set \$FL_API_TOKEN or run '
      '`fl login --token flk_live_...`.',
    );
    exit(64);
  }
  _client = ManagementClient(baseUrl: baseUrl, token: token);
  _resolver = ProjectResolver(
    _client,
    // Accept either FL_PROJECT (name or id) or the legacy FL_PROJECT_ID.
    defaultProject: env['FL_PROJECT'] ?? env['FL_PROJECT_ID'],
    defaultFlavor: env['FL_FLAVOR'],
  );
  stderr.writeln('fl_mcp: ready @ $baseUrl (workspace-scoped; pick projects by name).');
}

Future<void> _handle(final Map<String, dynamic> msg) async {
  final Object? id = msg['id'];
  final String method = (msg['method'] ?? '') as String;

  switch (method) {
    case 'initialize':
      _reply(id, <String, dynamic>{
        'protocolVersion': _protocolVersion,
        'capabilities': <String, dynamic>{'tools': <String, dynamic>{}},
        'serverInfo': <String, dynamic>{
          'name': _serverName,
          'version': _serverVersion,
        },
        'instructions': _serverInstructions,
      });
      return;
    case 'ping':
      _reply(id, <String, dynamic>{});
      return;
    case 'tools/list':
      _reply(id, <String, dynamic>{'tools': _toolDefinitions()});
      return;
    case 'tools/call':
      await _callTool(
        id,
        (msg['params'] ?? const <String, dynamic>{}) as Map<String, dynamic>,
      );
      return;
    case 'notifications/initialized':
    case 'notifications/cancelled':
      return;
    default:
      if (id != null) {
        _error(id, -32601, 'Method not found: $method');
      }
  }
}

// --------------------------------------------------------------------------- //
// Tools
// --------------------------------------------------------------------------- //

/// Shared project/flavor selectors added to every project-scoped tool.
Map<String, dynamic> get _projectProps => <String, dynamic>{
      'project': <String, dynamic>{
        'type': 'string',
        'description':
            'Project name or id. Optional if there is only one project or a default is set. '
                'Call list_projects to see the options.',
      },
      'flavor': <String, dynamic>{
        'type': 'string',
        'description': 'Flavor name. Optional if the project has a single flavor.',
      },
    };

List<Map<String, dynamic>> _toolDefinitions() => <Map<String, dynamic>>[
      <String, dynamic>{
        'name': 'list_projects',
        'description':
            'List the projects (with their flavors and locales) this token can access. '
                'Call this first so the user can pick a project by name.',
        'inputSchema': <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{},
        },
      },
      <String, dynamic>{
        'name': 'project_repo',
        'description':
            'Get the ARB git repo URL the backend pushes generated ARBs to (set in the '
                'dashboard → Project → Git). Use this to find the repo to clone into '
                'arb_dir before running codegen. Read-only.',
        'inputSchema': <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{..._projectProps},
        },
      },
      <String, dynamic>{
        'name': 'list_status',
        'description':
            'Show translation completion per locale for a project/flavor. Read-only.',
        'inputSchema': <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{..._projectProps},
        },
      },
      <String, dynamic>{
        'name': 'add_string',
        'description':
            'Add ONE new translation key with its base-language value. Set translate=true to '
                'AI-fill all other locales. Preview by default; pass apply=true to write. '
                'DO NOT CALL THIS IN A LOOP: it costs one request per key plus one per '
                'locale, and the server refuses after '
                '$_kAddStringLoopLimit applied calls in a session. Adding two or more keys '
                'is always import_arb instead — one request for every key and locale.',
        'inputSchema': <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'key': <String, dynamic>{'type': 'string', 'description': 'The translation key.'},
            'value': <String, dynamic>{'type': 'string', 'description': 'Base-language value.'},
            'translate': <String, dynamic>{
              'type': 'boolean',
              'description': 'AI-translate all other locales after adding.',
              'default': false,
            },
            'description': <String, dynamic>{
              'type': 'string',
              'description': 'Key description (ARB @key.description).',
            },
            'placeholders': <String, dynamic>{
              'type': 'object',
              'description':
                  'Placeholder metadata: map of name → {type: "String|int|num|double|DateTime", '
                      'format?: "<ICU format, e.g. decimalPattern>"}. Omit to let the backend '
                      'auto-detect {name} tokens.',
              'additionalProperties': <String, dynamic>{
                'type': 'object',
                'properties': <String, dynamic>{
                  'type': <String, dynamic>{'type': 'string'},
                  'format': <String, dynamic>{'type': 'string'},
                },
              },
            },
            'apply': <String, dynamic>{
              'type': 'boolean',
              'description': 'false = preview only (default); true = actually write.',
              'default': false,
            },
            'force': <String, dynamic>{
              'type': 'boolean',
              'description':
                  'Bypass the anti-loop limit for a genuine one-off key. Never set this '
                      'to work through a list of keys — use import_arb.',
              'default': false,
            },
            ..._projectProps,
          },
          'required': <String>['key', 'value'],
        },
      },
      <String, dynamic>{
        'name': 'edit_string',
        'description':
            "Edit one locale's value of an existing key. Preview by default; apply=true writes.",
        'inputSchema': <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'key': <String, dynamic>{'type': 'string'},
            'locale': <String, dynamic>{'type': 'string', 'description': 'e.g. fr'},
            'value': <String, dynamic>{'type': 'string'},
            'description': <String, dynamic>{
              'type': 'string',
              'description': 'Key description (ARB @key.description).',
            },
            'placeholders': <String, dynamic>{
              'type': 'object',
              'description':
                  'Placeholder metadata: map of name → {type: "String|int|num|double|DateTime", '
                      'format?: "<ICU format, e.g. decimalPattern>"}.',
              'additionalProperties': <String, dynamic>{
                'type': 'object',
                'properties': <String, dynamic>{
                  'type': <String, dynamic>{'type': 'string'},
                  'format': <String, dynamic>{'type': 'string'},
                },
              },
            },
            'apply': <String, dynamic>{'type': 'boolean', 'default': false},
            ..._projectProps,
          },
          'required': <String>['key', 'locale', 'value'],
        },
      },
      <String, dynamic>{
        'name': 'delete_string',
        'description':
            'Delete a key entirely (all locales) or, with locale, just one locale. '
                'Preview by default; apply=true writes.',
        'inputSchema': <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'key': <String, dynamic>{'type': 'string'},
            'locale': <String, dynamic>{
              'type': 'string',
              'description': 'Optional; omit to delete all locales of the key.',
            },
            'apply': <String, dynamic>{'type': 'boolean', 'default': false},
            ..._projectProps,
          },
          'required': <String>['key'],
        },
      },
      <String, dynamic>{
        'name': 'translate_key',
        'description':
            "AI-translate a key's locales. Default: only missing locales. all=true does every "
                'non-base locale; or pass a specific locales list. Preview by default; apply=true writes.',
        'inputSchema': <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'key': <String, dynamic>{'type': 'string'},
            'all': <String, dynamic>{'type': 'boolean', 'default': false},
            'locales': <String, dynamic>{
              'type': 'array',
              'items': <String, dynamic>{'type': 'string'},
            },
            'apply': <String, dynamic>{'type': 'boolean', 'default': false},
            ..._projectProps,
          },
          'required': <String>['key'],
        },
      },
      <String, dynamic>{
        'name': 'add_language',
        'description':
            'Add a locale to the flavor. With auto_translate=true the backend AI-fills '
                'EVERY existing key for that locale in this one request, and keeps '
                'translating keys added later. This is the ONLY correct way to populate a '
                'new language — never iterate keys with translate_key or add_string to do '
                'it. Preview by default; apply=true writes.',
        'inputSchema': <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'code': <String, dynamic>{
              'type': 'string',
              'description': 'Locale code to add, e.g. "id", "th", "hi".',
            },
            'auto_translate': <String, dynamic>{
              'type': 'boolean',
              'description':
                  'AI-fill every existing key for the new locale, server-side, in this '
                      'same request. Almost always what you want.',
              'default': false,
            },
            'apply': <String, dynamic>{'type': 'boolean', 'default': false},
            ..._projectProps,
          },
          'required': <String>['code'],
        },
      },
      <String, dynamic>{
        'name': 'retranslate',
        'description':
            'Bulk-fix locales that are filled but NOT translated. Finds every value that '
                'is empty, or still byte-identical to the source and not yet marked '
                'checked, and AI-translates it across whole locales in batched requests. '
                'This is the repair path for the case list_languages cannot show you: a '
                'locale reports 100% filled because its rows hold the untranslated source '
                'text, so the app ships in the source language while completion looks '
                'done. translate_key cannot fix it — those rows are not "missing", and it '
                'is one key per call. Values that are correctly identical to the source '
                '(loanwords, product names, notation) should be marked checked, which '
                'excludes them from future runs. Preview by default; apply=true writes.',
        'inputSchema': <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'locales': <String, dynamic>{
              'type': 'array',
              'items': <String, dynamic>{'type': 'string'},
              'description':
                  'Locale code(s) to repair. Omit for every non-base locale.',
            },
            'apply': <String, dynamic>{'type': 'boolean', 'default': false},
            ..._projectProps,
          },
        },
      },
      <String, dynamic>{
        'name': 'list_languages',
        'description':
            'List the locales on the flavor with how many keys each has filled. Use this '
                'before adding a language, and to confirm a back-fill actually landed.',
        'inputSchema': <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{..._projectProps},
        },
      },
      <String, dynamic>{
        'name': 'import_arb',
        'description':
            'Bulk-create keys by importing a whole ARB file in ONE request — the right '
                'tool for adding MANY strings at once. Put all the strings in an ARB JSON '
                '(a flat {"key":"value"} map, @-metadata allowed) and import it, instead of '
                'many add_string calls. Provide `path` (an ARB file on disk) or `content` '
                '(raw ARB JSON). translate=true batch-translates the other locales after '
                'import (one batch call, not per key). Preview by default; apply=true writes.',
        'inputSchema': <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'path': <String, dynamic>{
              'type': 'string',
              'description': 'Path to an ARB/JSON file to import.',
            },
            'content': <String, dynamic>{
              'type': 'string',
              'description': 'Raw ARB JSON, as an alternative to path.',
            },
            'language': <String, dynamic>{
              'type': 'string',
              'description': 'Locale the file represents (default: the base language).',
            },
            'overwrite': <String, dynamic>{
              'type': 'boolean',
              'description': 'Overwrite values of keys that already exist.',
              'default': false,
            },
            'translate': <String, dynamic>{
              'type': 'boolean',
              'description': 'Batch-translate all empty non-base locales after import.',
              'default': false,
            },
            'apply': <String, dynamic>{
              'type': 'boolean',
              'description': 'false = preview only (default); true = actually write.',
              'default': false,
            },
            ..._projectProps,
          },
        },
      },
    ];

Future<void> _callTool(final Object? id, final Map<String, dynamic> params) async {
  final String name = (params['name'] ?? '') as String;
  final Map<String, dynamic> a =
      (params['arguments'] ?? const <String, dynamic>{}) as Map<String, dynamic>;
  final bool apply = (a['apply'] ?? false) as bool;

  try {
    // list_projects needs no project resolution.
    if (name == 'list_projects') {
      final List<ProjectSummary> projects =
          await _resolver.projects(refresh: true);
      _toolResult(id, <String, dynamic>{
        'ok': true,
        'projects': projects
            .map((final ProjectSummary p) => <String, dynamic>{
                  'name': p.name,
                  'id': p.id,
                  'workspace': p.workspace,
                  if (p.gitNeedsReauth)
                    'warning':
                        'Git sync is disconnected — reconnect GitHub in the dashboard; '
                            'ARB files are not updating.',
                  'flavors': p.flavors
                      .map((final FlavorSummary f) => <String, dynamic>{
                            'name': f.name,
                            'base_language': f.baseLanguage,
                            'locales': f.languages,
                          },)
                      .toList(),
                },)
            .toList(),
      });
      return;
    }

    // Every other tool is project-scoped: resolve name/id → Operations.
    final ResolvedTarget target = await _resolver.resolve(
      project: a['project'] as String?,
      flavor: a['flavor'] as String?,
    );
    final Operations ops =
        Operations(_client, target.projectId, flavor: target.flavor);

    // Read-only and not an OpResult — answer directly.
    if (name == 'project_repo') {
      final ProjectData p = await _client.getProject(target.projectId);
      final GitRepository? repo = p.repository;
      _toolResult(id, <String, dynamic>{
        'ok': repo != null,
        'project': p.name,
        if (repo == null)
          'message': 'No git provider linked. Link one in the dashboard '
              '→ Project → Git.'
        else ...<String, dynamic>{
          'provider': repo.provider,
          'url': repo.url,
          'clone_into': 'your l10n.yaml arb-dir (clone once, then git pull)',
          if (repo.needsReauth)
            'warning': 'Git sync is disconnected — reconnect in the dashboard; '
                'ARB files are not updating.',
        },
      });
      return;
    }

    final OpResult r;
    switch (name) {
      case 'list_status':
        r = await ops.status();
      case 'add_string':
        {
          if (apply) {
            _appliedAddStrings++;
          }
          if (apply &&
              _appliedAddStrings > _kAddStringLoopLimit &&
              (a['force'] ?? false) != true) {
            _appliedAddStrings = _kAddStringLoopLimit; // don't run away
            throw StateError(
              'Refusing add_string: $_kAddStringLoopLimit keys have already been '
              'added one at a time in this session. Adding keys in a loop costs '
              'one request per key (plus one per locale to translate) and will '
              'hit the API rate limit. Write the remaining keys to an .arb file '
              'and call import_arb once — it creates every key across every '
              'locale in a single request, and translate=true batch-translates '
              'them server-side. Pass force=true only if you genuinely need '
              'another single key.',
            );
          }
          final Map<String, dynamic>? placeholders =
              (a['placeholders'] as Map<String, dynamic>?)?.isEmpty ?? true
                  ? null
                  : a['placeholders'] as Map<String, dynamic>;
          r = await ops.add(
            a['key'] as String,
            a['value'] as String,
            translate: (a['translate'] ?? false) as bool,
            placeholders: placeholders,
            isPlaceholdersEnabled: placeholders == null ? null : true,
            description: a['description'] as String?,
            dryRun: !apply,
          );
        }
      case 'edit_string':
        {
          final Map<String, dynamic>? placeholders =
              (a['placeholders'] as Map<String, dynamic>?)?.isEmpty ?? true
                  ? null
                  : a['placeholders'] as Map<String, dynamic>;
          r = await ops.edit(
            a['key'] as String,
            a['locale'] as String,
            value: a['value'] as String?,
            placeholders: placeholders,
            isPlaceholdersEnabled: placeholders == null ? null : true,
            description: a['description'] as String?,
            dryRun: !apply,
          );
        }
      case 'delete_string':
        r = await ops.delete(
          a['key'] as String,
          locale: a['locale'] as String?,
          dryRun: !apply,
        );
      case 'add_language':
        r = await ops.addLanguage(
          a['code'] as String,
          autoTranslate: (a['auto_translate'] ?? false) as bool,
          dryRun: !apply,
        );
      case 'retranslate':
        r = await ops.retranslate(
          locales: (a['locales'] as List<dynamic>?)?.cast<String>(),
          dryRun: !apply,
        );
      case 'list_languages':
        r = await ops.listLanguages();
      case 'translate_key':
        r = await ops.translate(
          a['key'] as String,
          all: (a['all'] ?? false) as bool,
          locales: (a['locales'] as List<dynamic>?)?.cast<String>(),
          dryRun: !apply,
        );
      case 'import_arb':
        {
          final String? path = a['path'] as String?;
          String? content = a['content'] as String?;
          if (content == null && path != null) {
            final File f = File(path);
            if (!f.existsSync()) {
              _toolResult(id,
                  <String, dynamic>{'ok': false, 'error': 'File not found: $path'},
                  isError: true);
              return;
            }
            content = f.readAsStringSync();
          }
          if (content == null || content.trim().isEmpty) {
            _toolResult(
                id,
                <String, dynamic>{
                  'ok': false,
                  'error': 'Provide `path` (a file) or `content` (raw ARB JSON).',
                },
                isError: true);
            return;
          }
          r = await ops.importArb(
            content,
            languageCode: a['language'] as String?,
            overwrite: (a['overwrite'] ?? false) as bool,
            translate: (a['translate'] ?? false) as bool,
            dryRun: !apply,
          );
        }
      default:
        _error(id, -32602, 'Unknown tool: $name');
        return;
    }
    final Map<String, dynamic> out = r.toJson();
    out['project'] = target.projectName;
    if (target.flavor != null) out['flavor'] = target.flavor;
    _toolResult(id, out, isError: !r.ok);
  } on ManagementException catch (e) {
    _toolResult(id, <String, dynamic>{'ok': false, 'error': e.message},
        isError: true,);
  }
}

// --------------------------------------------------------------------------- //
// JSON-RPC framing
// --------------------------------------------------------------------------- //

void _toolResult(final Object? id, final Map<String, dynamic> data,
    {final bool isError = false,}) {
  _reply(id, <String, dynamic>{
    'content': <Map<String, dynamic>>[
      <String, dynamic>{
        'type': 'text',
        'text': const JsonEncoder.withIndent('  ').convert(data),
      },
    ],
    'isError': isError,
  });
}

void _reply(final Object? id, final Map<String, dynamic> result) {
  _write(<String, dynamic>{'jsonrpc': '2.0', 'id': id, 'result': result});
}

void _error(final Object? id, final int code, final String message) {
  _write(<String, dynamic>{
    'jsonrpc': '2.0',
    'id': id,
    'error': <String, dynamic>{'code': code, 'message': message},
  });
}

void _write(final Map<String, dynamic> msg) {
  stdout.writeln(jsonEncode(msg));
}
