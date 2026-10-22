import 'package:flutter_localisation_cli/src/exceptions.dart';
import 'package:flutter_localisation_cli/src/management_client.dart';
import 'package:test/test.dart';

/// A project with one flavor, base=en, plus fr (partly filled) and de (empty).
ProjectData sample() => ProjectData.fromJson(<String, dynamic>{
      'id': 7,
      'name': 'Demo',
      'flavors': <Map<String, dynamic>>[
        <String, dynamic>{
          'name': 'production',
          'languages': <Map<String, dynamic>>[
            <String, dynamic>{
              'code': 'en',
              'is_base_language': true,
              'translations': <Map<String, dynamic>>[
                <String, dynamic>{'id': 1, 'key': 'greeting', 'value': 'Hello'},
                <String, dynamic>{'id': 2, 'key': 'bye', 'value': 'Bye'},
              ],
            },
            <String, dynamic>{
              'code': 'fr',
              'is_base_language': false,
              'translations': <Map<String, dynamic>>[
                <String, dynamic>{'id': 3, 'key': 'greeting', 'value': 'Bonjour'},
                <String, dynamic>{'id': 4, 'key': 'bye', 'value': ''},
              ],
            },
            <String, dynamic>{
              'code': 'de',
              'is_base_language': false,
              'translations': <Map<String, dynamic>>[
                <String, dynamic>{'id': 5, 'key': 'greeting', 'value': ''},
                <String, dynamic>{'id': 6, 'key': 'bye', 'value': ''},
              ],
            },
          ],
        },
      ],
    });

void main() {
  test('resolveId maps (key, locale) → translation id', () {
    final ProjectData p = sample();
    expect(p.resolveId('greeting', 'en'), 1);
    expect(p.resolveId('greeting', 'fr'), 3);
    expect(p.resolveId('bye', 'de'), 6);
  });

  test('canonicalKey accepts a catalog key by its stem and refuses a shared stem', () {
    final ProjectData p = ProjectData.fromJson(<String, dynamic>{
      'id': 7,
      'name': 'Gush',
      'flavors': <Map<String, dynamic>>[
        <String, dynamic>{
          'name': 'Default',
          'languages': <Map<String, dynamic>>[
            <String, dynamic>{
              'code': 'en',
              'is_base_language': true,
              'translations': <Map<String, dynamic>>[
                <String, dynamic>{'id': 1, 'key': 'done_body %@ %lld', 'value': '{arg1} in {arg2} s'},
                <String, dynamic>{'id': 2, 'key': 'paywall_buy %@', 'value': 'Buy {arg1}'},
                <String, dynamic>{'id': 3, 'key': 'paywall_buy', 'value': 'Buy'},
                <String, dynamic>{'id': 4, 'key': 'title %@', 'value': '{arg1}'},
                <String, dynamic>{'id': 5, 'key': 'title %lld', 'value': '{arg1}'},
              ],
            },
          ],
        },
      ],
    });
    expect(p.canonicalKey('done_body'), 'done_body %@ %lld');
    expect(p.canonicalKey('done_body %@ %lld'), 'done_body %@ %lld');
    expect(p.resolveId('done_body', 'en'), 1);
    expect(p.canonicalKey('paywall_buy'), 'paywall_buy', reason: 'an exact key wins over a stem');
    expect(p.baseEntry('done_body')?.id, 1);
    expect(p.entriesForKey('done_body').single.id, 1);
    expect(
      () => p.canonicalKey('title'),
      throwsA(isA<ResolveException>().having((final ResolveException e) => e.message, 'message',
          allOf(contains('ambiguous'), contains('"title %@"'), contains('"title %lld"')))),
    );
    expect(
      () => p.canonicalKey('done'),
      throwsA(isA<ResolveException>().having((final ResolveException e) => e.message, 'message',
          contains('Did you mean "done_body %@ %lld"?'))),
    );
    expect(p.entriesForKey('nothing'), isEmpty);
  });

  test('resolveId throws for unknown key or locale', () {
    final ProjectData p = sample();
    expect(() => p.resolveId('missing', 'fr'), throwsA(isA<ResolveException>()));
    expect(() => p.resolveId('greeting', 'es'), throwsA(isA<ResolveException>()));
  });

  test('baseLanguage picks the flagged base', () {
    expect(sample().baseLanguage('production')?.code, 'en');
  });

  test('entriesForKey lists every locale with empty flags', () {
    final List<({bool empty, int id, String locale})> entries =
        sample().entriesForKey('bye');
    expect(entries.length, 3);
    final Map<String, bool> emptyByLocale = <String, bool>{
      for (final ({bool empty, int id, String locale}) e in entries)
        e.locale: e.empty,
    };
    expect(emptyByLocale['en'], false); // "Bye"
    expect(emptyByLocale['fr'], true); // ""
    expect(emptyByLocale['de'], true); // ""
  });

  test('single-flavor projects resolve without --flavor', () {
    expect(sample().flavor(null).name, 'production');
  });

  test('batch result parses partial (207) shape', () {
    final BatchTranslateResult r =
        BatchTranslateResult.fromJson(<String, dynamic>{
      'status': 'partial',
      'results': <String, dynamic>{
        'success_count': 2,
        'failed_count': 1,
        'failed': <Map<String, dynamic>>[
          <String, dynamic>{'translation_id': 9, 'error': 'Base translation not found.'},
        ],
      },
    });
    expect(r.status, 'partial');
    expect(r.successCount, 2);
    expect(r.failed.single.id, 9);
  });
}
