/// The MCP server as an MCP client sees it: one `fl_mcp` process on stdio,
/// JSON-RPC in, JSON-RPC out, against a backend on a local port.
///
/// The unit tests cover `Operations`; this is the layer above it, where the
/// tool list, the project resolution, the preview/apply split and the iOS
/// branches of `pull_arbs` and `import_arb` live and had no test at all.
@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fake_backend.dart';

class McpProcess {
  McpProcess(this._process)
      : _lines = _process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .asBroadcastStream();

  final Process _process;
  final Stream<String> _lines;
  int _nextId = 0;

  static Future<McpProcess> start({
    required final String baseUrl,
    required final String workingDirectory,
  }) async {
    final Process process = await Process.start(
      'dart',
      <String>['run', p.join(packageRoot(), 'bin', 'fl_mcp.dart')],
      workingDirectory: workingDirectory,
      environment: <String, String>{
        'FL_BASE_URL': baseUrl,
        'FL_API_TOKEN': 'flk_live_test',
        'HOME': workingDirectory,
      },
    );
    process.stderr.transform(utf8.decoder).listen((_) {});
    return McpProcess(process);
  }

  Future<Map<String, dynamic>> request(
    final String method, [
    final Map<String, dynamic> params = const <String, dynamic>{},
  ]) async {
    final int id = ++_nextId;
    final Future<String> reply = _lines.firstWhere(
      (final String line) => (jsonDecode(line) as Map<String, dynamic>)['id'] == id,
    );
    _process.stdin.writeln(jsonEncode(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    }));
    return jsonDecode(await reply) as Map<String, dynamic>;
  }

  /// Calls a tool and decodes the JSON the server puts in its text content.
  Future<Map<String, dynamic>> call(
    final String name, [
    final Map<String, dynamic> arguments = const <String, dynamic>{},
  ]) async {
    final Map<String, dynamic> reply =
        await request('tools/call', <String, dynamic>{'name': name, 'arguments': arguments});
    final Map<String, dynamic> result = reply['result'] as Map<String, dynamic>;
    final List<dynamic> content = result['content'] as List<dynamic>;
    final Map<String, dynamic> data =
        jsonDecode((content.first as Map<String, dynamic>)['text'] as String) as Map<String, dynamic>;
    data['_isError'] = result['isError'];
    return data;
  }

  Future<void> stop() async {
    _process.kill();
    await _process.exitCode;
  }
}

