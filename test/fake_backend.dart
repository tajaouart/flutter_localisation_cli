/// A FlutterLocalisation backend on a local port, for tests that run the real
/// `fl` and `fl_mcp` binaries as child processes.
///
/// It answers the handful of endpoints the iOS paths touch, records every
/// import it receives, and lets a test flip the project's platforms between
/// calls so one process can be walked through Flutter, iOS and mixed cases.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Bytes the way the backend serves a catalog: Xcode's ` : ` separator, which
/// a re-encode would silently normalise away.
const String kServedCatalog = '{\n'
    '  "sourceLanguage" : "en",\n'
    '  "strings" : {\n'
    '    "running %lld" : {\n'
    '      "extractionState" : "manual",\n'
    '      "localizations" : {\n'
    '        "en" : {\n'
    '          "stringUnit" : {\n'
    '            "state" : "translated",\n'
    '            "value" : "Cleaning… %lld s left"\n'
    '          }\n'
    '        }\n'
    '      }\n'
    '    }\n'
    '  },\n'
    '  "version" : "1.0"\n'
    '}\n';

const String kEmptyInfoPlist =
    '{\n  "sourceLanguage" : "en",\n  "strings" : {\n\n  },\n  "version" : "1.0"\n}\n';

/// A catalog edited in Xcode: the served key plus one the service lacks.
const String kCatalogWithLocalKey = '{\n'
    '  "sourceLanguage" : "en",\n'
    '  "strings" : {\n'
    '    "local only" : {\n'
    '      "localizations" : {\n'
    '        "en" : {\n'
    '          "stringUnit" : {\n'
    '            "state" : "translated",\n'
    '            "value" : "Only on disk"\n'
    '          }\n'
    '        }\n'
    '      }\n'
    '    },\n'
    '    "running %lld" : {\n'
    '      "localizations" : {\n'
    '        "en" : {\n'
    '          "stringUnit" : {\n'
    '            "state" : "translated",\n'
    '            "value" : "Cleaning… %lld s left"\n'
    '          }\n'
    '        }\n'
    '      }\n'
    '    }\n'
    '  },\n'
    '  "version" : "1.0"\n'
    '}\n';

class ReceivedImport {
  ReceivedImport(this.body);

  /// The raw multipart body.
  final String body;

  bool get hasLanguage => body.contains('name="selected_language_code"');
  String? get language => _field('selected_language_code');
  bool get autoTranslate => _field('auto_translate') == 'true';
  bool get prune => _field('prune') == 'true';

  String? _field(final String name) =>
      RegExp('name="$name"\\r?\\n\\r?\\n([^\\r\\n]*)')
          .firstMatch(body)
          ?.group(1);
  String? get fileName =>
      RegExp(r'filename="([^"]+)"').firstMatch(body)?.group(1);
}

/// One answer a test queues ahead of the normal routing.
class Fault {
  /// A status with a body, the way a failing service or a proxy answers.
  const Fault(
    this.status, {
    this.body = '{"error": "unavailable"}',
    this.contentType = 'application/json',
    this.retryAfter,
  }) : stall = false;

  /// Accept the request and never answer it.
  const Fault.stall()
      : status = 0,
        body = '',
        contentType = '',
        retryAfter = null,
        stall = true;

  final int status;
  final String body;
  final String contentType;
  final int? retryAfter;
  final bool stall;
}

/// A second token the backend accepts for reads only.
const String kReadOnlyToken = 'flk_live_readonly';

class FakeBackend {
  FakeBackend._(this._server);

  /// Served in order, one per request, before anything else is looked at.
  final List<Fault> faults = <Fault>[];

  /// What the service says about client versions; null sends no header, as
  /// a service from before the CLI named itself.
  String? latestVersion;
  String? minimumVersion;
  String? notice;

  /// `X-FL-Client` and `User-Agent` of every request, in order.
  final List<String?> clients = <String?>[];
  final List<String?> userAgents = <String?>[];

  /// `X-FL-Install` of every request: `pub` or `npm`.
  final List<String?> installs = <String?>[];

  static const String _upgrade =
      'dart pub global activate flutter_localisation_cli';

