/// Platform text: a key's own text on one target, the platforms a key ships
/// to and the longest text a target takes, read from the API and used by the
/// export, the diff, translation, status and shorten.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_localisation_cli/src/call_budget.dart';
import 'package:flutter_localisation_cli/src/exceptions.dart';
import 'package:flutter_localisation_cli/src/file_diff.dart';
import 'package:flutter_localisation_cli/src/management_client.dart';
import 'package:flutter_localisation_cli/src/operations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

Map<String, dynamic> _ov(
  final String target,
  final String value, {
  final bool needsReview = false,
  final bool isOutdated = false,
}) =>
    <String, dynamic>{
      'target': target,
      'value': value,
      'needs_review': needsReview,
      'is_outdated': isOutdated,
      'is_ai_translated': false,
      'updated_at': '2026-11-26T10:00:00Z',
    };

/// One flavor, `en` base and `fr`: `paywall` has a Flutter and an iOS text,
/// `watch_only` ships to iOS only, `hello` uses none of it.
class _Service {
  _Service({this.platformText = true});

  final bool platformText;
  final Map<String, List<Map<String, dynamic>>> overrides =
      <String, List<Map<String, dynamic>>>{
    'en:paywall': <Map<String, dynamic>>[
      _ov('flutter', 'Go Pro'),
      _ov('ios', 'Pro'),
    ],
    'fr:paywall': <Map<String, dynamic>>[
      _ov('flutter', 'Passez Pro'),
    ],
  };
  Map<String, int> paywallMax = <String, int>{'ios': 10, 'flutter': 40};

  final List<Map<String, dynamic>> batches = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> shortens = <Map<String, dynamic>>[];

  Map<String, dynamic> _row(
    final int id,
    final String code,
    final String key,
    final String value, {
    final List<String> platforms = const <String>[],
    final Map<String, int> maxLength = const <String, int>{},
  }) =>
      <String, dynamic>{
        'id': id,
        'key': key,
        'value': value,
        if (platformText) ...<String, dynamic>{
          'overrides': overrides['$code:$key'] ?? const <dynamic>[],
          'platforms': platforms,
          'max_length': maxLength,
        },
      };

