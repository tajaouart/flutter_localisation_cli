import 'package:flutter_localisation_cli/src/locales.dart';
import 'package:test/test.dart';

void main() {
  group('canonicalize', () {
    test('keeps a bare language as-is', () {
      expect(canonicalize('fr'), 'fr');
      expect(canonicalize('FR'), 'fr');
    });

    test('normalises region case and separator', () {
      expect(canonicalize('pt_br'), 'pt-BR');
      expect(canonicalize('PT-BR'), 'pt-BR');
      expect(canonicalize('pt-br'), 'pt-BR');
    });

    test('title-cases a script subtag', () {
      expect(canonicalize('zh_hant'), 'zh-Hant');
      expect(canonicalize('ZH-HANT'), 'zh-Hant');
    });

    test('leaves a numeric UN M.49 region alone', () {
      expect(canonicalize('es_419'), 'es-419');
    });

    test('handles script and region together', () {
      expect(canonicalize('zh_hant_hk'), 'zh-Hant-HK');
    });

    test('rejects anything that is not a locale', () {
      expect(() => canonicalize('not a locale'), throwsA(isA<InvalidLocaleCode>()));
      expect(() => canonicalize(''), throwsA(isA<InvalidLocaleCode>()));
      expect(() => canonicalize('e'), throwsA(isA<InvalidLocaleCode>()));
    });
  });

  group('splitLocaleArgs', () {
    test('splits one space- or comma-joined argument into codes', () {
      expect(splitLocaleArgs(<String>['fr de,es', 'ja']),
          <String>['fr', 'de', 'es', 'ja']);
    });
    test('drops empty pieces', () {
      expect(splitLocaleArgs(<String>['fr, ', ' ']), <String>['fr']);
    });
  });

  group('canonicalizeOrKeep', () {
    test('passes junk through so the API can name the field', () {
      expect(canonicalizeOrKeep('not a locale'), 'not a locale');
    });
  });

  group('arbSuffix', () {
    test('is what gen_l10n reads', () {
      // app_pt-BR.arb is not picked up by gen_l10n at all — this is the whole
      // reason the suffix and the code are spelled differently.
      expect(arbSuffix('pt-BR'), 'pt_BR');
      expect(arbSuffix('pt_br'), 'pt_BR');
      expect(arbSuffix('zh-Hant'), 'zh_Hant');
      expect(arbSuffix('es-419'), 'es_419');
      expect(arbSuffix('fr'), 'fr');
    });
  });
}
