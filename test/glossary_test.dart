import 'dart:convert';
import 'dart:io';

import 'package:flutter_localisation_cli/src/exceptions.dart';
import 'package:flutter_localisation_cli/src/glossary.dart';
import 'package:flutter_localisation_cli/src/management_client.dart';
import 'package:flutter_localisation_cli/src/operations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// A fake backend for the glossary endpoints and the batch translate path.
class _Backend {
  final List<Map<String, dynamic>> terms = <Map<String, dynamic>>[];
  final List<({String method, String path, Object? body})> calls =
      <({String method, String path, Object? body})>[];
  final List<int> translated = <int>[];

  http.Client get client => MockClient((final http.Request req) async {
        final Object? body = req.body.isEmpty ? null : jsonDecode(req.body);
        calls.add((method: req.method, path: req.url.path, body: body));
        final String path = req.url.path;
        if (path == '/api/projects/7/glossary/' && req.method == 'GET') {
          return _json(<String, dynamic>{'terms': terms, 'count': terms.length});
        }
        if (path == '/api/projects/7/glossary/' && req.method == 'POST') {
          final List<Map<String, dynamic>> created = <Map<String, dynamic>>[];
          final List<Map<String, dynamic>> updated = <Map<String, dynamic>>[];
          for (final dynamic raw in (body! as Map<String, dynamic>)['terms'] as List<dynamic>) {
            final Map<String, dynamic> t = raw as Map<String, dynamic>;
            final int at = terms.indexWhere((final Map<String, dynamic> e) =>
                (e['term'] as String).toLowerCase() == (t['term'] as String).toLowerCase());
            final Map<String, dynamic> row = <String, dynamic>{
              'id': at >= 0 ? terms[at]['id'] : terms.length + 1,
              'term': t['term'],
              'do_not_translate': t['do_not_translate'] ?? false,
              'case_sensitive': t['case_sensitive'] ?? false,
              'translations': t['translations'] ?? <String, dynamic>{},
              'note': t['note'] ?? '',
              'string_count': 2,
            };
            if (at >= 0) {
              terms[at] = row;
              updated.add(row);
            } else {
              terms.add(row);
              created.add(row);
            }
          }
          return _json(<String, dynamic>{'created': created, 'updated': updated}, 201);
        }
        if (path.startsWith('/api/projects/7/glossary/') && req.method == 'DELETE') {
          terms.removeWhere((final Map<String, dynamic> e) => path.endsWith('/${e['id']}/'));
          return http.Response('', 204);
        }
        if (path == '/api/projects/7/glossary/suggestions/') {
          return _json(<String, dynamic>{
            'suggestions': <Map<String, dynamic>>[
              <String, dynamic>{'term': 'Dictee', 'reason': 'project name', 'string_count': 3, 'do_not_translate': true},
              <String, dynamic>{'term': 'Mac', 'reason': 'recurring name', 'string_count': 2, 'do_not_translate': false},
            ],
          });
        }
        if (path == '/api/projects/7/language-styles/' && req.method == 'GET') {
          return _json(<String, dynamic>{
            'languages': <Map<String, dynamic>>[
              <String, dynamic>{'code': 'de', 'formality': 'formal', 'instructions': '', 'inherited_from': null},
              <String, dynamic>{'code': 'de-AT', 'formality': 'formal', 'instructions': '', 'inherited_from': 'de'},
            ],
          });
        }
        if (path == '/api/projects/7/language-styles/' && req.method == 'PUT') {
          return _json(<String, dynamic>{...(body! as Map<String, dynamic>)}, 201);
        }
        if (path.startsWith('/api/projects/7/language-styles/') && req.method == 'DELETE') {
          return http.Response('', 204);
        }
        if (path == '/api/projects/7/translation_keys/do-not-translate/') {
          final Map<String, dynamic> b = body! as Map<String, dynamic>;
          return _json(<String, dynamic>{
            'updated': (b['keys'] as List<dynamic>).length,
            'do_not_translate': b['do_not_translate'],
            'values_copied': b['do_not_translate'] == true ? 4 : 0,
          });
        }
        if (path == '/api/projects/7/') return _json(_project(translated));
        if (path == '/api/ai_batch_translate/') {
          final List<int> ids = ((body! as Map<String, dynamic>)['translation_ids'] as List<dynamic>).cast<int>();
          translated.addAll(ids);
          return _json(<String, dynamic>{
            'status': 'success',
            'results': <String, dynamic>{'successful': <dynamic>[], 'failed': <dynamic>[]},
          });
        }
        return http.Response('unexpected ${req.method} $path', 500);
      });