  Map<String, dynamic> project() {
    Map<String, dynamic> lang(final int id, final String code, final bool base,
            final List<String> values) =>
        <String, dynamic>{
          'id': id,
          'code': code,
          'is_base_language': base,
          'translations': <Map<String, dynamic>>[
            _row(id * 10 + 1, code, 'hello', values[0]),
            _row(id * 10 + 2, code, 'paywall', values[1],
                maxLength: paywallMax),
            _row(id * 10 + 3, code, 'watch_only', values[2],
                platforms: <String>['ios']),
          ],
        };
    return <String, dynamic>{
      'id': 7,
      'name': 'P',
      'platforms': <String>['flutter', 'ios'],
      'flavors': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 3,
          'name': 'default',
          'languages': <Map<String, dynamic>>[
            lang(1, 'en', true, <String>[
              'Hello',
              'Upgrade to the Pro plan today',
              'Tap',
            ]),
            lang(2, 'fr', false, <String>[
              'Bonjour',
              'Passez au forfait Pro aujourd’hui',
              'Touchez',
            ]),
          ],
        },
      ],
    };
  }

  Operations ops() {
    final MockClient mock = MockClient((final http.Request req) async {
      final String path = req.url.path;
      Object body = project();
      if (path == '/api/ai_batch_translate/') {
        final Map<String, dynamic> sent =
            jsonDecode(req.body) as Map<String, dynamic>;
        batches.add(sent);
        if (sent['target'] == 'ios' &&
            (sent['translation_ids'] as List<dynamic>).contains(22)) {
          overrides['fr:paywall'] = <Map<String, dynamic>>[
            ...overrides['fr:paywall'] ?? const <Map<String, dynamic>>[],
            _ov('ios', 'Pro'),
          ];
        }
        body = <String, dynamic>{'status': 'success'};
      } else if (path == '/api/projects/7/shorten/') {
        if (!platformText) {
          return http.Response('{"detail": "Not found."}', 404);
        }
        shortens.add(jsonDecode(req.body) as Map<String, dynamic>);
        overrides['en:paywall'] = <Map<String, dynamic>>[
          _ov('flutter', 'Go Pro'),
          _ov('ios', 'Go Pro now'),
        ];
        body = <String, dynamic>{'shortened': 1};
      }
      return http.Response(jsonEncode(body), 200, headers: <String, String>{
        'content-type': 'application/json; charset=utf-8',
      });
    });
    return Operations(
        ManagementClient(baseUrl: 'http://t', token: 'x', httpClient: mock), 7,
        flavor: 'default', budget: CallBudget.disabled());
  }
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('fl_platform_text_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Map<String, dynamic> arb(final String name) =>
      jsonDecode(File('${tmp.path}/$name').readAsStringSync())
          as Map<String, dynamic>;

  group('reading the API', () {
    test('a row from an older service has no platform text', () {
      final TranslationEntry t = TranslationEntry.fromJson(
          <String, dynamic>{'id': 1, 'key': 'k', 'value': 'Full'});
      expect(t.knowsPlatformText, isFalse);
      expect(t.overrides, isEmpty);
      expect(t.platforms, isEmpty);
      expect(t.textFor('ios'), 'Full');
      expect(t.overLimit, isEmpty);
    });

    test('a row carries its overrides, platforms and max lengths', () {
      final TranslationEntry t = TranslationEntry.fromJson(<String, dynamic>{
        'id': 1,
        'key': 'k',
        'value': 'A long full text',
        'overrides': <dynamic>[_ov('ios', 'Short', needsReview: true)],
        'platforms': <String>['ios'],
        'max_length': <String, int>{'ios': 4, 'angular': 3},
      });
      expect(t.knowsPlatformText, isTrue);
      expect(t.textFor('ios'), 'Short');
      expect(t.textFor('angular'), 'A long full text');
      expect(t.overrideFor('ios')!.needsReview, isTrue);
      expect(t.overLimit, <String>['ios', 'angular']);
    });

    test('a project knows platform text when its rows say so', () async {
      expect((await _Service().ops().client.getProject(7)).knowsPlatformText,
          isTrue);
      final ProjectData old =
          await _Service(platformText: false).ops().client.getProject(7);
      expect(old.knowsPlatformText, isFalse);
      expect(() => old.requirePlatformText('--target'),
          throwsA(isA<ManagementException>()));
    });
  });

  group('Flutter export', () {
    test('writes the flutter text and only the keys Flutter ships', () async {
      final OpResult r = await _Service().ops().exportArbs(tmp.path);
      expect(r.ok, isTrue);
      final Map<String, dynamic> en = arb('app_en.arb');
      final Map<String, dynamic> fr = arb('app_fr.arb');
      expect(en['paywall'], 'Go Pro');
      expect(fr['paywall'], 'Passez Pro');
      expect(en['hello'], 'Hello');
      expect(en.containsKey('watch_only'), isFalse);
      expect(fr.containsKey('watch_only'), isFalse);
      expect((r.data['files'] as List<dynamic>).first['keys'], 2);
    });

    test('an older service exports every key with its full text', () async {
      await _Service(platformText: false).ops().exportArbs(tmp.path);
      final Map<String, dynamic> en = arb('app_en.arb');
      expect(en['paywall'], 'Upgrade to the Pro plan today');
      expect(en['watch_only'], 'Tap');
    });

    test('an iOS text does not reach the Flutter file', () async {
      final _Service s = _Service()
        ..overrides['en:paywall'] = <Map<String, dynamic>>[_ov('ios', 'Pro')];
      await s.ops().exportArbs(tmp.path);
      expect(arb('app_en.arb')['paywall'], 'Upgrade to the Pro plan today');
    });
  });

  group('diff', () {
    test('round trip: an exported file has no difference with the service',
        () async {
      final Operations ops = _Service().ops();
      await ops.exportArbs(tmp.path);
      for (final String name in <String>['app_en.arb', 'app_fr.arb']) {
        final FileDiff d = await ops.compareFile(
            File('${tmp.path}/$name').readAsStringSync(),
            fileName: name);
        expect(d.isEmpty, isTrue, reason: '$name: ${d.toJson()}');
        expect(d.same, 2);
      }
    });

    test('an override is not a difference; the full text in its place is',
        () async {
      final Operations ops = _Service().ops();
      FileDiff d = await ops.compareFile(
          jsonEncode(<String, String>{
            '@@locale': 'en',
            'hello': 'Hello',
            'paywall': 'Go Pro',
          }),
          fileName: 'app_en.arb');
      expect(d.changed, isEmpty);
      expect(d.gone, isEmpty, reason: 'watch_only is not a Flutter key');

      d = await ops.compareFile(
          jsonEncode(<String, String>{
            '@@locale': 'en',
            'hello': 'Hello',
            'paywall': 'Upgrade to the Pro plan today',
          }),
          fileName: 'app_en.arb');
      expect(d.changed.keys, <String>['paywall']);
      expect(d.changed['paywall']!.remote, 'Go Pro');
    });
  });

  group('translate --target', () {
    test('sends the target for the locales missing that text', () async {
      final _Service s = _Service();
      final OpResult r = await s.ops().translate('paywall', target: 'ios');
      expect(r.ok, isTrue, reason: r.message);
      expect(s.batches.single, <String, dynamic>{
        'translation_ids': <int>[22],
        'target': 'ios',
      });
      expect(r.data['translated'], 1);
    });

    test('a key with no base text for the target is refused', () async {
      final _Service s = _Service();
      final OpResult r = await s.ops().translate('hello', target: 'ios');
      expect(r.ok, isFalse);
      expect(r.message, contains('no ios text in the base language'));
      expect(s.batches, isEmpty);
    });

    test('an older service is refused before anything is sent', () async {
      final _Service s = _Service(platformText: false);
      await expectLater(s.ops().translate('paywall', target: 'ios'),
          throwsA(isA<ManagementException>()));
      expect(s.batches, isEmpty);
    });

    test('retranslate --target sends every missing or outdated text', () async {
      final _Service s = _Service();
      final OpResult r = await s.ops().retranslate(target: 'ios');
      expect(r.ok, isTrue, reason: r.message);
      expect(s.batches.single['target'], 'ios');
      expect(s.batches.single['translation_ids'], <int>[22]);
      expect(r.message, contains('ios text(s)'));
    });
  });

  group('status', () {
    test('counts texts to check and texts over the limit', () async {
      final _Service s = _Service()
        ..overrides['fr:paywall'] = <Map<String, dynamic>>[
          _ov('flutter', 'Passez Pro', needsReview: true),
        ];
      final OpResult r = await s.ops().status();
      final List<dynamic> rows = r.data['locales'] as List<dynamic>;
      final Map<String, dynamic> en = rows.first as Map<String, dynamic>;
      final Map<String, dynamic> fr = rows.last as Map<String, dynamic>;
      expect(en.containsKey('over_limit'), isFalse,
          reason: 'en has an ios text of 3 characters');
      expect(fr['over_limit'], <String, int>{'ios': 1});
      expect(fr['platform_text_to_check'], 1);
    });

    test('an older service adds nothing to the status', () async {
      final OpResult r = await _Service(platformText: false).ops().status();
      for (final dynamic row in r.data['locales'] as List<dynamic>) {
        expect(
            (row as Map<String, dynamic>).keys, isNot(contains('over_limit')));
        expect(row.keys, isNot(contains('platform_text_to_check')));
      }
    });
  });

  group('shorten', () {
    test('sends the keys over the limit for the one limited target', () async {
      final _Service s = _Service()
        ..overrides['en:paywall'] = <Map<String, dynamic>>[]
        ..paywallMax = <String, int>{'ios': 12};
      final OpResult r = await s.ops().shorten();
      expect(r.ok, isTrue, reason: r.message);
      expect(s.shortens.single, <String, dynamic>{
        'keys': <String>['paywall'],
        'target': 'ios',
      });
      expect(r.message, contains('Shortened 1/1'));
    });

    test('several limited targets need --target', () async {
      final _Service s = _Service();
      final OpResult r = await s.ops().shorten();
      expect(r.ok, isFalse);
      expect(r.message, contains('flutter, ios'));
      expect(s.shortens, isEmpty);
    });

    test('nothing over the limit sends nothing', () async {
      final _Service s = _Service();
      final OpResult r = await s.ops().shorten(target: 'ios');
      expect(r.ok, isTrue);
      expect(r.message, 'Nothing is over the ios limit.');
      expect(s.shortens, isEmpty);
    });

    test('named keys and locales are sent as given', () async {
      final _Service s = _Service();
      final OpResult r = await s.ops().shorten(
          target: 'ios', keys: <String>['paywall'], locales: <String>['fr']);
      expect(r.ok, isTrue, reason: r.message);
      expect(s.shortens.single['locales'], <String>['fr']);
    });

    test('an older service is refused with a sentence', () async {
      await expectLater(
          _Service(platformText: false).ops().shorten(target: 'ios'),
          throwsA(isA<ManagementException>().having(
              (final ManagementException e) => e.message,
              'message',
              contains('does not support platform text'))));
    });
  });

  group('parsing', () {
    test('platforms and max lengths', () {
      expect(parsePlatformList(<String>['ios, angular']),
          <String>['ios', 'angular']);
      expect(parsePlatformList(<String>['all']), isEmpty);
      expect(() => parsePlatformList(<String>['android']),
          throwsA(isA<ArgumentError>()));
      expect(parseMaxLengths(<String>['ios=40,ios/watch=12', 'ngx=0']),
          <String, int>{'ios': 40, 'ios/watch': 12, 'ngx': 0});
      expect(() => parseMaxLengths(<String>['ios']),
          throwsA(isA<ArgumentError>()));
      expect(() => parseMaxLengths(<String>['ios/car=4']),
          throwsA(isA<ArgumentError>()));
    });
  });
}
