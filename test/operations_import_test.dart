import 'dart:convert';

import 'package:flutter_localisation_cli/src/management_client.dart';
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
    final OpResult r = await Operations(client, 7, flavor: 'default').importArb(arb);

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

    final OpResult r = await Operations(client, 7, flavor: 'default')
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
        await Operations(client, 7, flavor: 'default').importArb('not json {');

    expect(r.ok, isFalse);
    expect(r.message, contains('Invalid ARB'));
    expect(hits, isEmpty);
  });
}
