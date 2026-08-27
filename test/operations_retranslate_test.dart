import 'dart:convert';

import 'package:flutter_localisation_cli/src/exceptions.dart';
import 'package:flutter_localisation_cli/src/management_client.dart';
import 'package:flutter_localisation_cli/src/call_budget.dart';
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
({MockClient client, List<List<int>> batches, List<List<int>> checked}) _mock({
  required final String before,
  required final String after,
}) {
  final List<List<int>> batches = <List<int>>[];
  // Every /translations/bulk-check/ call, so a test can assert there was
  // exactly ONE — the whole point of that endpoint.
  final List<List<int>> checked = <List<int>>[];
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
    if (req.url.path == '/api/translations/bulk-check/') {
      final Map<String, dynamic> body =
          jsonDecode(req.body) as Map<String, dynamic>;
      checked.add((body['translation_ids'] as List<dynamic>).cast<int>());
      return http.Response(
        jsonEncode(<String, dynamic>{'updated': checked.last.length}),
        200,
      );
    }
    return http.Response(batches.isEmpty ? before : after, 200);
  });
  return (client: client, batches: batches, checked: checked);
}

Operations _ops(final MockClient c) => Operations(
      ManagementClient(baseUrl: 'http://t', token: 'x', httpClient: c),
      7,
      flavor: 'default',
      budget: CallBudget.disabled(),
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
    final ({List<List<int>> batches, List<List<int>> checked, MockClient client}) m =
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
    final ({List<List<int>> batches, List<List<int>> checked, MockClient client}) m =
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
    final ({List<List<int>> batches, List<List<int>> checked, MockClient client}) m =
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
    final ({List<List<int>> batches, List<List<int>> checked, MockClient client}) m =
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
    final ({List<List<int>> batches, List<List<int>> checked, MockClient client}) m =
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
    final ({List<List<int>> batches, List<List<int>> checked, MockClient client}) m =
        _mock(before: p, after: p);

    await _ops(m.client).retranslate(chunkSize: 2);

    expect(m.batches.map((final List<int> b) => b.length), <int>[2, 2, 1]);
  });

  test('reports a value the backend wrote the source back into as unchanged',
      () async {
    // The batch endpoint can answer 200 while persisting the source text. The
    // re-fetch is what catches it, so the caller is never told it succeeded.
    //
    // It lands in `unchanged`, not `failed`: nothing went wrong on the wire,
    // and for a loanword the source text IS the right answer. What the caller
    // must never see is this row counted as translated.
    final String p = _project(
      base: <String>['Save'],
      locales: <String, List<Row>>{
        'fr': <Row>[v('Save')],
      },
    );
    final ({List<List<int>> batches, List<List<int>> checked, MockClient client}) m =
        _mock(before: p, after: p);

    final OpResult r = await _ops(m.client).retranslate();

    expect(r.data['translated'], 0, reason: 'must never over-report');
    expect(r.data['failed'], isEmpty, reason: 'no backend error occurred');
    expect(
      (r.data['unchanged'] as List<dynamic>).single,
      containsPair('locale', 'fr'),
    );
    expect(r.message, contains('1 unchanged'));
  });

  test('--accept-unchanged marks the identical rows checked', () async {
    // The loop-breaker: without this, a correctly-identical row is selected,
    // re-translated and re-reported on every single run, for ever.
    final String p = _project(
      base: <String>['Save'],
      locales: <String, List<Row>>{
        'fr': <Row>[v('Save')],
      },
    );
    final ({List<List<int>> batches, List<List<int>> checked, MockClient client})
        m = _mock(before: p, after: p);

    final OpResult r = await _ops(m.client).retranslate(acceptUnchanged: true);

    expect(r.data['accepted'], 1);
    expect(r.message, contains('1 accepted as checked'));
    // ONE request for the whole set, not one per row. This was a per-row loop
    // and each of those calls made the server regenerate and push every ARB.
    expect(m.checked.length, 1);
  });

  test('a 400 whose rows are all identical-to-source still completes',
      () async {
    // "Every row in the chunk failed" is a 400, not a 207 — and it is the
    // NORMAL outcome once the only gap left is loanwords. Treating it as fatal
    // meant a project in exactly that state could never finish a run, so it
    // could never reach --accept-unchanged, so it stayed in that state for
    // ever. The rows also arrive with translation_id: null, so they cannot be
    // attributed; the re-fetch is what recovers them.
    final String p = _project(
      base: <String>['OK', 'Premium'],
      locales: <String, List<Row>>{
        'fr': <Row>[v('OK'), v('Premium')],
      },
    );
    final MockClient client = MockClient((final http.Request req) async {
      if (req.url.path == '/api/ai_batch_translate/') {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'message': 'All translations failed.',
            'results': <String, dynamic>{
              'failed': <Map<String, dynamic>>[
                <String, dynamic>{
                  'translation_id': null,
                  'error': 'AI returned text identical to the source (untranslated).',
                },
                <String, dynamic>{
                  'translation_id': null,
                  'error': 'AI returned text identical to the source (untranslated).',
                },
              ],
            },
          }),
          400,
        );
      }
      if (req.url.path == '/api/translations/bulk-check/') {
        final Map<String, dynamic> body =
            jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'updated': (body['translation_ids'] as List<dynamic>).length,
          }),
          200,
        );
      }
      return http.Response(p, 200);
    });

    final OpResult r = await _ops(client).retranslate(acceptUnchanged: true);

    expect(r.data['failed'], isEmpty);
    expect(r.data['unchanged'], hasLength(2));
    expect(r.data['accepted'], 2, reason: 'the loop must actually be closable');
  });

  test('a 400 with no per-row detail is still fatal', () async {
    // The other side of the same coin: a genuine outage must not be quietly
    // absorbed by the recovery path above.
    final String p = _project(
      base: <String>['OK'],
      locales: <String, List<Row>>{
        'fr': <Row>[v('OK')],
      },
    );
    final MockClient client = MockClient((final http.Request req) async {
      if (req.url.path == '/api/ai_batch_translate/') {
        return http.Response(
          jsonEncode(<String, dynamic>{'message': 'Gateway Time-out'}),
          504,
        );
      }
      return http.Response(p, 200);
    });

    await expectLater(
      _ops(client).retranslate(),
      throwsA(isA<ApiException>()),
    );
  });

  test('sorts the backend\'s own per-row errors into unchanged vs failed',
      () async {
    // The backend reports "AI returned text identical to the source" as a
    // per-row error, so the loanword case arrives from BOTH directions: some
    // rows come back 200-but-identical, and some come back as this error. Both
    // are the same event. Anything else it says is a real failure and must
    // survive as one, with its reason intact — that reason is how a malformed
    // plural row gets diagnosed instead of being read as a dead service.
    //
    // Note both rows below still equal their source after the run: a row that
    // fails validation keeps the value it had, and every row selected for
    // retranslation was source-identical to begin with. So "still equals the
    // source" cannot be what sorts these — only the reason can. Deciding by
    // value here would file the placeholder error under `unchanged`, where
    // --accept-unchanged would mark a broken row as deliberately correct.
    final String p = _project(
      base: <String>['OK', 'Save'],
      locales: <String, List<Row>>{
        'fr': <Row>[v('OK'), v('Save')],
      },
    );
    final MockClient client = MockClient((final http.Request req) async {
      if (req.url.path == '/api/ai_batch_translate/') {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'status': 'partial',
            'results': <String, dynamic>{
              'failed': <Map<String, dynamic>>[
                <String, dynamic>{
                  'translation_id': 1000,
                  'error': 'AI returned text identical to the source (untranslated).',
                },
                <String, dynamic>{
                  'translation_id': 1001,
                  'error': "AI response altered placeholders — singular_case: unexpected ['count']",
                },
              ],
            },
          }),
          200,
          // The real backend's reasons contain non-ASCII (an em dash), and
          // http.Response falls back to latin-1 without this.
          headers: <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
        );
      }
      return http.Response(p, 200);
    });

    final OpResult r = await _ops(client).retranslate();

    final List<dynamic> unchanged = r.data['unchanged'] as List<dynamic>;
    final List<dynamic> failed = r.data['failed'] as List<dynamic>;
    expect(unchanged, hasLength(1));
    expect((unchanged.single as Map)['id'], 1000);
    expect(failed, hasLength(1));
    expect((failed.single as Map)['id'], 1001);
    expect(
      (failed.single as Map)['error'],
      contains('altered placeholders'),
      reason: 'the backend reason is the whole value of the failed bucket',
    );
  });
}