  static http.Response _json(final Object body, [final int status = 200]) =>
      http.Response(jsonEncode(body), status,
          headers: <String, String>{'content-type': 'application/json; charset=utf-8'});
}

/// en base with three strings; de holds translations that change once sent.
Map<String, dynamic> _project(final List<int> translated) {
  String de(final int id, final String before) => translated.contains(id) ? '$before*' : before;
  return <String, dynamic>{
    'id': 7,
    'name': 'Dictee',
    'flavors': <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 3,
        'name': 'default',
        'languages': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 1,
            'code': 'en',
            'is_base_language': true,
            'translations': <Map<String, dynamic>>[
              <String, dynamic>{'id': 1, 'key': 'a', 'value': 'Open Dictee'},
              <String, dynamic>{'id': 2, 'key': 'b', 'value': 'Professional'},
              <String, dynamic>{'id': 3, 'key': 'c', 'value': 'Get Pro'},
            ],
          },
          <String, dynamic>{
            'id': 2,
            'code': 'de',
            'is_base_language': false,
            'translations': <Map<String, dynamic>>[
              <String, dynamic>{'id': 11, 'key': 'a', 'value': de(11, 'Diktat öffnen')},
              <String, dynamic>{'id': 12, 'key': 'b', 'value': de(12, 'Professionell')},
              <String, dynamic>{'id': 13, 'key': 'c', 'value': de(13, 'Pro holen')},
            ],
          },
        ],
      },
    ],
  };
}

