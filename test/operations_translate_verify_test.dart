import 'dart:convert';

import 'package:flutter_localisation_cli/src/management_client.dart';
import 'package:flutter_localisation_cli/src/operations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// A project where the backend "translated" every locale, but `es` still holds
/// the English base text — the silent false-success we must catch client-side.
Map<String, dynamic> _project({required String esValue}) => <String, dynamic>{
      'id': 9,
      'name': 'P',
      'flavors': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 1,
          'name': 'default',
          'languages': <Map<String, dynamic>>[
            <String, dynamic>{
              'code': 'en',
              'is_base_language': true,
              'translations': <Map<String, dynamic>>[
                <String, dynamic>{'id': 1, 'key': 'greeting', 'value': 'Hello'},
              ],
            },
            <String, dynamic>{
              'code': 'fr',
              'is_base_language': false,
              'translations': <Map<String, dynamic>>[
                <String, dynamic>{'id': 2, 'key': 'greeting', 'value': 'Bonjour'},
              ],
            },
            <String, dynamic>{
              'code': 'es',
              'is_base_language': false,
              'translations': <Map<String, dynamic>>[
                <String, dynamic>{'id': 3, 'key': 'greeting', 'value': esValue},
              ],
            },
            <String, dynamic>{
              'code': 'de',
              'is_base_language': false,
              'translations': <Map<String, dynamic>>[
                <String, dynamic>{'id': 4, 'key': 'greeting', 'value': 'Hallo'},
              ],
            },
          ],
        },
      ],
    };

ManagementClient _client(String esValue) {
  final MockClient mock = MockClient((final http.Request req) async {
    if (req.url.path == '/api/ai_batch_translate/') {
      // The backend LIES: claims all three succeeded.
      return http.Response(
        jsonEncode(<String, dynamic>{
          'status': 'success',
          'results': <String, dynamic>{
            'success_count': 3,
            'failed_count': 0,
            'failed': <dynamic>[],
          },
        }),
        200,
      );
    }
    return http.Response(jsonEncode(_project(esValue: esValue)), 200);
  });
  return ManagementClient(baseUrl: 'http://t', token: 'flk_live_x', httpClient: mock);
}

void main() {
  test('silent false success is caught: es still == base → reported unchanged',
      () async {
    // The guard here is the count, not the bucket: `translated` must stay at 2
    // so a row holding the source text can never be passed off as finished.
    // It is reported as unchanged rather than failed because no error
    // occurred — and because "Hello" may simply be what Spanish uses.
    final OpResult r = await Operations(_client('Hello'), 9, flavor: 'default')
        .translate('greeting', all: true);
    expect(r.data['translated'], 2, reason: 'fr + de changed; es did not');
    expect(r.data['failed'], isEmpty, reason: 'no backend error occurred');
    final List<dynamic> unchanged = r.data['unchanged'] as List<dynamic>;
    expect(unchanged, hasLength(1));
    expect((unchanged.first as Map)['id'], 3);
    expect(r.message, contains('2/3'));
    expect(r.message, contains('1 unchanged'));
  });

  test('genuinely translated (es differs from base) → all counted, ok',
      () async {
    final OpResult r = await Operations(_client('Hola'), 9, flavor: 'default')
        .translate('greeting', all: true);
    expect(r.ok, isTrue);
    expect(r.data['translated'], 3);
    expect(r.data['failed'], isEmpty);
    expect(r.message, contains('3/3'));
  });
}
