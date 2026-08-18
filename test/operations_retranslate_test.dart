import 'dart:convert';

import 'package:flutter_localisation_cli/src/management_client.dart';
import 'package:flutter_localisation_cli/src/operations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// A locale row: its value, and whether a reviewer has marked it checked.
typedef Row = ({String value, bool checked});

Row v(final String value, {final bool checked = false}) =>
    (value: value, checked: checked);

/// A project whose base `en` holds [base] (key `k<i>` → value), plus one row
/// per entry in [locales].
String _project({
  required final List<String> base,
  final Map<String, List<Row>> locales = const <String, List<Row>>{},
}) =>
    jsonEncode(<String, dynamic>{
      'id': 7,
      'name': 'P',
      'flavors': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 3,
          'name': 'default',
          'languages': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 100,
              'code': 'en',
              'is_base_language': true,
              'translations': <Map<String, dynamic>>[
                for (int i = 0; i < base.length; i++)
                  <String, dynamic>{'id': i + 1, 'key': 'k$i', 'value': base[i]},
              ],
            },
            for (final MapEntry<String, List<Row>> e in locales.entries)
              <String, dynamic>{
                'id': 200 + locales.keys.toList().indexOf(e.key),
                'code': e.key,
                'is_base_language': false,
                'translations': <Map<String, dynamic>>[
                  for (int i = 0; i < e.value.length; i++)
                    <String, dynamic>{
                      'id': 1000 +
                          locales.keys.toList().indexOf(e.key) * 100 +
                          i,
                      'key': 'k$i',
                      'value': e.value[i].value,
                      'is_checked': e.value[i].checked,
                    },
                ],
              },
          ],
        },
      ],
    });

/// Serves [before] until the batch endpoint is hit, then [after]. Records every
/// `translation_ids` payload the caller sent.
({MockClient client, List<List<int>> batches}) _mock({
  required final String before,
  required final String after,
}) {
  final List<List<int>> batches = <List<int>>[];
  final MockClient client = MockClient((final http.Request req) async {
    if (req.url.path == '/api/ai_batch_translate/') {
      final Map<String, dynamic> body =
          jsonDecode(req.body) as Map<String, dynamic>;
      batches.add((body['translation_ids'] as List<dynamic>).cast<int>());
      return http.Response(
        jsonEncode(<String, dynamic>{'translated': batches.last.length}),
        200,
      );
    }
    return http.Response(batches.isEmpty ? before : after, 200);
  });
  return (client: client, batches: batches);
}

Operations _ops(final MockClient c) => Operations(
      ManagementClient(baseUrl: 'http://t', token: 'x', httpClient: c),
      7,
      flavor: 'default',
    );

void main() {
  test('selects empty values and values identical to the source', () async {
    final String before = _project(
      base: <String>['Hello', 'Bye', 'Save'],
      locales: <String, List<Row>>{
        'fr': <Row>[v('Bonjour'), v(''), v('Save')],
      },
    );
    final String after = _project(
      base: <String>['Hello', 'Bye', 'Save'],
      locales: <String, List<Row>>{
        'fr': <Row>[v('Bonjour'), v('Au revoir'), v('Enregistrer')],
      },
    );
    final ({List<List<int>> batches, MockClient client}) m =
        _mock(before: before, after: after);

    final OpResult r = await _ops(m.client).retranslate();

    expect(r.ok, isTrue);
    // k0 already differs from the source and must not be re-spent.
    expect(m.batches.single, <int>[1001, 1002]);
    expect(r.data['translated'], 2);
  });

  test('leaves a checked value that equals the source alone', () async {
    // "OK" is correct unchanged in French; a reviewer recorded that by
    // checking the row, so it must not come back every run.
    final String p = _project(
      base: <String>['OK', 'Save'],
      locales: <String, List<Row>>{
        'fr': <Row>[v('OK', checked: true), v('Save')],
      },
    );
    final ({List<List<int>> batches, MockClient client}) m =
        _mock(before: p, after: p);

    final OpResult r = await _ops(m.client).retranslate(dryRun: true);

    expect(r.data['pending'], 1, reason: 'only the unchecked row');
    expect(m.batches, isEmpty, reason: 'dry run must not write');
    expect(r.message, contains('DRY RUN'));
  });

  test('skips keys whose source value is itself empty', () async {
    final String p = _project(
      base: <String>['', 'Save'],
      locales: <String, List<Row>>{
        'fr': <Row>[v(''), v('Enregistrer')],
      },
    );
    final ({List<List<int>> batches, MockClient client}) m =
        _mock(before: p, after: p);

    final OpResult r = await _ops(m.client).retranslate(dryRun: true);

    expect(r.ok, isTrue);
    expect(r.message, contains('Nothing to translate'));
  });

  test('restricts to the requested locales', () async {
    final String p = _project(
      base: <String>['Save'],
      locales: <String, List<Row>>{
        'fr': <Row>[v('Save')],
        'de': <Row>[v('Save')],
      },
    );
    final ({List<List<int>> batches, MockClient client}) m =
        _mock(before: p, after: p);

    final OpResult r =
        await _ops(m.client).retranslate(locales: <String>['de'], dryRun: true);

    expect(r.data['per_locale'], <String, int>{'de': 1});
  });

  test('rejects a locale the flavor does not have', () async {
    final String p = _project(
      base: <String>['Save'],
      locales: <String, List<Row>>{
        'fr': <Row>[v('Save')],
      },
    );
    final ({List<List<int>> batches, MockClient client}) m =
        _mock(before: p, after: p);

    final OpResult r = await _ops(m.client).retranslate(locales: <String>['zz']);

    expect(r.ok, isFalse);
    expect(r.data['unknown_locales'], <String>['zz']);
    expect(m.batches, isEmpty);
  });

  test('splits large selections across batch requests', () async {
    final List<String> base =
        List<String>.generate(5, (final int i) => 'source $i');
    final String p = _project(
      base: base,
      locales: <String, List<Row>>{
        'fr': <Row>[for (int i = 0; i < 5; i++) v('source $i')],
      },
    );
    final ({List<List<int>> batches, MockClient client}) m =
        _mock(before: p, after: p);

    await _ops(m.client).retranslate(chunkSize: 2);

    expect(m.batches.map((final List<int> b) => b.length), <int>[2, 2, 1]);
  });

  test('reports a value the backend wrote the source back into as failed',
      () async {
    // The batch endpoint can answer 200 while persisting the source text. The
    // re-fetch is what catches it, so the caller is never told it succeeded.
    final String p = _project(
      base: <String>['Save'],
      locales: <String, List<Row>>{
        'fr': <Row>[v('Save')],
      },
    );
    final ({List<List<int>> batches, MockClient client}) m =
        _mock(before: p, after: p);

    final OpResult r = await _ops(m.client).retranslate();

    expect(r.ok, isFalse);
    expect(r.data['translated'], 0);
    expect(
      (r.data['failed'] as List<dynamic>).single,
      containsPair('error', contains('unchanged from source')),
    );
  });
}
