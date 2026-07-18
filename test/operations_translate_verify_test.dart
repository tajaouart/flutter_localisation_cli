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
  test('silent false success is caught: es still == base → reported failed',
      () async {
    final OpResult r = await Operations(_client('Hello'), 9, flavor: 'default')
        .translate('greeting', all: true);
    expect(r.ok, isFalse, reason: 'must not report ok when a locale is untranslated');
    expect(r.data['translated'], 2, reason: 'fr + de changed; es did not');
    final List<dynamic> failed = r.data['failed'] as List<dynamic>;
    expect(failed, hasLength(1));
    expect((failed.first as Map)['id'], 3);
    expect(r.message, contains('2/3'));
    expect(r.message, contains('1 failed'));
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
