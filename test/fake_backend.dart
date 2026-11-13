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
  /// translation is refused, the way the service refuses it.
  bool translateScope = true;

  /// The linked git repo the project detail reports, or null for none.
  String? repoUrl;

  final List<ReceivedImport> imports = <ReceivedImport>[];
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
        if (repoUrl != null) ...<String, dynamic>{
          'is_github_linked': true,
          'github_repository_url': repoUrl,
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
                    'translations': <Map<String, dynamic>>[],
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
    } else if (req.method == 'GET' && path == '/api/project/7/export/') {
      final String table = req.uri.queryParameters['table'] ?? 'Localizable';
      res.write(table == 'InfoPlist' ? kEmptyInfoPlist : kServedCatalog);
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
          'problems': <String>[],
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