void main() {
  late FakeBackend backend;
  late Directory tmp;
  late McpProcess mcp;

  setUpAll(() async {
    backend = await FakeBackend.start();
    tmp = Directory(Directory.systemTemp.createTempSync('fl_mcp_test').resolveSymbolicLinksSync());
    File(p.join(tmp.path, 'flutterlocalisation.json')).writeAsStringSync(jsonEncode(<String, String>{
      'base_url': backend.url,
      'project': 'Gush',
      'arb_dir': 'lib/l10n',
      'xcstrings_dir': 'Resources',
    }));
    mcp = await McpProcess.start(baseUrl: backend.url, workingDirectory: tmp.path);
  });

  tearDownAll(() async {
    await mcp.stop();
    await backend.close();
    tmp.deleteSync(recursive: true);
  });

  setUp(() {
    backend.platforms = <String>['ios'];
    backend.imports.clear();
  });

  String catalogDir() => p.join(tmp.path, 'Resources');
  File catalogFile() => File(p.join(catalogDir(), 'Localizable.xcstrings'));

  test('initialize names the server and tools/list carries the catalog tools', () async {
    final Map<String, dynamic> init = await mcp.request('initialize', <String, dynamic>{
      'protocolVersion': '2024-11-05',
      'capabilities': <String, dynamic>{},
      'clientInfo': <String, String>{'name': 'test', 'version': '0'},
    });
    expect((init['result'] as Map<String, dynamic>)['serverInfo'], containsPair('name', 'flutter-localisation'));

    final Map<String, dynamic> list = await mcp.request('tools/list');
    final List<dynamic> tools = (list['result'] as Map<String, dynamic>)['tools'] as List<dynamic>;
    final Map<String, Map<String, dynamic>> byName = <String, Map<String, dynamic>>{
      for (final dynamic t in tools) (t as Map<String, dynamic>)['name'] as String: t,
    };
    expect(byName.keys, containsAll(<String>['list_projects', 'import_arb', 'pull_arbs']));
    expect(byName['import_arb']!['description'], contains('.xcstrings'));
    final Map<String, dynamic> importProps =
        (byName['import_arb']!['inputSchema'] as Map<String, dynamic>)['properties'] as Map<String, dynamic>;
    expect((importProps['path'] as Map<String, dynamic>)['description'], contains('.xcstrings'));
    expect(
      ((byName['pull_arbs']!['inputSchema'] as Map<String, dynamic>)['properties'] as Map<String, dynamic>)['dir'],
      isNotNull,
    );
  });

  test('list_projects tells the model what each project ships', () async {
    final Map<String, dynamic> data = await mcp.call('list_projects');
    expect(data['ok'], isTrue);
    final List<dynamic> projects = data['projects'] as List<dynamic>;
    expect(projects, hasLength(1));
    expect(projects.first, containsPair('name', 'Gush'));
    expect(projects.first, containsPair('platforms', <String>['ios']));
  });

  test('pull_arbs preview on an iOS project names the catalog, not an ARB template', () async {
    final Map<String, dynamic> data = await mcp.call('pull_arbs');
    expect(data['ok'], isTrue, reason: data.toString());
    expect(data['applied'], isFalse);
    expect(data['catalog'], 'Localizable.xcstrings');
    expect(data.containsKey('template'), isFalse);
    expect(data['dir'], catalogDir());
    expect(data['service_keys'], 1);
    expect(data['message'], contains('apply=true'));
  });

  test('pull_arbs preview on a mixed project names both files and the ARB folder', () async {
    backend.platforms = <String>['flutter', 'ios'];
    final Map<String, dynamic> data = await mcp.call('pull_arbs');
    expect(data['ok'], isTrue, reason: data.toString());
    expect(data['template'], 'app_en.arb');
    expect(data['catalog'], 'Localizable.xcstrings');
    expect(data['dir'], p.join(tmp.path, 'lib', 'l10n'));
  });

  test('pull_arbs apply with no git clone writes the catalog from the API, byte for byte', () async {
    final Map<String, dynamic> data = await mcp.call('pull_arbs', <String, dynamic>{'apply': true});
    expect(data['ok'], isTrue, reason: data.toString());
    expect(data['applied'], isTrue);
    expect(data['method'], 'api');
    expect(data['git_skipped'], 'notARepo');
    expect(catalogFile().readAsStringSync(), kServedCatalog);
    expect(File(p.join(catalogDir(), 'InfoPlist.xcstrings')).existsSync(), isFalse,
        reason: 'an empty InfoPlist table is not written');
    expect(
      tmp.listSync(recursive: true).where((final FileSystemEntity e) => e.path.endsWith('.arb')),
      isEmpty,
      reason: 'an iOS-only project has no ARBs',
    );
  });

  test('pull_arbs refuses to overwrite a key added in Xcode, then adopts it on request', () async {
    catalogFile().writeAsStringSync(kCatalogWithLocalKey);

    final Map<String, dynamic> refused = await mcp.call('pull_arbs', <String, dynamic>{'apply': true});
    expect(refused['ok'], isFalse);
    expect(refused['local_only_keys'], <String>['local only']);
    expect(refused['message'], contains('Localizable.xcstrings'));
    expect(backend.imports, isEmpty);
    expect(catalogFile().readAsStringSync(), kCatalogWithLocalKey, reason: 'nothing was written');

    final Map<String, dynamic> adopted =
        await mcp.call('pull_arbs', <String, dynamic>{'apply': true, 'adopt': true});
    expect(adopted['ok'], isTrue, reason: adopted.toString());
    expect(backend.imports, hasLength(1));
    expect(backend.imports.single.hasLanguage, isFalse, reason: 'a catalog names its own locales');
    expect(backend.imports.single.fileName, 'Localizable.xcstrings');
    expect(backend.imports.single.body, contains('"local only"'));
    expect(adopted['steps'], hasLength(1));
    expect(catalogFile().readAsStringSync(), kServedCatalog, reason: 'the service copy wins after the import');
  });

  test('import_arb with a catalog path previews without a language and applies without one', () async {
    final File staged = File(p.join(tmp.path, 'Staged.xcstrings'))..writeAsStringSync(kCatalogWithLocalKey);

    final Map<String, dynamic> preview = await mcp.call('import_arb', <String, dynamic>{'path': staged.path});
    expect(preview['ok'], isTrue, reason: preview.toString());
    expect(preview['format'], 'xcstrings');
    expect(preview['keys'], 2);
    expect(preview.containsKey('language'), isFalse);
    expect(preview['message'], contains('every locale in the file'));
    expect(backend.imports, isEmpty);

    final Map<String, dynamic> applied =
        await mcp.call('import_arb', <String, dynamic>{'path': staged.path, 'apply': true});
    expect(applied['ok'], isTrue, reason: applied.toString());
    expect(backend.imports, hasLength(1));
    expect(backend.imports.single.hasLanguage, isFalse);
    expect(backend.imports.single.fileName, 'Staged.xcstrings');
    expect(applied['locales'], <String>['en']);
  });

  test('import_arb with an ARB still carries the language', () async {
    backend.platforms = <String>['flutter'];
    final File arb = File(p.join(tmp.path, 'app_en.arb'))..writeAsStringSync('{"@@locale": "en", "k": "v"}');
    final Map<String, dynamic> applied =
        await mcp.call('import_arb', <String, dynamic>{'path': arb.path, 'apply': true});
    expect(applied['ok'], isTrue, reason: applied.toString());
    expect(backend.imports.single.hasLanguage, isTrue);
    expect(backend.imports.single.fileName, 'app_en.arb');
  });

  test('a missing file is a tool error, not a crash', () async {
    final Map<String, dynamic> data =
        await mcp.call('import_arb', <String, dynamic>{'path': p.join(tmp.path, 'nope.xcstrings')});
    expect(data['ok'], isFalse);
    expect(data['_isError'], isTrue);
    expect(data['error'], contains('File not found'));
  });
}