  static List<int> _numbers(final String version) => <int>[
        for (final String part in version.split('.').take(3))
          int.tryParse(part) ?? 0,
      ];

  static bool _older(final String version, final String than) {
    final List<int> a = _numbers(version), b = _numbers(than);
    for (int i = 0; i < 3; i++) {
      if (a[i] != b[i]) return a[i] < b[i];
    }
    return false;
  }

  final HttpServer _server;

  /// What the project ships; tests change it between calls.
  List<String> platforms = <String>['ios'];

  /// Flavor names, in order; each holds the same one English key.
  List<String> flavors = <String>['Default'];

  /// Locale codes of every flavor, base language first.
  List<String> languages = <String>['en'];

  /// False for a token with `strings:write` only: an import that asks for
  /// translation, and a translation itself, are refused the way the service
  /// refuses them.
  bool translateScope = true;

  /// The linked git repo the project detail reports, or null for none.
  String? repoUrl;

  /// The provider [repoUrl] is linked through.
  String repoProvider = 'github';

  /// The one key's row in other languages, by locale code: `value`, and
  /// `is_outdated` for a translation of an older base text. A locale without
  /// an entry has no row.
  Map<String, Map<String, dynamic>> targets = <String, Map<String, dynamic>>{};

  /// More keys of the base language, beside the one every flavor holds.
  List<String> extraKeys = <String>[];

  /// `platforms` of an extra key, by key.
  Map<String, List<String>> extraKeyPlatforms = <String, List<String>>{};

  /// The `Localizable` catalog to serve in place of [kServedCatalog].
  String? servedCatalog;

  /// The `InfoPlist` catalog to serve in place of [kEmptyInfoPlist].
  String? infoPlist;

  /// The `AppShortcuts` catalog; null answers as a service from before it
  /// had one, with a 400.
  String? appShortcuts;

  /// What the translator is told for every language.
  String projectInstructions = '';

  /// What an import reports it left out, as the service words it.
  List<String> importProblems = <String>[];

  /// Ids of every batch translation request, in order.
  final List<List<int>> translated = <List<int>>[];

  /// The `target` of every batch translation request, null for none.
  final List<String?> translatedTargets = <String?>[];

  /// Answer as a service that knows platform text: `overrides`, `platforms`
  /// and `max_length` on every row. Off answers as one from before.
  bool platformText = false;

  /// The one key's texts per target, by locale code.
  Map<String, List<Map<String, dynamic>>> overrides =
      <String, List<Map<String, dynamic>>>{};

  /// `platforms` and `max_length` of the one key.
  List<String> keyPlatforms = <String>[];
  Map<String, int> keyMaxLength = <String, int>{};

  /// Bodies of `update_translation` (with its `id`), `translation_keys` and
  /// `shorten` requests, in order.
  final List<Map<String, dynamic>> updates = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> keyPosts = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> shortens = <Map<String, dynamic>>[];

  Map<String, dynamic> _textFields(final String? code) => !platformText
      ? const <String, dynamic>{}
      : <String, dynamic>{
          'overrides': code == null
              ? const <dynamic>[]
              : overrides[code] ?? const <dynamic>[],
          'platforms': code == null ? const <String>[] : keyPlatforms,
          'max_length': code == null ? const <String, int>{} : keyMaxLength,
        };

  final List<ReceivedImport> imports = <ReceivedImport>[];

  /// Answer a `prune` import with what the service deleted and took the
  /// file's platform off; null answers as a service that ignores `prune`.
  ({List<String> pruned, List<String> unshipped})? serverPrune;

  /// Keys deleted through `/translation_keys/delete/`, in order.
  final List<String> deletedKeys = <String>[];
  final List<String> requests = <String>[];

  String get url => 'http://127.0.0.1:${_server.port}';

  static Future<FakeBackend> start() async {
    final HttpServer server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final FakeBackend backend = FakeBackend._(server);
    server.listen(backend._handle);
    return backend;
  }

  Future<void> close() => _server.close(force: true);

