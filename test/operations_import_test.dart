import 'dart:convert';

import 'package:flutter_localisation_cli/src/management_client.dart';
import 'package:flutter_localisation_cli/src/call_budget.dart';
import 'package:flutter_localisation_cli/src/operations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

http.Response _project(final http.Request req) => http.Response(
      jsonEncode(<String, dynamic>{
        'id': 7,
        'name': 'P',
        'flavors': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 3,
            'name': 'default',
            'languages': <Map<String, dynamic>>[
              <String, dynamic>{
                'code': 'en',
                'is_base_language': true,
                'translations': <Map<String, dynamic>>[],
              },
            ],
          },
        ],
      }),
      200,
    );

void main() {
  test('importArb posts the ARB to the import endpoint and counts keys', () async {
    final List<String> hits = <String>[];
    final MockClient mock = MockClient((final http.Request req) async {
      hits.add('${req.method} ${req.url.path}');
      if (req.url.path == '/api/projects/7/') return _project(req);
      return http.Response(jsonEncode(<String, dynamic>{'import_status': 'success'}), 200);
    });
    final ManagementClient client =
        ManagementClient(baseUrl: 'http://t', token: 'flk_live_x', httpClient: mock);

    final String arb = jsonEncode(<String, dynamic>{
      '@@locale': 'en',
      'k1': 'v1',
      'k2': 'v2',
      '@k1': <String, dynamic>{'description': 'meta, not a key'},
    });
    final OpResult r = await Operations(client, 7, flavor: 'default', budget: CallBudget.disabled()).importArb(arb);

    expect(r.ok, isTrue);
    expect(hits, contains('POST /api/project/7/import-arb/'));
    expect(r.data['imported'], 2); // k1, k2 — not @@locale / @k1
  });

  test('importArb dry run resolves but does NOT hit the import endpoint', () async {
    final List<String> hits = <String>[];
    final MockClient mock = MockClient((final http.Request req) async {
      hits.add('${req.method} ${req.url.path}');
      if (req.url.path == '/api/projects/7/') return _project(req);
      return http.Response('{}', 200);
    });
    final ManagementClient client =
        ManagementClient(baseUrl: 'http://t', token: 'x', httpClient: mock);

    final OpResult r = await Operations(client, 7, flavor: 'default', budget: CallBudget.disabled())
        .importArb(jsonEncode(<String, dynamic>{'k': 'v'}), dryRun: true);

    expect(r.ok, isTrue);
    expect(r.message, contains('DRY RUN'));
    expect(hits.any((final String h) => h.contains('import-arb')), isFalse);
  });

  test('importArb rejects invalid JSON before any network call', () async {
    final List<String> hits = <String>[];
    final MockClient mock = MockClient((final http.Request req) async {
      hits.add('${req.method} ${req.url.path}');
      return http.Response('{}', 200);
    });
    final ManagementClient client =
        ManagementClient(baseUrl: 'http://t', token: 'x', httpClient: mock);

    final OpResult r =
        await Operations(client, 7, flavor: 'default', budget: CallBudget.disabled()).importArb('not json {');

    expect(r.ok, isFalse);
    expect(r.message, contains('Invalid ARB'));
    expect(hits, isEmpty);
  });

  test('importArb WITH --language scopes to that locale only', () async {
    String? body;
    final MockClient mock = MockClient((final http.Request req) async {
      if (req.url.path == '/api/projects/7/') return _project(req);
      if (req.url.path == '/api/project/7/import-arb/') {
        body = req.body;
        return http.Response(
            jsonEncode(<String, dynamic>{'import_status': 'success'}), 200);
      }
      return http.Response('{}', 200);
    });
    final ManagementClient client =
        ManagementClient(baseUrl: 'http://t', token: 'x', httpClient: mock);

    await Operations(client, 7, flavor: 'default', budget: CallBudget.disabled())
        .importArb(jsonEncode(<String, dynamic>{'k': 'v'}), languageCode: 'fr');

    // A targeted locale import must NOT fan out across every language, else it
    // clobbers the others with this file's values.
    expect(_field(body!, 'apply_to_all_languages'), 'false');
    expect(_field(body!, 'selected_language_code'), 'fr');
  });

  test('importArb WITHOUT --language still seeds every locale', () async {
    String? body;
    final MockClient mock = MockClient((final http.Request req) async {
      if (req.url.path == '/api/projects/7/') return _project(req);
      if (req.url.path == '/api/project/7/import-arb/') {
        body = req.body;
        return http.Response(
            jsonEncode(<String, dynamic>{'import_status': 'success'}), 200);
      }
      return http.Response('{}', 200);
    });
    final ManagementClient client =
        ManagementClient(baseUrl: 'http://t', token: 'x', httpClient: mock);

    await Operations(client, 7, flavor: 'default', budget: CallBudget.disabled())
        .importArb(jsonEncode(<String, dynamic>{'k': 'v'}));

    // A base-language import seeds all locales so fresh keys are translatable.
    expect(_field(body!, 'apply_to_all_languages'), 'true');
  });

  test('importArb naming the BASE language explicitly still seeds every locale',
      () async {
    String? body;
    final MockClient mock = MockClient((final http.Request req) async {
      if (req.url.path == '/api/projects/7/') return _project(req);
      if (req.url.path == '/api/project/7/import-arb/') {
        body = req.body;
        return http.Response(
            jsonEncode(<String, dynamic>{'import_status': 'success'}), 200);
      }
      return http.Response('{}', 200);
    });
    final ManagementClient client =
        ManagementClient(baseUrl: 'http://t', token: 'x', httpClient: mock);

    await Operations(client, 7, flavor: 'default', budget: CallBudget.disabled())
        .importArb(jsonEncode(<String, dynamic>{'k': 'v'}), languageCode: 'en');

    // `--language en` on an en-base project must behave exactly like omitting
    // the flag. It used to scope the import to `en` alone, leaving the other
    // locales without rows; `--translate` then found nothing, reported success,
    // and the caller's only working fallback was one add+translate PER KEY.
    expect(_field(body!, 'apply_to_all_languages'), 'true');
  });

  test('importArb --translate FAILS loudly when locales were left unseeded',
      () async {
    // en has the imported key, fr does not — the exact state the old code
    // reported as "imported; nothing to translate", i.e. success with zero
    // translations.
    http.Response projectWithUnseededFr(final http.Request req) => http.Response(
          jsonEncode(<String, dynamic>{
            'id': 7,
            'name': 'P',
            'flavors': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 3,
                'name': 'default',
                'languages': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'code': 'en',
                    'is_base_language': true,
                    'translations': <Map<String, dynamic>>[
                      <String, dynamic>{'id': 1, 'key': 'k', 'value': 'v'},
                    ],
                  },
                  <String, dynamic>{
                    'code': 'fr',
                    'is_base_language': false,
                    'translations': <Map<String, dynamic>>[],
                  },
                ],
              },
            ],
          }),
          200,
        );

    final MockClient mock = MockClient((final http.Request req) async {
      if (req.url.path == '/api/projects/7/') return projectWithUnseededFr(req);
      return http.Response(
          jsonEncode(<String, dynamic>{'import_status': 'success'}), 200);
    });
    final ManagementClient client =
        ManagementClient(baseUrl: 'http://t', token: 'x', httpClient: mock);

    final OpResult r = await Operations(client, 7, flavor: 'default', budget: CallBudget.disabled()).importArb(
      jsonEncode(<String, dynamic>{'k': 'v'}),
      translate: true,
    );

    expect(r.ok, isFalse, reason: 'translating nothing is not success');
    expect(r.message, contains('fr'));
    expect(r.data['unseeded_locales'], <String>['fr']);
    expect(r.data['translated'], 0);
  });

  test('a server that filled the locales itself ends the run there', () async {
    // The point of the server-side flag: ONE round trip. If the CLI still went
    // on to re-fetch the project and batch-translate, the work would be done
    // twice and billed twice.
    var batchCalls = 0;
    final MockClient mock = MockClient((final http.Request req) async {
      if (req.url.path == '/api/ai_batch_translate/') {
        batchCalls++;
        return http.Response('{}', 200);
      }
      if (req.url.path.contains('import')) {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'import_status': 'success',
            'translation': <String, dynamic>{
              'status': 'success',
              'translated': 30,
              'failed': 0,
            },
          }),
          200,
        );
      }
      return _project(req);
    });

    final OpResult r = await Operations(ManagementClient(
      baseUrl: 'http://t',
      token: 'x',
      httpClient: mock,
    ), 7, flavor: 'default')
        .importArb(jsonEncode(<String, dynamic>{'k': 'v'}), translate: true);

    expect(r.ok, isTrue);
    expect(r.data['server_side'], isTrue);
    expect(r.data['translated'], 30);
    expect(batchCalls, 0, reason: 'the server already did it');
  });

  test('an older server without the field falls back to client-side batching',
      () async {
    // The flag is ignored by any deployment that predates it, which answers
    // with no `translation` block. That must degrade to the old path rather
    // than silently import nothing translated.
    var batchCalls = 0;
    final MockClient mock = MockClient((final http.Request req) async {
      if (req.url.path == '/api/ai_batch_translate/') {
        batchCalls++;
        return http.Response('{}', 200);
      }
      if (req.url.path.contains('import')) {
        return http.Response(
          jsonEncode(<String, dynamic>{'import_status': 'success'}),
          200,
        );
      }
      return http.Response(
        jsonEncode(<String, dynamic>{
          'id': 7,
          'name': 'P',
          'flavors': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 3,
              'name': 'default',
              'languages': <Map<String, dynamic>>[
                <String, dynamic>{
                  'code': 'en',
                  'is_base_language': true,
                  'translations': <Map<String, dynamic>>[
                    <String, dynamic>{'id': 1, 'key': 'k', 'value': 'v'},
                  ],
                },
                <String, dynamic>{
                  'code': 'fr',
                  'is_base_language': false,
                  'translations': <Map<String, dynamic>>[
                    <String, dynamic>{'id': 2, 'key': 'k', 'value': 'v'},
                  ],
                },
              ],
            },
          ],
        }),
        200,
      );
    });

    await Operations(ManagementClient(
      baseUrl: 'http://t',
      token: 'x',
      httpClient: mock,
    ), 7, flavor: 'default')
        .importArb(jsonEncode(<String, dynamic>{'k': 'v'}), translate: true);

    expect(batchCalls, 1, reason: 'the CLI must still translate it');
  });

  test('a job the server refuses as too large falls back too', () async {
    // "too_large" is the server saying the work cannot finish inside a request
    // — not that it is done. Treating it as done would leave every row
    // untranslated while reporting success.
    var batchCalls = 0;
    final MockClient mock = MockClient((final http.Request req) async {
      if (req.url.path == '/api/ai_batch_translate/') {
        batchCalls++;
        return http.Response('{}', 200);
      }
      if (req.url.path.contains('import')) {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'import_status': 'success',
            'translation': <String, dynamic>{
              'status': 'too_large',
              'pending': 25110,
            },
          }),
          200,
        );
      }
      return http.Response(
        jsonEncode(<String, dynamic>{
          'id': 7,
          'name': 'P',
          'flavors': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 3,
              'name': 'default',
              'languages': <Map<String, dynamic>>[
                <String, dynamic>{
                  'code': 'en',
                  'is_base_language': true,
                  'translations': <Map<String, dynamic>>[
                    <String, dynamic>{'id': 1, 'key': 'k', 'value': 'v'},
                  ],
                },
                <String, dynamic>{
                  'code': 'fr',
                  'is_base_language': false,
                  'translations': <Map<String, dynamic>>[
                    <String, dynamic>{'id': 2, 'key': 'k', 'value': 'v'},
                  ],
                },
              ],
            },
          ],
        }),
        200,
      );
    });

    await Operations(ManagementClient(
      baseUrl: 'http://t',
      token: 'x',
      httpClient: mock,
    ), 7, flavor: 'default')
        .importArb(jsonEncode(<String, dynamic>{'k': 'v'}), translate: true);

    expect(batchCalls, 1);
  });

  test('import --translate chunks its batch calls', () async {
    // The 504 that motivated this was not "837 keys is too many to create" —
    // the import itself is one request by design and worked. It was the
    // translate step sending every row in a single call: 837 keys × 30 locales
    // = 25,110 rows in one HTTP request. retranslate had chunked for exactly
    // this reason and this path had not, so the protection existed and simply
    // was not shared.
    final List<int> batchSizes = <int>[];
    final MockClient mock = MockClient((final http.Request req) async {
      if (req.url.path == '/api/ai_batch_translate/') {
        final Map<String, dynamic> body =
            jsonDecode(req.body) as Map<String, dynamic>;
        batchSizes.add((body['translation_ids'] as List<dynamic>).length);
        return http.Response('{}', 200);
      }
      if (req.url.path.contains('import')) return http.Response('{}', 200);
      return http.Response(
        jsonEncode(<String, dynamic>{
          'id': 7,
          'name': 'P',
          'flavors': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 3,
              'name': 'default',
              'languages': <Map<String, dynamic>>[
                <String, dynamic>{
                  'code': 'en',
                  'is_base_language': true,
                  'translations': <Map<String, dynamic>>[
                    for (int i = 0; i < 25; i++)
                      <String, dynamic>{'id': i + 1, 'key': 'k$i', 'value': 'v'},
                  ],
                },
                <String, dynamic>{
                  'code': 'fr',
                  'is_base_language': false,
                  'translations': <Map<String, dynamic>>[
                    for (int i = 0; i < 25; i++)
                      <String, dynamic>{
                        'id': 100 + i,
                        'key': 'k$i',
                        'value': 'v',
                      },
                  ],
                },
              ],
            },
          ],
        }),
        200,
      );
    });

    await Operations(ManagementClient(
      baseUrl: 'http://t',
      token: 'x',
      httpClient: mock,
    ), 7, flavor: 'default')
        .importArb(
      jsonEncode(<String, dynamic>{
        for (int i = 0; i < 25; i++) 'k$i': 'v',
      }),
      translate: true,
      chunkSize: 10,
    );

    expect(batchSizes, <int>[10, 10, 5],
        reason: '25 rows at chunkSize 10 is three calls, not one');
  });

  test('a timeout while translating still reports the keys as imported',
      () async {
    // A big `--translate` is the request most likely to time out, and the
    // import has already been written by the time it does. Letting the
    // exception escape reported a bare "Gateway Time-out" for a run whose 837
    // keys were all safely created — so the true state (keys in, values not)
    // and the one-command remedy were both invisible.
    final MockClient mock = MockClient((final http.Request req) async {
      if (req.url.path == '/api/ai_batch_translate/') {
        return http.Response(
          jsonEncode(<String, dynamic>{'message': 'Gateway Time-out'}),
          504,
        );
      }
      if (req.url.path.contains('import')) {
        return http.Response('{}', 200);
      }
      return http.Response(
        jsonEncode(<String, dynamic>{
          'id': 7,
          'name': 'P',
          'flavors': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 3,
              'name': 'default',
              'languages': <Map<String, dynamic>>[
                <String, dynamic>{
                  'code': 'en',
                  'is_base_language': true,
                  'translations': <Map<String, dynamic>>[
                    <String, dynamic>{'id': 1, 'key': 'k', 'value': 'v'},
                  ],
                },
                <String, dynamic>{
                  'code': 'fr',
                  'is_base_language': false,
                  'translations': <Map<String, dynamic>>[
                    <String, dynamic>{'id': 2, 'key': 'k', 'value': 'v'},
                  ],
                },
              ],
            },
          ],
        }),
        200,
      );
    });
    final ManagementClient client =
        ManagementClient(baseUrl: 'http://t', token: 'x', httpClient: mock);

    final OpResult r = await Operations(client, 7, flavor: 'default', budget: CallBudget.disabled()).importArb(
      jsonEncode(<String, dynamic>{'k': 'v'}),
      translate: true,
    );

    expect(r.ok, isFalse, reason: 'the caller did not get what they asked for');
    expect(r.data['imported'], 1, reason: 'but the keys ARE created');
    expect(r.message, contains('Imported'));
    expect(r.message, contains('fl retranslate'),
        reason: 'the message must name the remedy');
  });
}

/// Extracts a multipart form field's value from a raw request body.
String _field(final String body, final String name) {
  final RegExpMatch? m =
      RegExp('name="$name"\\r?\\n\\r?\\n([^\\r\\n]*)').firstMatch(body);
  return m?.group(1)?.trim() ?? '';
}
