/// One project whose iPhone app ships more languages than its website: the
/// website's repository keeps to its own.
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fake_backend.dart';
import 'fl_mcp_test.dart' show McpProcess;

class Run {
  Run(this.code, this.out, this.err);

  final int code;
  final String out;
  final String err;

  Map<String, dynamic> get json =>
      jsonDecode(out.substring(out.indexOf('{'))) as Map<String, dynamic>;
}

void main() {
  late FakeBackend backend;
  late Directory web;

  Future<Run> fl(final List<String> args) async {
    final ProcessResult r = await Process.run(
      'dart',
      <String>['run', p.join(packageRoot(), 'bin', 'fl.dart'), ...args],
      workingDirectory: web.path,
      environment: <String, String>{
        'FL_API_TOKEN': 'flk_live_test',
        'HOME': web.path,
      },
    );
    return Run(r.exitCode, r.stdout as String, r.stderr as String);
  }

  File at(final String rel) => File(p.join(web.path, rel));

  void writeConfig(
          [final Map<String, Object> extra = const <String, Object>{}]) =>
      at('flutterlocalisation.json')
          .writeAsStringSync(jsonEncode(<String, Object>{
        'base_url': backend.url,
        'project': 'Gush',
        'platforms': <String>['angular'],
        'angular_dir': 'src/locale',
        ...extra,
      }));

  List<String> arbs() => <String>[
        for (final FileSystemEntity e
            in Directory(p.join(web.path, 'src', 'locale')).listSync())
          p.basename(e.path),
      ]..sort();

  void haveFrench() => at('src/locale/messages.fr.arb')
    ..createSync(recursive: true)
    ..writeAsStringSync('{"@@locale": "fr"}');

  setUpAll(() async => backend = await FakeBackend.start());
  tearDownAll(() => backend.close());

  setUp(() {
    backend
      ..platforms = <String>['angular', 'ios']
      ..languages = <String>['en', 'fr', 'de', 'ja']
      ..extraKeys = <String>[]
      ..platformText = false
      ..keyPlatforms = <String>[]
      ..serverPrune = null
      ..keptRecent = <String>[]
      ..targets = <String, Map<String, dynamic>>{
        for (final String code in <String>['fr', 'de', 'ja'])
          code: <String, dynamic>{'value': 'Cleaning… {arg1} s left'},
      };
    backend.imports.clear();
    backend.translated.clear();
    backend.updates.clear();
    web = Directory(Directory.systemTemp
        .createTempSync('fl_repo_locales')
        .resolveSymbolicLinksSync());
    at('angular.json').writeAsStringSync(jsonEncode(<String, dynamic>{
      'version': 1,
      'projects': <String, dynamic>{
        'site': <String, dynamic>{'projectType': 'application', 'root': ''},
      },
    }));
    writeConfig();
  });

  tearDown(() => web.deleteSync(recursive: true));

  test('a repository with no translated file yet takes every language',
      () async {
    final Run r = await fl(<String>['pull']);
    expect(r.code, 0, reason: r.err);
    expect(arbs(), <String>[
      'messages.de.arb',
      'messages.fr.arb',
      'messages.ja.arb',
    ]);
    expect(r.err, isNot(contains('"locales"')));
  });

  test('pull and export keep to the languages the repository has files for',
      () async {
    haveFrench();
    for (final String command in <String>['pull', 'export']) {
      final Run r = await fl(<String>[command]);
      expect(r.code, 0, reason: r.err);
      expect(arbs(), <String>['messages.fr.arb'], reason: command);
      expect(
          r.err,
          contains('This repository ships fr; de, ja have no file here and '
              'are left to iOS. Pin it with "locales": ["fr"]'));
    }
    final Map<String, dynamic> listed =
        jsonDecode(at('angular.json').readAsStringSync())
            as Map<String, dynamic>;
    expect(
        ((((listed['projects'] as Map)['site'] as Map)['i18n']
                as Map)['locales'] as Map)
            .keys,
        <String>['fr']);
  });

  test('status and a retranslation with no locale cover those languages only',
      () async {
    haveFrench();
    Run r = await fl(<String>['status', '--json']);
    expect(r.code, 0, reason: r.err);
    expect(
        <String>[
          for (final dynamic l in r.json['locales'] as List<dynamic>)
            (l as Map<String, dynamic>)['locale'] as String,
        ]..sort(),
        <String>['en', 'fr']);

    r = await fl(<String>['retranslate', '--json']);
    expect(r.code, 0, reason: r.err);
    expect(r.json['per_locale'], <String, dynamic>{'fr': 1});
    expect(backend.translated.single, <int>[501]);
  });

  test('a locale named on the command is worked on wherever it ships',
      () async {
    haveFrench();
    final Run r = await fl(
        <String>['retranslate', '--locale', 'de', '--dry-run', '--json']);
    expect(r.code, 0, reason: r.err);
    expect(r.json['per_locale'], <String, dynamic>{'de': 1});
  });

  test('"locales" in the config decides, files or not', () async {
    haveFrench();
    writeConfig(<String, Object>{
      'locales': <String>['fr', 'de'],
    });
    final Run r = await fl(<String>['pull']);
    expect(r.code, 0, reason: r.err);
    expect(arbs(), <String>['messages.de.arb', 'messages.fr.arb']);
    expect(r.err, isNot(contains('Pin it with "locales"')));
  });

  test('a project with one platform is never narrowed by its files', () async {
    backend.platforms = <String>['angular'];
    haveFrench();
    final Run r = await fl(<String>['pull']);
    expect(r.code, 0, reason: r.err);
    expect(arbs(), hasLength(3));
  });

  test('"locales" must be a list of codes', () async {
    writeConfig(<String, Object>{'locales': 'fr'});
    final Run r = await fl(<String>['status']);
    expect(r.code, isNot(0));
    expect(r.err, contains('"locales" must list the languages'));
  });

  test('languages list says what is not shipped here', () async {
    haveFrench();
    final Run r = await fl(<String>['languages', 'list']);
    expect(r.code, 0, reason: r.err);
    expect(r.out, contains(RegExp(r'fr: \d+/\d+ filled\n')));
    expect(r.out, contains(RegExp(r'de: .*not shipped by this repository')));
  });

  test('a language added from a narrowed repository is listed in its config',
      () async {
    haveFrench();
    final Run r = await fl(<String>['languages', 'add', 'es']);
    expect(r.code, 0, reason: r.err);
    expect(r.err, contains('Listed es under "locales"'));
    final Map<String, dynamic> cfg =
        jsonDecode(at('flutterlocalisation.json').readAsStringSync())
            as Map<String, dynamic>;
    expect(cfg['locales'], <String>['fr', 'es']);
    expect(cfg['angular_dir'], 'src/locale');

    final Run pull = await fl(<String>['pull']);
    expect(pull.code, 0, reason: pull.err);
    expect(arbs(), <String>['messages.es.arb', 'messages.fr.arb']);
  });

  test('several languages added at once are all listed', () async {
    haveFrench();
    final Run r = await fl(<String>['languages', 'add', 'es', 'it']);
    expect(r.code, 0, reason: r.err);
    final Map<String, dynamic> cfg =
        jsonDecode(at('flutterlocalisation.json').readAsStringSync())
            as Map<String, dynamic>;
    expect(cfg['locales'], <String>['fr', 'es', 'it']);
  });

  test(
      'a language added to a repository that takes them all leaves the '
      'config alone', () async {
    final String before = at('flutterlocalisation.json').readAsStringSync();
    final Run r = await fl(<String>['languages', 'add', 'es']);
    expect(r.code, 0, reason: r.err);
    expect(at('flutterlocalisation.json').readAsStringSync(), before);
  });

  test('retranslate prints each value it wrote beside its source', () async {
    haveFrench();
    final Run r = await fl(<String>['retranslate']);
    expect(r.code, 0, reason: r.err);
    // The source holds an ellipsis, which a Windows console does not print
    // as UTF-8.
    expect(r.out, contains('  fr  running %lld: "Cleaning'));
    expect(r.out, contains(' s left" -> "Translated (fr)"'));
    final Run json =
        await fl(<String>['retranslate', '--locale', 'de', '--json']);
    final Map<String, dynamic> row =
        (json.json['written'] as List<dynamic>).single as Map<String, dynamic>;
    expect(row['locale'], 'de');
    expect(row['key'], 'running %lld');
    expect(row['source'], startsWith('Cleaning'));
    expect(row['value'], 'Translated (de)');
  });

  test(r'edit takes a placeholder written the Angular way, {$NAME}', () async {
    final Run r = await fl(<String>[
      'edit',
      'running %lld',
      '--locale',
      'fr',
      '--value',
      r'Nettoyage, {$arg1} s',
    ]);
    expect(r.code, 0, reason: '${r.out}${r.err}');
    expect(backend.updates.single['value'], 'Nettoyage, {arg1} s');
  });

  test('a prune names every key it deleted and the young ones it kept',
      () async {
    final List<String> gone = <String>[for (int i = 0; i < 14; i++) 'old.k$i'];
    backend
      ..serverPrune = (pruned: gone, unshipped: <String>[])
      ..keptRecent = <String>['new.fromAnotherCheckout'];
    at('src/locale/messages.arb')
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(<String, dynamic>{
        '@@locale': 'en',
        'home.title': 'Hello',
        '@home.title': <String, dynamic>{
          'x-locations': <dynamic>[
            <String, String>{'file': 'a.ts'},
          ],
        },
      }));
    final Run r =
        await fl(<String>['import', 'src/locale/messages.arb', '--prune']);
    expect(r.code, 0, reason: r.err);
    expect(
        r.out,
        contains('Deleted 14 key(s) the file no longer has: '
            '${gone.join(', ')}'));
    expect(r.out, isNot(contains('…')));
    expect(
        r.out,
        contains('Kept 1 key(s) the file does not have, added in the last 24 '
            'hours (another checkout may not have committed them yet): '
            'new.fromAnotherCheckout.'));
  });

  group('the MCP server', () {
    late McpProcess mcp;

    Future<Map<String, dynamic>> call(
        final String tool, final Map<String, dynamic> args) async {
      final Map<String, dynamic> data = await mcp.call(tool, args);
      return (data['data'] ?? data) as Map<String, dynamic>;
    }

    setUp(() async {
      haveFrench();
      mcp = await McpProcess.start(
          baseUrl: backend.url, workingDirectory: web.path);
    });
    tearDown(() => mcp.stop());

    test('pull_arbs writes the languages the repository ships', () async {
      final Map<String, dynamic> first =
          await mcp.call('pull_arbs', <String, dynamic>{'apply': true});
      expect(arbs(), <String>['messages.fr.arb']);
      expect(first['repository_notice'],
          contains('de, ja have no file here and are left to iOS'));
      final Map<String, dynamic> second =
          await mcp.call('list_status', <String, dynamic>{});
      expect(second.containsKey('repository_notice'), isFalse);
    });

    test(
        'list_status and retranslate keep to them, and retranslate says '
        'what it wrote', () async {
      final Map<String, dynamic> status =
          await call('list_status', <String, dynamic>{});
      expect(
          <String>[
            for (final dynamic l in status['locales'] as List<dynamic>)
              (l as Map<String, dynamic>)['locale'] as String,
          ]..sort(),
          <String>['en', 'fr']);

      final Map<String, dynamic> done =
          await call('retranslate', <String, dynamic>{'apply': true});
      expect(done['per_locale'], <String, dynamic>{'fr': 1});
      final Map<String, dynamic> row =
          (done['written'] as List<dynamic>).single as Map<String, dynamic>;
      expect(row['locale'], 'fr');
      expect(row['value'], 'Translated (fr)');
    });

    test('add_language lists the new language in the config', () async {
      final Map<String, dynamic> added =
          await call('add_language', <String, dynamic>{
        'codes': <String>['es'],
        'apply': true
      });
      expect(added['locales_pinned'], <String>['es']);
      final Map<String, dynamic> cfg =
          jsonDecode(at('flutterlocalisation.json').readAsStringSync())
              as Map<String, dynamic>;
      expect(cfg['locales'], <String>['fr', 'es']);
    });

    test(r'edit_string takes {$NAME}', () async {
      await call('edit_string', <String, dynamic>{
        'key': 'running %lld',
        'locale': 'fr',
        'value': r'Nettoyage, {$arg1} s',
        'apply': true,
      });
      expect(backend.updates.single['value'], 'Nettoyage, {arg1} s');
    });
  });
}
