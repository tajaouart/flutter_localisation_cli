import 'dart:convert';

import 'package:flutter_localisation_cli/src/exceptions.dart';
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
                <String, dynamic>{
                  'id': 2,
                  'key': 'greeting',
                  'value': 'Bonjour'
                },
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
  return ManagementClient(
      baseUrl: 'http://t', token: 'flk_live_x', httpClient: mock);
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

  test(
      'an English variant that reads like English is translated, not unchanged',
      () async {
    final Map<String, dynamic> project = _project(esValue: 'Hola');
    ((project['flavors'] as List<dynamic>).first['languages'] as List<dynamic>)
        .add(<String, dynamic>{
      'code': 'en-GB',
      'is_base_language': false,
      'translations': <Map<String, dynamic>>[
        <String, dynamic>{'id': 5, 'key': 'greeting', 'value': 'Hello'},
      ],
    });
    final MockClient mock = MockClient((final http.Request req) async {
      if (req.url.path == '/api/ai_batch_translate/') {
        return http.Response(
            jsonEncode(<String, dynamic>{
              'status': 'success',
              'results': <String, dynamic>{
                'success_count': 4,
                'failed_count': 0,
                'failed': <dynamic>[]
              },
            }),
            200);
      }
      return http.Response(jsonEncode(project), 200);
    });
    final OpResult r = await Operations(
            ManagementClient(
                baseUrl: 'http://t', token: 'flk_live_x', httpClient: mock),
            9,
            flavor: 'default')
        .translate('greeting', all: true);
    expect(r.data['translated'], 4);
    expect(r.data['unchanged'], isEmpty);
    expect(r.message, isNot(contains('unchanged')));
  });

  group('add --translate with a key that may not translate', () {
    ManagementClient refusing(final Map<String, dynamic> refusal,
        {final int status = 403}) {
      final MockClient mock = MockClient((final http.Request req) async {
        if (req.url.path == '/api/ai_batch_translate/') {
          return http.Response(jsonEncode(refusal), status);
        }
        if (req.url.path == '/api/projects/9/translation_keys/') {
          return http.Response('{}', 201);
        }
        return http.Response(jsonEncode(_project(esValue: 'Hello')), 200);
      });
      return ManagementClient(
          baseUrl: 'http://t', token: 'flk_live_x', httpClient: mock);
    }

    const String message =
        'Your API token lacks the required scope (translate) for this '
        'endpoint. A workspace owner or manager can switch it on for this key '
        'at https://app.flutterlocalisation.com/api-keys.';

    test('says the key was added, why it was not translated and what to do',
        () async {
      final OpResult r = await Operations(
              refusing(<String, dynamic>{'code': 'scope', 'message': message}),
              9,
              flavor: 'default')
          .add('greeting', 'Hello', translate: true);
      expect(r.ok, isFalse);
      expect(
          r.message, startsWith('Added "greeting", but it was not translated'));
      expect(r.message, contains(message));
      expect(r.message, contains('fl translate greeting --all'));
      expect(r.data['added'], isTrue);
      expect(r.data['translated'], 0);
    });

    test(
        'a service from before the refusal carried a code is read by its words',
        () async {
      final OpResult r = await Operations(
              refusing(<String, dynamic>{
                'message': 'Your API token lacks the required scope '
                    '(translate) for this endpoint.'
              }),
              9,
              flavor: 'default')
          .add('greeting', 'Hello', translate: true);
      expect(r.ok, isFalse);
      expect(
          r.message, contains('Added "greeting", but it was not translated'));
    });

    test('any other refusal is still an error of its own', () async {
      expect(
          () => Operations(
                  refusing(<String, dynamic>{'message': 'Plan limit reached.'}),
                  9,
                  flavor: 'default')
              .add('greeting', 'Hello', translate: true),
          throwsA(isA<ApiException>().having(
              (final ApiException e) => e.isScopeRefusal, 'scope', isFalse)));
      expect(
          () => Operations(
                  refusing(<String, dynamic>{'code': 'scope', 'message': 'x'},
                      status: 500),
                  9,
                  flavor: 'default')
              .add('greeting', 'Hello', translate: true),
          throwsA(isA<ManagementException>()));
    });
  });
}