void main() {
  late _Backend backend;
  late ManagementClient client;
  late GlossaryOperations g;
  late Operations ops;

  setUp(() {
    backend = _Backend();
    client = ManagementClient(baseUrl: 'http://x', token: 't', httpClient: backend.client, maxRetries: 0);
    g = GlossaryOperations(client, 7);
    ops = Operations(client, 7);
  });

  group('parsing', () {
    test('--as pairs are canonicalised', () {
      expect(parseTermTranslations(<String>['de=Schnipsel', 'pt_br = Trechos ']),
          <String, String>{'de': 'Schnipsel', 'pt-BR': 'Trechos'});
    });

    test('a malformed --as is refused', () {
      for (final String bad in <String>['de', '=x', 'de=']) {
        expect(() => parseTermTranslations(<String>[bad]), throwsA(isA<ManagementException>()));
      }
    });

    test('term matching follows the backend: whole words, punctuation-safe', () {
      expect(termPattern('Pro').hasMatch('Go Pro'), isTrue);
      expect(termPattern('Pro').hasMatch('Professional'), isFalse);
      expect(termPattern('C++').hasMatch('in C++ code'), isTrue);
      expect(termPattern('dictee').hasMatch('Open Dictee'), isTrue);
      expect(termPattern('dictee', caseSensitive: true).hasMatch('Open Dictee'), isFalse);
      expect(termPattern('Été').hasMatch('Bel été'), isTrue);
    });
  });

  group('glossary files', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('fl_glossary'));
    tearDown(() => dir.deleteSync(recursive: true));

    String write(final String name, final String text) {
      final File f = File('${dir.path}/$name')..writeAsStringSync(text);
      return f.path;
    }

    test('JSON as a list or under "terms"; keep is an alias', () {
      final String a = write('a.json', jsonEncode(<dynamic>[<String, dynamic>{'term': 'Dictee', 'keep': true}]));
      final String b = write('b.json', jsonEncode(<String, dynamic>{
        'terms': <dynamic>[<String, dynamic>{'term': 'Snippets', 'translations': <String, String>{'de': 'Schnipsel'}, 'note': 'n'}],
      }));
      expect(readGlossaryFile(a), <Map<String, dynamic>>[<String, dynamic>{'term': 'Dictee', 'do_not_translate': true}]);
      expect(readGlossaryFile(b).single['translations'], <String, String>{'de': 'Schnipsel'});
      expect(readGlossaryFile(b).single['note'], 'n');
    });

    test('CSV with quoted cells, locale columns and flags', () {
      final String path = write('g.csv',
          'term,keep,note,de,pt_br\r\nDictee,yes,,,\n"Snippets","","the ""feature"", saved text",Schnipsel,Trechos\n\n');
      final List<Map<String, dynamic>> terms = readGlossaryFile(path);
      expect(terms, hasLength(2));
      expect(terms[0], <String, dynamic>{'term': 'Dictee', 'do_not_translate': true});
      expect(terms[1]['note'], 'the "feature", saved text');
      expect(terms[1]['translations'], <String, String>{'de': 'Schnipsel', 'pt-BR': 'Trechos'});
    });

    test('bad files are explained', () {
      expect(() => readGlossaryFile('${dir.path}/missing.json'), throwsA(isA<ManagementException>()));
      expect(() => readGlossaryFile(write('x.json', '{')), throwsA(isA<ManagementException>()));
      expect(() => readGlossaryFile(write('y.json', '{"terms": 3}')), throwsA(isA<ManagementException>()));
      expect(() => readGlossaryFile(write('z.json', '[1]')), throwsA(isA<ManagementException>()));
      expect(() => readGlossaryFile(write('w.csv', 'name,de\nx,y\n')), throwsA(isA<ManagementException>()));
      expect(readGlossaryFile(write('e.csv', '')), isEmpty);
    });

    test('import sends everything in one request and export reads back', () async {
      final String path = write('in.json', jsonEncode(<dynamic>[
        <String, dynamic>{'term': 'Dictee', 'keep': true},
        <String, dynamic>{'term': 'Snippets', 'translations': <String, String>{'de': 'Schnipsel'}},
      ]));
      final OpResult r = await g.importFile(path);
      expect(r.ok, isTrue);
      expect(r.message, contains('2 added, 0 updated'));
      expect(backend.calls.where((final c) => c.method == 'POST'), hasLength(1));

      final String out = '${dir.path}/out.json';
      expect((await g.export(out)).message, 'Wrote 2 term(s) to $out.');
      expect(readGlossaryFile(out).map((final Map<String, dynamic> t) => t['term']), <String>['Dictee', 'Snippets']);

      final OpResult again = await g.importFile(out);
      expect(again.message, contains('0 added, 2 updated'));
    });

    test('import dry run and an empty file', () async {
      expect((await g.importFile(write('d.json', '[{"term":"A"}]'), dryRun: true)).message, contains('Would save 1'));
      expect((await g.importFile(write('n.json', '[]'))).ok, isFalse);
      expect(backend.calls.where((final c) => c.method == 'POST'), isEmpty);
    });
  });

  group('terms', () {
    test('add, list, update and remove', () async {
      expect((await g.list()).message, contains('glossary is empty'));
      final OpResult added = await g.add('Dictee', keep: true);
      expect(added.message, 'Added "Dictee" (kept as written); it occurs in 2 string(s). '
          'Strings already translated keep their text until `fl glossary apply` re-translates them.');
      final OpResult updated = await g.add('dictee', translations: <String, String>{'de': 'Diktat'});
      expect(updated.message, startsWith('Updated "dictee" (de: Diktat)'));
      expect((await g.list()).message, '1 glossary term(s).');
      expect(GlossaryOperations.describeTerm(backend.terms.single), 'dictee → de: Diktat  [2 string(s)]');
      expect((await g.remove('DICTEE')).message, 'Removed "dictee".');
      expect((await g.remove('nope')).ok, isFalse);
    });

    test('keep and --as together, and an empty term, are refused before any call', () async {
      await expectLater(g.add('X', keep: true, translations: <String, String>{'de': 'Y'}), throwsA(isA<ManagementException>()));
      await expectLater(g.add('  '), throwsA(isA<ManagementException>()));
      expect(backend.calls, isEmpty);
    });

    test('dry runs change nothing', () async {
      expect((await g.add('A', dryRun: true)).message, 'Would save "A".');
      await g.add('B');
      expect((await g.remove('B', dryRun: true)).message, 'Would remove "B".');
      expect(backend.terms, hasLength(1));
    });

    test('suggest lists, and --apply adds them all', () async {
      final OpResult listed = await g.suggest();
      expect((listed.data['suggestions'] as List<dynamic>).length, 2);
      expect(backend.terms, isEmpty);
      final OpResult applied = await g.suggest(apply: true);
      expect(applied.message, startsWith('Added 2 term(s).'));
      expect(backend.terms.first['do_not_translate'], isTrue);
      expect(backend.terms.last['do_not_translate'], isFalse);
    });
  });

  group('apply', () {
    test('re-translates only strings containing the terms, every locale but the base', () async {
      backend.terms.add(<String, dynamic>{'id': 1, 'term': 'Pro', 'do_not_translate': true, 'translations': <String, dynamic>{}});
      final OpResult r = await g.apply(ops);
      expect(backend.translated, <int>[13], reason: '"Professional" is not "Pro"');
      expect(r.message, 'Re-translated 1 value(s) of 1 string(s).');
    });

    test('--term narrows, --all widens, unknown terms are named', () async {
      backend.terms
        ..add(<String, dynamic>{'id': 1, 'term': 'Pro', 'translations': <String, dynamic>{}})
        ..add(<String, dynamic>{'id': 2, 'term': 'Dictee', 'translations': <String, dynamic>{}});
      await g.apply(ops, only: <String>['dictee']);
      expect(backend.translated, <int>[11]);
      expect((await g.apply(ops, only: <String>['Ghost'])).message, 'Not in the glossary: ghost.');
      final OpResult dry = await g.apply(ops, all: true, dryRun: true);
      expect(dry.message, 'DRY RUN: would re-translate 3 value(s) of 3 string(s).');
    });

    test('an empty glossary or no match does nothing', () async {
      expect((await g.apply(ops)).ok, isFalse);
      backend.terms.add(<String, dynamic>{'id': 1, 'term': 'Nowhere', 'translations': <String, dynamic>{}});
      expect((await g.apply(ops)).message, 'No translated string uses these terms.');
      expect(backend.translated, isEmpty);
    });
  });

  group('styles and locks', () {
    test('list, set and clear', () async {
      final OpResult listed = await g.styles();
      expect((listed.data['languages'] as List<dynamic>).last['inherited_from'], 'de');
      final OpResult set = await g.setStyle('de_at', formality: 'informal', instructions: 'Short.');
      expect(set.message, startsWith('de-AT: informal, with instructions.'));
      expect(backend.calls.last.body, <String, dynamic>{'code': 'de-AT', 'formality': 'informal', 'instructions': 'Short.'});
      expect((await g.setStyle('fr', formality: '', dryRun: true)).message, "Would set fr to translator's choice.");
      expect((await g.clearStyle('de-AT')).message, 'Cleared the style of de-AT.');
      expect(backend.calls.last.path, '/api/projects/7/language-styles/de-AT/');
      expect((await g.clearStyle('fr', dryRun: true)).message, 'Would clear the style of fr.');
    });

    test('lock and unlock', () async {
      final OpResult locked = await g.lock(<String>['brand', 'url']);
      expect(locked.message, startsWith('Locked 2 key(s): every locale now shows the base text (4 value(s) reset)'));
      final OpResult unlocked = await g.lock(<String>['brand'], on: false);
      expect(unlocked.message, startsWith('Unlocked 1 key(s).'));
      expect((await g.lock(<String>['x'], dryRun: true)).message, 'Would lock 1 key(s).');
      await expectLater(g.lock(<String>[]), throwsA(isA<ManagementException>()));
    });
  });
}
