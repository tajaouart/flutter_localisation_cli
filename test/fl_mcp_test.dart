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
      (final String line) =>
          (jsonDecode(line) as Map<String, dynamic>)['id'] == id,
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
    final Map<String, dynamic> reply = await request(
        'tools/call', <String, dynamic>{'name': name, 'arguments': arguments});
    final Map<String, dynamic> result = reply['result'] as Map<String, dynamic>;
    final List<dynamic> content = result['content'] as List<dynamic>;
    final Map<String, dynamic> data =
        jsonDecode((content.first as Map<String, dynamic>)['text'] as String)
            as Map<String, dynamic>;
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
    tmp = Directory(Directory.systemTemp
        .createTempSync('fl_mcp_test')
        .resolveSymbolicLinksSync());
    File(p.join(tmp.path, 'flutterlocalisation.json'))
        .writeAsStringSync(jsonEncode(<String, String>{
      'base_url': backend.url,
      'project': 'Gush',
      'arb_dir': 'lib/l10n',
      'xcstrings_dir': 'Resources',
    }));
    mcp = await McpProcess.start(
        baseUrl: backend.url, workingDirectory: tmp.path);
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

  test('initialize names the server and tools/list carries the catalog tools',
      () async {
    final Map<String, dynamic> init =
        await mcp.request('initialize', <String, dynamic>{
      'protocolVersion': '2024-11-05',
      'capabilities': <String, dynamic>{},
      'clientInfo': <String, String>{'name': 'test', 'version': '0'},
    });
    expect((init['result'] as Map<String, dynamic>)['serverInfo'],
        containsPair('name', 'flutter-localisation'));

    final Map<String, dynamic> list = await mcp.request('tools/list');
    final List<dynamic> tools =
        (list['result'] as Map<String, dynamic>)['tools'] as List<dynamic>;
    final Map<String, Map<String, dynamic>> byName =
        <String, Map<String, dynamic>>{
      for (final dynamic t in tools)
        (t as Map<String, dynamic>)['name'] as String: t,
    };
    expect(byName.keys,
        containsAll(<String>['list_projects', 'import_arb', 'pull_arbs']));
    expect(byName['import_arb']!['description'], contains('.xcstrings'));
    final Map<String, dynamic> importProps =
        (byName['import_arb']!['inputSchema']
            as Map<String, dynamic>)['properties'] as Map<String, dynamic>;
    expect((importProps['path'] as Map<String, dynamic>)['description'],
        contains('.xcstrings'));
    expect(
      ((byName['pull_arbs']!['inputSchema']
              as Map<String, dynamic>)['properties']
          as Map<String, dynamic>)['dir'],
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

  test(
      'pull_arbs preview on an iOS project names the catalog, not an ARB template',
      () async {
    final Map<String, dynamic> data = await mcp.call('pull_arbs');
    expect(data['ok'], isTrue, reason: data.toString());
    expect(data['applied'], isFalse);
    expect(data['catalog'], 'Localizable.xcstrings');
    expect(data.containsKey('template'), isFalse);
    expect(data['dir'], catalogDir());
    expect(data['service_keys'], 1);
    expect(data['message'], contains('apply=true'));
  });

  test(
      'pull_arbs preview on a mixed project names both files and the ARB folder',
      () async {
    backend.platforms = <String>['flutter', 'ios'];
    // A Flutter app with native iOS strings: pubspec.yaml and the Xcode
    // project show both platforms.
    File(p.join(tmp.path, 'pubspec.yaml'))
        .writeAsStringSync('dependencies:\n  flutter:\n    sdk: flutter\n');
    Directory(p.join(tmp.path, 'ios', 'Runner.xcodeproj'))
        .createSync(recursive: true);
    final Map<String, dynamic> data = await mcp.call('pull_arbs');
    expect(data['ok'], isTrue, reason: data.toString());
    expect(data['template'], 'app_en.arb');
    expect(data['catalog'], 'Localizable.xcstrings');
    expect(data['dir'], p.join(tmp.path, 'lib', 'l10n'));
    File(p.join(tmp.path, 'pubspec.yaml')).deleteSync();
    Directory(p.join(tmp.path, 'ios')).deleteSync(recursive: true);
  });

  test(
      'pull_arbs apply with no git clone writes the catalog from the API, byte for byte',
      () async {
    final Map<String, dynamic> data =
        await mcp.call('pull_arbs', <String, dynamic>{'apply': true});
    expect(data['ok'], isTrue, reason: data.toString());
    expect(data['applied'], isTrue);
    expect(data['method'], 'api');
    expect(data['git_skipped'], 'notARepo');
    expect(catalogFile().readAsStringSync(), kServedCatalog);
    expect(
        File(p.join(catalogDir(), 'InfoPlist.xcstrings')).existsSync(), isFalse,
        reason: 'an empty InfoPlist table is not written');
    expect(
      tmp
          .listSync(recursive: true)
          .where((final FileSystemEntity e) => e.path.endsWith('.arb')),
      isEmpty,
      reason: 'an iOS-only project has no ARBs',
    );
  });

  test(
      'pull_arbs refuses to overwrite a key added in Xcode, then adopts it on request',
      () async {
    catalogFile().writeAsStringSync(kCatalogWithLocalKey);

    final Map<String, dynamic> refused =
        await mcp.call('pull_arbs', <String, dynamic>{'apply': true});
    expect(refused['ok'], isFalse);
    expect(refused['local_only_keys'], <String>['local only']);
    expect(refused['message'], contains('Localizable.xcstrings'));
    expect(backend.imports, isEmpty);
    expect(catalogFile().readAsStringSync(), kCatalogWithLocalKey,
        reason: 'nothing was written');

    final Map<String, dynamic> adopted = await mcp
        .call('pull_arbs', <String, dynamic>{'apply': true, 'adopt': true});
    expect(adopted['ok'], isTrue, reason: adopted.toString());
    expect(backend.imports, hasLength(1));
    expect(backend.imports.single.hasLanguage, isFalse,
        reason: 'a catalog names its own locales');
    expect(backend.imports.single.fileName, 'Localizable.xcstrings');
    expect(backend.imports.single.body, contains('"local only"'));
    expect(adopted['steps'], hasLength(1));
    expect(catalogFile().readAsStringSync(), kServedCatalog,
        reason: 'the service copy wins after the import');
  });

  test(
      'import_arb with a catalog path previews without a language and applies without one',
      () async {
    final File staged = File(p.join(tmp.path, 'Staged.xcstrings'))
      ..writeAsStringSync(kCatalogWithLocalKey);

    final Map<String, dynamic> preview =
        await mcp.call('import_arb', <String, dynamic>{'path': staged.path});
    expect(preview['ok'], isTrue, reason: preview.toString());
    expect(preview['format'], 'xcstrings');
    expect(preview['keys'], 2);
    expect(preview.containsKey('language'), isFalse);
    expect(preview['message'], contains('every locale in the file'));
    expect(backend.imports, isEmpty);

    final Map<String, dynamic> applied = await mcp.call(
        'import_arb', <String, dynamic>{'path': staged.path, 'apply': true});
    expect(applied['ok'], isTrue, reason: applied.toString());
    expect(backend.imports, hasLength(1));
    expect(backend.imports.single.hasLanguage, isFalse);
    expect(backend.imports.single.fileName, 'Staged.xcstrings');
    expect(applied['locales'], <String>['en']);
  });

  test(
      'pull_arbs on an Angular project writes messages.<locale>.arb from '
      'the API, never the source', () async {
    backend.platforms = <String>['angular'];
    backend.languages = <String>['en', 'fr'];
    addTearDown(() => backend.languages = <String>['en']);
    final Map<String, dynamic> data =
        await mcp.call('pull_arbs', <String, dynamic>{'apply': true});
    expect(data['ok'], isTrue, reason: data.toString());
    expect(data['method'], 'api');
    final File fr = File(p.join(tmp.path, 'src', 'locale', 'messages.fr.arb'));
    expect(jsonDecode(fr.readAsStringSync())['@@locale'], 'fr');
    expect(File(p.join(tmp.path, 'src', 'locale', 'messages.arb')).existsSync(),
        isFalse);
  });

  test('import_arb sends an Angular extraction without a language', () async {
    backend.platforms = <String>['angular'];
    final Map<String, dynamic> data =
        await mcp.call('import_arb', <String, dynamic>{
      'content':
          r'{"@@locale":"en-US","home.title":"Hi","@home.title":{"x-locations":[]}}',
      'apply': true,
    });
    expect(data['ok'], isTrue, reason: data.toString());
    expect(backend.imports.single.hasLanguage, isFalse);
  });

  test(
      'import_arb previews key by key, and prune deletes what only the '
      'service has', () async {
    backend.platforms = <String>['angular'];
    backend.deletedKeys.clear();
    const String source =
        r'{"@@locale":"en-US","home.title":"Hello (en)","home.new":"N","@home.title":{"x-locations":[]}}';
    final Map<String, dynamic> preview = await mcp.call(
        'import_arb', <String, dynamic>{
      'path': _write(tmp, 'messages.arb', source),
      'prune': true
    });
    expect(preview['ok'], isTrue, reason: preview.toString());
    final Map<String, dynamic> diff =
        (preview['data'] ?? preview)['diff'] as Map<String, dynamic>;
    expect(diff['added'], <String>['home.new']);
    expect(diff['gone'], <String>['home.greeting']);
    expect(backend.imports, isEmpty);

    final Map<String, dynamic> applied =
        await mcp.call('import_arb', <String, dynamic>{
      'path': p.join(tmp.path, 'messages.arb'),
      'prune': true,
      'apply': true,
    });
    expect(applied['ok'], isTrue, reason: applied.toString());
    expect(backend.deletedKeys, <String>['home.greeting']);
  });

  test('import_arb with an ARB still carries the language', () async {
    backend.platforms = <String>['flutter'];
    final File arb = File(p.join(tmp.path, 'app_en.arb'))
      ..writeAsStringSync('{"@@locale": "en", "k": "v"}');
    final Map<String, dynamic> applied = await mcp
        .call('import_arb', <String, dynamic>{'path': arb.path, 'apply': true});
    expect(applied['ok'], isTrue, reason: applied.toString());
    expect(backend.imports.single.hasLanguage, isTrue);
    expect(backend.imports.single.fileName, 'app_en.arb');
  });

  test('a missing file is a tool error, not a crash', () async {
    final Map<String, dynamic> data = await mcp.call('import_arb',
        <String, dynamic>{'path': p.join(tmp.path, 'nope.xcstrings')});
    expect(data['ok'], isFalse);
    expect(data['_isError'], isTrue);
    expect(data['error'], contains('File not found'));
  });

  test('language_style all=true sets one instruction for every language',
      () async {
    addTearDown(() => backend.projectInstructions = '');
    final Map<String, dynamic> preview = await mcp.call(
        'language_style', <String, dynamic>{
      'action': 'set',
      'all': true,
      'instructions': 'No dashes.'
    });
    expect(
        preview['message'], 'Would set the instructions for every language.');
    expect(backend.projectInstructions, isEmpty);

    final Map<String, dynamic> applied =
        await mcp.call('language_style', <String, dynamic>{
      'action': 'set',
      'all': true,
      'instructions': 'No dashes.',
      'apply': true,
    });
    expect(applied['ok'], isTrue, reason: applied.toString());
    expect(backend.projectInstructions, 'No dashes.');
    final Map<String, dynamic> listed =
        await mcp.call('language_style', <String, dynamic>{'action': 'list'});
    expect(listed['project_instructions'], 'No dashes.');

    final Map<String, dynamic> cleared = await mcp.call('language_style',
        <String, dynamic>{'action': 'clear', 'all': true, 'apply': true});
    expect(cleared['message'], 'Removed the instructions for every language.');
    expect(backend.projectInstructions, isEmpty);
  });

  test('language_style all=true refuses a locale, a formality or no text',
      () async {
    for (final Map<String, dynamic> arguments in <Map<String, dynamic>>[
      <String, dynamic>{'action': 'set', 'all': true, 'apply': true},
      <String, dynamic>{
        'action': 'set',
        'all': true,
        'locale': 'de',
        'instructions': 'x',
        'apply': true,
      },
      <String, dynamic>{
        'action': 'set',
        'all': true,
        'formality': 'formal',
        'instructions': 'x',
        'apply': true,
      },
      <String, dynamic>{
        'action': 'clear',
        'all': true,
        'locale': 'de',
        'apply': true
      },
    ]) {
      final Map<String, dynamic> reply = await mcp.request('tools/call',
          <String, dynamic>{'name': 'language_style', 'arguments': arguments});
      expect((reply['error'] as Map<String, dynamic>)['message'],
          contains('all=true takes instructions only'),
          reason: '$arguments');
    }
    expect(backend.projectInstructions, isEmpty);
  });

  test('retranslate changed=true redoes values of an older base text',
      () async {
    backend
      ..platforms = <String>['flutter']
      ..languages = <String>['en', 'de']
      ..targets = <String, Map<String, dynamic>>{
        'de': <String, dynamic>{'value': 'Alt {arg1}', 'is_outdated': true},
      };
    addTearDown(() {
      backend
        ..languages = <String>['en']
        ..targets = <String, Map<String, dynamic>>{};
      backend.translated.clear();
    });

    final Map<String, dynamic> plain =
        await mcp.call('retranslate', <String, dynamic>{'apply': true});
    expect(plain['outdated'], 1);
    expect(plain['message'], contains('fl retranslate --changed'));
    expect(backend.translated, isEmpty);

    final Map<String, dynamic> preview =
        await mcp.call('retranslate', <String, dynamic>{'changed': true});
    expect(preview['pending'], 1);
    expect(backend.translated, isEmpty);

    final Map<String, dynamic> applied = await mcp
        .call('retranslate', <String, dynamic>{'changed': true, 'apply': true});
    expect(applied['ok'], isTrue, reason: applied.toString());
    expect(applied['translated'], 1);
    expect(backend.translated, <List<int>>[
      <int>[501]
    ]);
  });

  test('a newer version is told to the agent once, in a tool result', () async {
    backend.latestVersion = '99.0.0';
    addTearDown(() => backend.latestVersion = null);
    final Map<String, dynamic> first = await mcp.call('list_projects');
    expect(first['update_notice'], contains('fl_mcp 99.0.0 is available'));
    expect(first['update_notice'],
        contains('dart pub global activate flutter_localisation_cli'));
    expect(first['_isError'], isFalse);
    final Map<String, dynamic> second = await mcp.call('list_projects');
    expect(second.containsKey('update_notice'), isFalse);
    expect(backend.clients.last, startsWith('fl_mcp/'));
  });

  test('a withdrawn version comes back as a tool error with the command',
      () async {
    backend
      ..latestVersion = '99.0.0'
      ..minimumVersion = '99.0.0';
    addTearDown(() {
      backend
        ..latestVersion = null
        ..minimumVersion = null;
    });
    final Map<String, dynamic> data = await mcp.call('list_projects');
    expect(data['_isError'], isTrue);
    expect(data['error'], contains('is no longer supported'));
    expect(data['error'],
        contains('dart pub global activate flutter_localisation_cli'));
  });

  // Last: it turns the shared folder into a git repository.
  test('pull_arbs inside the app\'s own git repository leaves its HEAD alone',
      () async {
    void git(final List<String> args, {final String? cwd}) {
      final ProcessResult r = Process.runSync(
        'git',
        <String>['-c', 'user.name=t', '-c', 'user.email=t@t', ...args],
        workingDirectory: cwd ?? tmp.path,
      );
      expect(r.exitCode, 0, reason: 'git ${args.join(' ')}: ${r.stderr}');
    }

    final Directory origin = Directory.systemTemp.createTempSync('fl_mcp_app');
    addTearDown(() => origin.deleteSync(recursive: true));
    File(p.join(origin.path, 'README.md')).writeAsStringSync('app\n');
    git(<String>['init', '-q', '-b', 'main'], cwd: origin.path);
    git(<String>['add', '.'], cwd: origin.path);
    git(<String>['commit', '-qm', 'app'], cwd: origin.path);

    git(<String>['init', '-q', '-b', 'feature']);
    git(<String>['remote', 'add', 'origin', origin.path]);
    git(<String>['fetch', '-q', 'origin']);
    git(<String>['add', 'flutterlocalisation.json']);
    git(<String>['commit', '-qm', 'feature work']);
    String head() => '${Process.runSync('git', <String>[
              'rev-parse',
              'HEAD'
            ], workingDirectory: tmp.path).stdout}'
        .trim();
    final String before = head();

    backend.platforms = <String>['ios'];
    Directory(catalogDir()).createSync(recursive: true);
    final Map<String, dynamic> data = await mcp.call(
        'pull_arbs', <String, dynamic>{'apply': true, 'discard_local': true});
    expect(data['ok'], isTrue, reason: data.toString());
    expect(data['method'], 'api');
    expect(head(), before);
    expect(File(p.join(tmp.path, 'flutterlocalisation.json')).existsSync(),
        isTrue);
  });

  test(
      'pull_arbs on an ngx-translate project guards the base file and writes JSON',
      () async {
    backend.platforms = <String>['ngx'];
    backend.languages = <String>['en', 'fr'];
    backend.extraKeys = <String>['home.title', 'home.greeting'];
    addTearDown(() {
      backend.extraKeys = <String>[];
      backend.languages = <String>['en'];
    });
    final Directory dir = Directory(p.join(tmp.path, 'i18n'))
      ..createSync(recursive: true);
    final File en = File(p.join(dir.path, 'en.json'))
      ..writeAsStringSync('{"home": {"title": "Hello", "new": "Brand new"}}');

    final Map<String, dynamic> refused = await mcp
        .call('pull_arbs', <String, dynamic>{'apply': true, 'dir': dir.path});
    expect(refused['ok'], isFalse);
    expect(refused['local_only_keys'], <String>['home.new']);
    expect(refused['message'], contains('en.json'));

    final Map<String, dynamic> adopted = await mcp.call('pull_arbs',
        <String, dynamic>{'apply': true, 'adopt': true, 'dir': dir.path});
    expect(adopted['ok'], isTrue, reason: adopted.toString());
    expect(backend.imports.single.language, 'en');
    expect(jsonDecode(en.readAsStringSync()), <String, dynamic>{
      'home': <String, dynamic>{
        'title': 'Hello (en)',
        'greeting': 'Hi {{name}} (en)',
      },
    });
    expect(File(p.join(dir.path, 'fr.json')).existsSync(), isTrue);

    File(p.join(tmp.path, 'package.json')).writeAsStringSync(
        '{"dependencies": {"@ngx-translate/core": "^16.0.0"}}');
    addTearDown(() => File(p.join(tmp.path, 'package.json')).deleteSync());
    final Map<String, dynamic> doctor = await mcp
        .call('check_l10n_setup', <String, dynamic>{'project_root': tmp.path});
    expect(doctor['ngx'], isTrue, reason: doctor.toString());
  });

  test(
      'tools/list: edit_string and add_string take a target, platforms and '
      'max_length, and shorten is a tool', () async {
    final List<dynamic> tools = ((await mcp.request('tools/list'))['result']
        as Map<String, dynamic>)['tools'] as List<dynamic>;
    Map<String, dynamic> props(final String name) =>
        ((tools.firstWhere((final dynamic t) => t['name'] == name)
                as Map<String, dynamic>)['inputSchema']
            as Map<String, dynamic>)['properties'] as Map<String, dynamic>;
    for (final String name in <String>['edit_string', 'add_string']) {
      expect(props(name)['platforms'], containsPair('type', 'array'));
      expect(props(name)['max_length'], containsPair('type', 'object'));
    }
    expect((props('edit_string')['target'] as Map<String, dynamic>)['enum'],
        containsAll(<String>['ios', 'flutter', 'ios/applewatch']));
    expect(props('translate_key'), contains('target'));
    expect(props('retranslate'), contains('target'));
    expect(props('shorten').keys,
        containsAll(<String>['target', 'keys', 'locales', 'apply']));
    final Map<String, dynamic> edit = tools.firstWhere(
            (final dynamic t) => t['name'] == 'edit_string')['inputSchema']
        as Map<String, dynamic>;
    expect(edit['required'], <String>['key']);
  });

  test('edit_string with a target writes that text; an empty value removes it',
      () async {
    backend
      ..platformText = true
      ..overrides = <String, List<Map<String, dynamic>>>{
        'en': <Map<String, dynamic>>[
          <String, dynamic>{'target': 'ios', 'value': '{arg1}s'},
        ],
      };
    backend.updates.clear();
    addTearDown(() => backend
      ..platformText = false
      ..overrides = <String, List<Map<String, dynamic>>>{});

    final Map<String, dynamic> preview = await mcp.call(
        'edit_string', <String, dynamic>{
      'key': 'running',
      'locale': 'en',
      'target': 'ios',
      'value': '{arg1} s'
    });
    expect(preview['ok'], isTrue, reason: preview.toString());
    expect(preview['message'], contains('DRY RUN'));
    expect(backend.updates, isEmpty);

    await mcp.call('edit_string', <String, dynamic>{
      'key': 'running',
      'locale': 'en',
      'target': 'ios',
      'value': '{arg1} s',
      'apply': true,
    });
    final Map<String, dynamic> cleared =
        await mcp.call('edit_string', <String, dynamic>{
      'key': 'running',
      'locale': 'en',
      'target': 'ios',
      'value': '',
      'platforms': <String>[],
      'apply': true,
    });
    expect(cleared['ok'], isTrue, reason: cleared.toString());
    expect(backend.updates, <Map<String, dynamic>>[
      <String, dynamic>{'id': 1, 'target': 'ios', 'value': '{arg1} s'},
      <String, dynamic>{'id': 1, 'target': 'ios', 'value': ''},
    ]);

    backend.keyPosts.clear();
    final Map<String, dynamic> limited =
        await mcp.call('edit_string', <String, dynamic>{
      'key': 'running',
      'max_length': <String, int>{'ios': 12},
      'apply': true,
    });
    expect(limited['ok'], isTrue, reason: limited.toString());
    expect(backend.keyPosts.single['max_length'], <String, int>{'ios': 12});
  });

  test('add_string sends platforms and max_length; shorten previews', () async {
    backend
      ..platformText = true
      ..platforms = <String>['flutter', 'ios']
      ..keyMaxLength = <String, int>{'ios': 4};
    backend.keyPosts.clear();
    addTearDown(() => backend
      ..platformText = false
      ..keyMaxLength = <String, int>{});

    final Map<String, dynamic> added =
        await mcp.call('add_string', <String, dynamic>{
      'key': 'promo',
      'value': 'Save now',
      'platforms': <String>['ios'],
      'max_length': <String, int>{'ios': 12},
      'apply': true,
    });
    expect(added['ok'], isTrue, reason: added.toString());
    expect(backend.keyPosts.single['platforms'], <String>['ios']);
    expect(backend.keyPosts.single['max_length'], <String, int>{'ios': 12});

    final Map<String, dynamic> shorten = await mcp.call('shorten');
    expect(shorten['ok'], isTrue, reason: shorten.toString());
    expect(shorten['target'], 'ios');
    expect(shorten['keys'], <String>['running %lld']);
  });

  test('fl_mcp reads base_url from flutterlocalisation.json', () async {
    final McpProcess fromConfig =
        await McpProcess.start(baseUrl: '', workingDirectory: tmp.path);
    addTearDown(fromConfig.stop);
    final Map<String, dynamic> data = await fromConfig.call('list_projects');
    expect(data['ok'], isTrue, reason: data.toString());
    expect(data['projects'], hasLength(1));
  });
}

String _write(final Directory dir, final String name, final String content) {
  final File f = File(p.join(dir.path, name))..writeAsStringSync(content);
  return f.path;
}