  Map<String, dynamic> get _project => <String, dynamic>{
        'id': 7,
        'name': 'Gush',
        'platforms': platforms,
        'xcstrings_dir': 'Resources',
        if (platformText) 'keys_per_platform': false,
        if (repoUrl != null) ...<String, dynamic>{
          'is_${repoProvider}_linked': true,
          '${repoProvider}_repository_url': repoUrl,
        },
        'flavors': <Map<String, dynamic>>[
          for (int i = 0; i < flavors.length; i++)
            <String, dynamic>{
              'id': 3 + i,
              'name': flavors[i],
              'languages': <Map<String, dynamic>>[
                for (final String code in languages.skip(1))
                  <String, dynamic>{
                    'id': 100 + i + languages.indexOf(code),
                    'code': code,
                    'is_base_language': false,
                    'translations': <Map<String, dynamic>>[
                      if (targets[code] != null)
                        <String, dynamic>{
                          'id': 500 + i * 100 + languages.indexOf(code),
                          'key': 'running %lld',
                          ...targets[code]!,
                          ..._textFields(code),
                        },
                    ],
                  },
                <String, dynamic>{
                  'id': 1 + i,
                  'code': languages.first,
                  'is_base_language': true,
                  'translations': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'id': 1 + i,
                      'key': 'running %lld',
                      'value': 'Cleaning… {arg1} s left',
                      'placeholders': <String, dynamic>{
                        'arg1': <String, dynamic>{
                          'type': 'int',
                          'spec': '%lld'
                        },
                      },
                      ..._textFields(languages.first),
                    },
                    for (int k = 0; k < extraKeys.length; k++)
                      <String, dynamic>{
                        'id': 900 + i * 100 + k,
                        'key': extraKeys[k],
                        'value': extraKeys[k],
                        ..._textFields(null),
                        if (platformText)
                          'platforms':
                              extraKeyPlatforms[extraKeys[k]] ?? <String>[],
                      },
                  ],
                },
              ],
            },
        ],
      };

  Future<void> _handle(final HttpRequest req) async {
    final String path = req.uri.path;
    requests.add('${req.method} ${req.uri}');
    final HttpResponse res = req.response;
    final String? client = req.headers.value('x-fl-client');
    clients.add(client);
    userAgents.add(req.headers.value('user-agent'));
    installs.add(req.headers.value('x-fl-install'));
    if (latestVersion != null) {
      res.headers.set('X-FL-Latest-Version', latestVersion!);
      res.headers.set('X-FL-Upgrade-Command', _upgrade);
      if (notice != null) res.headers.set('X-FL-Notice', notice!);
    }
    final String sent = client?.split('/').last ?? '0.0.0';
    if (minimumVersion != null && _older(sent, minimumVersion!)) {
      res.statusCode = 426;
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode(<String, String>{
        'status': 'error',
        'code': 'client_outdated',
        'message': '${client?.replaceAll('/', ' ')} is no longer supported; '
            '$minimumVersion or newer is required. Update with: $_upgrade',
      }));
      await res.close();
      return;
    }
    if (faults.isNotEmpty) {
      final Fault fault = faults.removeAt(0);
      if (fault.stall) return;
      res.statusCode = fault.status;
      res.headers.set('content-type', fault.contentType);
      if (fault.retryAfter != null) {
        res.headers.set('retry-after', '${fault.retryAfter}');
      }
      res.write(fault.body);
      await res.close();
      return;
    }
    res.headers.contentType = ContentType.json;

    final String? auth = req.headers.value('authorization');
    if (auth == 'Bearer $kReadOnlyToken' && req.method != 'GET') {
      res.statusCode = HttpStatus.forbidden;
      res.write(jsonEncode(<String, String>{
        'error': "This token lacks the 'strings:write' scope.",
      }));
      await res.close();
      return;
    }
    if (auth != 'Bearer flk_live_test' && auth != 'Bearer $kReadOnlyToken') {
      res.statusCode = HttpStatus.unauthorized;
      res.write(jsonEncode(<String, String>{'error': 'Invalid API token.'}));
      await res.close();
      return;
    }

    if (req.method == 'GET' && path == '/api/projects/') {
      res.write(jsonEncode(<String, dynamic>{
        'projects': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 7,
            'name': 'Gush',
            'workspace': 'AylanTech',
            'platforms': platforms,
            'flavors': <Map<String, dynamic>>[
              for (int i = 0; i < flavors.length; i++)
                <String, dynamic>{
                  'id': 3 + i,
                  'name': flavors[i],
                  'base_language': languages.first,
                  'languages': languages,
                },
            ],
          },
        ],
      }));
    } else if (req.method == 'GET' && path == '/api/projects/7/') {
      res.write(jsonEncode(_project));
    } else if (path == '/api/projects/7/language-styles/') {
      if (req.method == 'PUT') {
        final Map<String, dynamic> body = jsonDecode(
          await utf8.decoder.bind(req).join(),
        ) as Map<String, dynamic>;
        projectInstructions = body['project_instructions'] as String;
        res.write(jsonEncode(
            <String, String>{'project_instructions': projectInstructions}));
      } else {
        res.write(jsonEncode(<String, dynamic>{
          'project_instructions': projectInstructions,
          'languages': <Map<String, dynamic>>[
            for (final String code in languages)
              <String, dynamic>{
                'code': code,
                'formality': code == 'de' ? 'informal' : '',
                'instructions': '',
                'inherited_from': null,
              },
          ],
        }));
      }
    } else if (path.startsWith('/api/update_translation/')) {
      updates.add(<String, dynamic>{
        'id': int.parse(path.split('/')[3]),
        ...jsonDecode(await utf8.decoder.bind(req).join())
            as Map<String, dynamic>,
      });
      res.write('{}');
    } else if (req.method == 'POST' &&
        path == '/api/projects/7/translation_keys/') {
      keyPosts.add(jsonDecode(await utf8.decoder.bind(req).join())
          as Map<String, dynamic>);
      res.statusCode = HttpStatus.created;
      res.write('{"status": "success"}');
    } else if (req.method == 'POST' &&
        path == '/api/projects/7/shorten/' &&
        platformText) {
      final Map<String, dynamic> body =
          jsonDecode(await utf8.decoder.bind(req).join())
              as Map<String, dynamic>;
      shortens.add(body);
      if ((body['keys'] as List<dynamic>).contains('running %lld')) {
        overrides[languages.first] = <Map<String, dynamic>>[
          <String, dynamic>{
            'target': body['target'],
            'value': '{arg1} s',
            'needs_review': false,
            'is_outdated': false,
            'is_ai_translated': true,
          },
        ];
      }
      res.write(jsonEncode(<String, dynamic>{
        'shortened': (body['keys'] as List<dynamic>).length,
      }));
    } else if (req.method == 'GET' && path == '/api/projects/7/glossary/') {
      res.write(jsonEncode(<String, dynamic>{'terms': <dynamic>[]}));
    } else if (req.method == 'POST' &&
        path == '/api/ai_batch_translate/' &&
        !translateScope) {
      res.statusCode = HttpStatus.forbidden;
      res.write(jsonEncode(<String, dynamic>{
        'status': 'error',
        'code': 'scope',
        'scopes': <String>['translate'],
        'message': 'Your API token lacks the required scope (translate) for '
            'this endpoint. A workspace owner or manager can switch it on for '
            'this key at https://app.flutterlocalisation.com/api-keys.',
      }));
    } else if (req.method == 'POST' && path == '/api/ai_batch_translate/') {
      final Map<String, dynamic> body =
          jsonDecode(await utf8.decoder.bind(req).join())
              as Map<String, dynamic>;
      final List<int> ids =
          (body['translation_ids'] as List<dynamic>).cast<int>();
      final String? target = body['target'] as String?;
      translated.add(ids);
      translatedTargets.add(target);
      for (final String code in targets.keys) {
        if (!ids.contains(500 + languages.indexOf(code))) continue;
        if (target == null) {
          targets[code] = <String, dynamic>{'value': 'Translated ($code)'};
        } else {
          overrides[code] = <Map<String, dynamic>>[
            <String, dynamic>{'target': target, 'value': 'Kurz ($code)'},
          ];
        }
      }
      res.write(jsonEncode(<String, dynamic>{
        'status': 'success',
        'results': <String, dynamic>{
          'successful': <dynamic>[],
          'failed': <dynamic>[],
        },
      }));
    } else if (req.method == 'GET' &&
        path == '/api/project/7/export/' &&
        req.uri.queryParameters['format'] == 'angular') {
      final String code = req.uri.queryParameters['language_code'] ?? '';
      res.write('${const JsonEncoder.withIndent('  ').convert(<String, String>{
            '@@locale': code,
            'home.title': 'Hello ($code)',
            'home.greeting': r'Hi {$INTERPOLATION} ' '($code)',
          })}\n');
    } else if (req.method == 'GET' &&
        path == '/api/project/7/export/' &&
        req.uri.queryParameters['format'] == 'ngx') {
      final String code = req.uri.queryParameters['language_code'] ?? '';
      final bool nested = req.uri.queryParameters['layout'] == 'nested';
      final Map<String, dynamic> doc = nested
          ? <String, dynamic>{
              'home': <String, String>{
                'title': 'Hello ($code)',
                'greeting': 'Hi {{name}} ($code)',
              },
            }
          : <String, dynamic>{
              'home.greeting': 'Hi {{name}} ($code)',
              'home.title': 'Hello ($code)',
            };
      res.write('${const JsonEncoder.withIndent('  ').convert(doc)}\n');
    } else if (req.method == 'GET' && path == '/api/project/7/export/') {
      final String table = req.uri.queryParameters['table'] ?? 'Localizable';
      if (table == 'AppShortcuts' && appShortcuts == null) {
        res.statusCode = HttpStatus.badRequest;
        res.write(jsonEncode(<String, String>{
          'error': 'table must be Localizable or InfoPlist.',
        }));
      } else {
        res.write(switch (table) {
          'InfoPlist' => infoPlist ?? kEmptyInfoPlist,
          'AppShortcuts' => appShortcuts!,
          _ => servedCatalog ?? kServedCatalog,
        });
      }
    } else if (req.method == 'POST' &&
        path == '/api/projects/7/translation_keys/delete/') {
      deletedKeys.add((jsonDecode(await utf8.decoder.bind(req).join())
          as Map<String, dynamic>)['key'] as String);
      res.write('{}');
    } else if (req.method == 'POST' && path == '/api/project/7/import-arb/') {
      final String body = await utf8.decoder.bind(req).join();
      final ReceivedImport received = ReceivedImport(body);
      if (received.autoTranslate && !translateScope) {
        res.statusCode = HttpStatus.forbidden;
        res.write(jsonEncode(<String, String>{
          'error': "auto_translate requires the 'translate' scope; this "
              "token only has 'strings:write'. Import without it, then "
              'translate with a token that has the scope.',
        }));
        await res.close();
        return;
      }
      imports.add(received);
      res.write(jsonEncode(<String, dynamic>{
        'import_status': 'success',
        if (received.autoTranslate)
          'translation': <String, dynamic>{
            'status': 'success',
            'translated': 1,
            'failed': 0,
            'pending': 1,
          },
        'import': <String, dynamic>{
          'keys': <String, int>{
            'total': 1,
            'written': 1,
            'skipped': 0,
            'unchanged': 0
          },
          'rows': <String, int>{},
          'skipped_keys': <String>[],
          'locales': <String>['en'],
          'problems': importProblems,
          if (received.prune && serverPrune != null) ...<String, dynamic>{
            'pruned': serverPrune!.pruned,
            'unshipped': serverPrune!.unshipped,
          },
        },
      }));
    } else {
      res.statusCode = HttpStatus.notFound;
      res.write(jsonEncode(<String, String>{'error': 'no route for $path'}));
    }
    await res.close();
  }
}

/// The package root, whichever directory `dart test` was started from.
String packageRoot() {
  Directory dir = Directory.current;
  while (!File('${dir.path}/pubspec.yaml').existsSync()) {
    if (dir.parent.path == dir.path) {
      throw StateError('pubspec.yaml not found above ${Directory.current}');
    }
    dir = dir.parent;
  }
  return dir.path;
}
