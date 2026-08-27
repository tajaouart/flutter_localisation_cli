import 'dart:convert';

import 'package:flutter_localisation_cli/src/management_client.dart';
import 'package:flutter_localisation_cli/src/call_budget.dart';
import 'package:flutter_localisation_cli/src/operations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// A project whose `en` base holds [keys] keys, plus whatever [extra] locales
/// are supplied (code → list of values, '' meaning an empty/untranslated row).
String _project({
  required final int keys,
  final Map<String, List<String>> extra = const <String, List<String>>{},
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
                for (int i = 0; i < keys; i++)
                  <String, dynamic>{'id': i + 1, 'key': 'k$i', 'value': 'v$i'},
              ],
            },
            for (final MapEntry<String, List<String>> e in extra.entries)
              <String, dynamic>{
                'id': 200 + extra.keys.toList().indexOf(e.key),
                'code': e.key,
                'is_base_language': false,
                'translations': <Map<String, dynamic>>[
                  for (int i = 0; i < e.value.length; i++)
                    <String, dynamic>{
                      'id': 1000 + i,
                      'key': 'k$i',
                      'value': e.value[i],
                    },
                ],
              },
          ],
        },
      ],
    });

void main() {
  test('addLanguage posts to /api/add-language/ with the auto-translate flag',
      () async {
    final List<String> hits = <String>[];
    String? body;
    var call = 0;
    final MockClient mock = MockClient((final http.Request req) async {
      hits.add('${req.method} ${req.url.path}');
      if (req.url.path == '/api/projects/7/') {
        call++;
        // Before the add: en only. After: id present and filled.
        return http.Response(
          call == 1
              ? _project(keys: 2)
              : _project(keys: 2, extra: <String, List<String>>{
                  'id': <String>['nilai0', 'nilai1'],
                }),
          200,
        );
      }
      body = req.body;
      return http.Response(jsonEncode(<String, dynamic>{'language': <String, dynamic>{'code': 'id'}}), 200);
    });
    final ManagementClient client =
        ManagementClient(baseUrl: 'http://t', token: 'x', httpClient: mock);

    final OpResult r = await Operations(client, 7, flavor: 'default', budget: CallBudget.disabled())
        .addLanguage('id', autoTranslate: true);

    expect(r.ok, isTrue);
    expect(hits, contains('POST /api/add-language/'));
    final Map<String, dynamic> sent = jsonDecode(body!) as Map<String, dynamic>;
    expect(sent['project'], 7);
    expect(sent['flavor'], 3);
    expect(sent['languageCode'], 'id');
    expect(sent['autoTranslate'], true);
    expect(r.data['filled'], 2);
  });

  test('addLanguage FAILS when auto-translate back-filled nothing', () async {
    var call = 0;
    final MockClient mock = MockClient((final http.Request req) async {
      if (req.url.path == '/api/projects/7/') {
        call++;
        return http.Response(
          call == 1
              ? _project(keys: 3)
              // Added, but every row came back empty — the backend accepted the
              // request and did not translate.
              : _project(keys: 3, extra: <String, List<String>>{
                  'id': <String>['', '', ''],
                }),
          200,
        );
      }
      return http.Response('{}', 200);
    });
    final ManagementClient client =
        ManagementClient(baseUrl: 'http://t', token: 'x', httpClient: mock);

    final OpResult r = await Operations(client, 7, flavor: 'default', budget: CallBudget.disabled())
        .addLanguage('id', autoTranslate: true);

    // Must not claim success: that is what pushes callers into per-key loops.
    expect(r.ok, isFalse);
    expect(r.message, contains('0 of 3'));
    expect(r.data['filled'], 0);
  });

  test('addLanguage refuses a locale the flavor already has', () async {
    final List<String> hits = <String>[];
    final MockClient mock = MockClient((final http.Request req) async {
      hits.add('${req.method} ${req.url.path}');
      return http.Response(
        _project(keys: 1, extra: <String, List<String>>{'id': <String>['x']}),
        200,
      );
    });
    final ManagementClient client =
        ManagementClient(baseUrl: 'http://t', token: 'x', httpClient: mock);

    final OpResult r =
        await Operations(client, 7, flavor: 'default', budget: CallBudget.disabled()).addLanguage('id');

    expect(r.ok, isFalse);
    expect(r.message, contains('already'));
    expect(hits.any((final String h) => h.contains('add-language')), isFalse);
  });

  test('addLanguage canonicalises the code before comparing and sending',
      () async {
    final List<String> hits = <String>[];
    String? body;
    var call = 0;
    final MockClient mock = MockClient((final http.Request req) async {
      hits.add('${req.method} ${req.url.path}');
      if (req.url.path == '/api/projects/7/') {
        call++;
        return http.Response(
          call == 1
              ? _project(keys: 1)
              : _project(keys: 1, extra: <String, List<String>>{
                  'pt-BR': <String>['olá'],
                }),
          200,
        );
      }
      body = req.body;
      return http.Response('{}', 200);
    });
    final ManagementClient client =
        ManagementClient(baseUrl: 'http://t', token: 'x', httpClient: mock);

    final OpResult r =
        await Operations(client, 7, flavor: 'default', budget: CallBudget.disabled()).addLanguage('pt_br');

    expect(r.ok, isTrue);
    // The backend stores `pt-BR`. Sending `pt_br` made a second row for one
    // locale, and the verify-after-write read below never found what it added.
    expect((jsonDecode(body!) as Map<String, dynamic>)['languageCode'], 'pt-BR');
    expect(r.data['locale'], 'pt-BR');
  });

  test('addLanguage refuses a variant the flavor already has, however spelled',
      () async {
    final List<String> hits = <String>[];
    final MockClient mock = MockClient((final http.Request req) async {
      hits.add('${req.method} ${req.url.path}');
      return http.Response(
        _project(keys: 1, extra: <String, List<String>>{'pt-BR': <String>['x']}),
        200,
      );
    });
    final ManagementClient client =
        ManagementClient(baseUrl: 'http://t', token: 'x', httpClient: mock);

    final OpResult r =
        await Operations(client, 7, flavor: 'default', budget: CallBudget.disabled()).addLanguage('PT-br');

    expect(r.ok, isFalse);
    expect(r.message, contains('already'));
    expect(hits.any((final String h) => h.contains('add-language')), isFalse);
  });


  test('addLanguage treats a retry\'s "already exists" as the success it is',
      () async {
    var call = 0;
    final MockClient mock = MockClient((final http.Request req) async {
      if (req.url.path == '/api/projects/7/') {
        call++;
        return http.Response(
          call == 1
              ? _project(keys: 2)
              : _project(keys: 2, extra: <String, List<String>>{
                  'pt-BR': <String>['oi0', 'oi1'],
                }),
          200,
        );
      }
      // What the server says when the first attempt already created the row
      // and the client, having timed out waiting for the AI fill, retried.
      return http.Response(
        jsonEncode(<String, dynamic>{
          'error': "Language 'pt-BR' already exists for this flavor.",
        }),
        400,
      );
    });
    final ManagementClient client =
        ManagementClient(baseUrl: 'http://t', token: 'x', httpClient: mock);

    final OpResult r = await Operations(client, 7, flavor: 'default', budget: CallBudget.disabled())
        .addLanguage('pt-BR', autoTranslate: true);

    expect(r.ok, isTrue);
    expect(r.data['filled'], 2);
  });

  test('addLanguage dry run resolves but writes nothing', () async {
    final List<String> hits = <String>[];
    final MockClient mock = MockClient((final http.Request req) async {
      hits.add('${req.method} ${req.url.path}');
      return http.Response(_project(keys: 5), 200);
    });
    final ManagementClient client =
        ManagementClient(baseUrl: 'http://t', token: 'x', httpClient: mock);

    final OpResult r = await Operations(client, 7, flavor: 'default', budget: CallBudget.disabled())
        .addLanguage('th', autoTranslate: true, dryRun: true);

    expect(r.ok, isTrue);
    expect(r.message, contains('DRY RUN'));
    expect(r.message, contains('5 existing key'));
    expect(hits.any((final String h) => h.contains('add-language')), isFalse);
  });

  test('removeLanguage refuses to delete the base language', () async {
    final List<String> hits = <String>[];
    final MockClient mock = MockClient((final http.Request req) async {
      hits.add('${req.method} ${req.url.path}');
      return http.Response(_project(keys: 1), 200);
    });
    final ManagementClient client =
        ManagementClient(baseUrl: 'http://t', token: 'x', httpClient: mock);

    final OpResult r =
        await Operations(client, 7, flavor: 'default', budget: CallBudget.disabled()).removeLanguage('en');

    expect(r.ok, isFalse);
    expect(r.message, contains('base language'));
    expect(hits.any((final String h) => h.contains('delete-language')), isFalse);
  });

  test('removeLanguage deletes by the language row id', () async {
    final List<String> hits = <String>[];
    final MockClient mock = MockClient((final http.Request req) async {
      hits.add('${req.method} ${req.url.path}');
      if (req.url.path == '/api/projects/7/') {
        return http.Response(
          _project(keys: 1, extra: <String, List<String>>{'id': <String>['x']}),
          200,
        );
      }
      return http.Response('', 204);
    });
    final ManagementClient client =
        ManagementClient(baseUrl: 'http://t', token: 'x', httpClient: mock);

    final OpResult r =
        await Operations(client, 7, flavor: 'default', budget: CallBudget.disabled()).removeLanguage('id');

    expect(r.ok, isTrue);
    expect(hits, contains('DELETE /api/delete-language/200/'));
  });

  // ── Bulk add ──────────────────────────────────────────────────────────────
  //
  // The singular form was an open invitation to `for c in …; do fl languages
  // add $c; done`, which is how a 1000/day budget vanishes in an hour. These
  // pin the behaviour that makes the loop pointless.

  test('addLanguages adds every code in one invocation', () async {
    final List<String> posted = <String>[];
    final Map<String, List<String>> present = <String, List<String>>{};
    final MockClient mock = MockClient((final http.Request req) async {
      if (req.url.path == '/api/projects/7/') {
        return http.Response(_project(keys: 1, extra: present), 200);
      }
      final String code =
          (jsonDecode(req.body) as Map<String, dynamic>)['languageCode'] as String;
      posted.add(code);
      present[code] = <String>['t'];
      return http.Response(jsonEncode(<String, dynamic>{'language': <String, dynamic>{'code': code}}), 200);
    });
    final ManagementClient client =
        ManagementClient(baseUrl: 'http://t', token: 'x', httpClient: mock);

    final OpResult r = await Operations(client, 7,
            flavor: 'default', budget: CallBudget.disabled())
        .addLanguages(<String>['ja', 'ko', 'th'], autoTranslate: true);

    expect(r.ok, isTrue);
    expect(posted, containsAll(<String>['ja', 'ko', 'th']));
    expect(r.message, contains('3/3'));
  });

  test('addLanguages sends base languages before their variants', () async {
    // `zh-Hant` cannot be filled before `zh` exists — gen-l10n needs the base
    // ARB beside any variant, and the backend enforces it. A caller listing
    // them in the other order used to eat a hard error and have to rediscover
    // the rule; ordering is free.
    final List<String> posted = <String>[];
    final Map<String, List<String>> present = <String, List<String>>{};
    final MockClient mock = MockClient((final http.Request req) async {
      if (req.url.path == '/api/projects/7/') {
        return http.Response(_project(keys: 1, extra: present), 200);
      }
      final Map<String, dynamic> b = jsonDecode(req.body) as Map<String, dynamic>;
      final String code = b['languageCode'] as String;
      posted.add(code);
      present[code] = <String>['t'];
      return http.Response(jsonEncode(<String, dynamic>{'language': <String, dynamic>{'code': code}}), 200);
    });
    final ManagementClient client =
        ManagementClient(baseUrl: 'http://t', token: 'x', httpClient: mock);

    await Operations(client, 7, flavor: 'default', budget: CallBudget.disabled())
        .addLanguages(<String>['zh-Hant', 'pt-BR', 'zh', 'pt']);

    expect(posted.indexOf('zh'), lessThan(posted.indexOf('zh-Hant')));
    expect(posted.indexOf('pt'), lessThan(posted.indexOf('pt-BR')));
  });

  test('addLanguages stops the moment it is rate limited', () async {
    // Grinding through the remaining 30 locales to collect 30 identical 429s
    // is the exact behaviour the bulk form exists to prevent.
    final List<String> posted = <String>[];
    final MockClient mock = MockClient((final http.Request req) async {
      if (req.url.path == '/api/projects/7/') {
        return http.Response(_project(keys: 1), 200);
      }
      final Map<String, dynamic> b = jsonDecode(req.body) as Map<String, dynamic>;
      posted.add(b['languageCode'] as String);
      return http.Response('{"detail":"Rate limited for another 600s"}', 429,
          headers: <String, String>{'retry-after': '600'});
    });
    final ManagementClient client =
        ManagementClient(baseUrl: 'http://t', token: 'x', httpClient: mock);

    final OpResult r = await Operations(client, 7,
            flavor: 'default', budget: CallBudget.disabled())
        .addLanguages(<String>['ja', 'ko', 'th', 'vi', 'id']);

    expect(r.ok, isFalse);
    // One locale attempted, not five.
    expect(posted.toSet().length, 1);
    expect(
      (r.data['failures'] as List<dynamic>).join(' '),
      contains('were not attempted'),
    );
  });
}
