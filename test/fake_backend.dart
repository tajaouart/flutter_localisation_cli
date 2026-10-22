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
  String? get fileName =>
      RegExp(r'filename="([^"]+)"').firstMatch(body)?.group(1);
}

class FakeBackend {
  FakeBackend._(this._server);

  final HttpServer _server;

  /// What the project ships; tests change it between calls.
  List<String> platforms = <String>['ios'];

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
        'flavors': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 3,
            'name': 'Default',
            'languages': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 1,
                'code': 'en',
                'is_base_language': true,
                'translations': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'id': 1,
                    'key': 'running %lld',
                    'value': 'Cleaning… {arg1} s left',
                    'placeholders': <String, dynamic>{
                      'arg1': <String, dynamic>{'type': 'int', 'spec': '%lld'},
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
    res.headers.contentType = ContentType.json;

    if (req.headers.value('authorization') != 'Bearer flk_live_test') {
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
              <String, dynamic>{
                'id': 3,
                'name': 'Default',
                'base_language': 'en',
                'languages': <String>['en'],
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
      imports.add(ReceivedImport(body));
      res.write(jsonEncode(<String, dynamic>{
        'import_status': 'success',
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
