import 'dart:convert';
import 'dart:io';

import 'package:flutter_localisation_cli/src/ngx.dart';
import 'package:flutter_localisation_cli/src/platform.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('ngx is a platform of its own, read from the service name', () {
    expect(AppPlatform.fromWire('ngx'), AppPlatform.ngx);
    expect(AppPlatform.ngx.files, '<locale>.json');
    expect(AppPlatform.ngx.liveUpdates, isFalse);
    expect(platformsFromJson(<String>['ngx']), <AppPlatform>[AppPlatform.ngx]);
  });

  test('a translation JSON is told apart from ARBs and catalogs', () {
    expect(isNgxDoc(<String, dynamic>{'a.b': 'x'}), isTrue);
    expect(
        isNgxDoc(<String, dynamic>{
          r'$schema': './i18n.schema.json',
          'HOME': <String, dynamic>{'TITLE': 'x'},
        }),
        isTrue);
    expect(isNgxDoc(<String, dynamic>{'@@locale': 'fr', 'a': 'b'}), isFalse);
    expect(
        isNgxDoc(<String, dynamic>{
          'a': 'b',
          '@a': <String, dynamic>{'description': 'x'},
        }),
        isFalse);
    expect(
        isNgxDoc(<String, dynamic>{
          'sourceLanguage': 'en',
          'strings': <String, dynamic>{},
        }),
        isFalse);
    expect(isNgxDoc(<String, dynamic>{'a': 1}), isFalse);
    expect(isNgxDoc(<String, dynamic>{}), isFalse);
    expect(isNgxDoc(<dynamic>[]), isFalse);
  });

  test('nested keys flatten to dots, schema hints left out', () {
    expect(
        flattenNgx(<String, dynamic>{
          r'$schema': 'x',
          'HOME': <String, dynamic>{
            'TITLE': 't',
            'SUB': <String, dynamic>{'X': 'x'},
          },
          'OK': 'ok',
        }),
        <String, String>{'HOME.TITLE': 't', 'HOME.SUB.X': 'x', 'OK': 'ok'});
  });

  test('a file name gives its locale, a two-letter language first', () {
    expect(ngxLocaleOf('fr.json'), 'fr');
    expect(ngxLocaleOf('src/assets/i18n/de-DE.json'), 'de-DE');
    expect(ngxLocaleOf('pt_BR.json'), 'pt-BR');
    expect(ngxLocaleOf('frx_fr.json'), 'fr');
    expect(ngxLocaleCandidates('frx_fr.json'), <String>['fr', 'frx-FR']);
    expect(ngxLocaleOf('strings.json'), isNull);
    expect(ngxLocaleOf('fr.arb'), isNull);
  });

  group('on disk', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('ngx_test'));
    tearDown(() => tmp.deleteSync(recursive: true));

    File at(final String rel) {
      final File f = File(p.join(tmp.path, rel));
      f.parent.createSync(recursive: true);
      return f;
    }

    test('finds the folder holding <locale>.json files', () {
      expect(ngxDirIn(tmp.path), isNull);
      at('src/assets/i18n/notes.json').writeAsStringSync('{}');
      expect(ngxDirIn(tmp.path), isNull);
      at('src/assets/i18n/fr.json').writeAsStringSync('{}');
      expect(ngxDirIn(tmp.path), 'src/assets/i18n');
    });

    test('knows an ngx-translate app from its package.json', () {
      expect(usesNgxTranslate(tmp.path), isFalse);
      at('angular.json').writeAsStringSync('{}');
      expect(looksLikeLocalizeApp(tmp.path), isTrue);
      at('package.json').writeAsStringSync(jsonEncode(<String, dynamic>{
        'dependencies': <String, String>{'@ngx-translate/core': '^16.0.0'},
      }));
      expect(usesNgxTranslate(tmp.path), isTrue);
      expect(looksLikeLocalizeApp(tmp.path), isFalse);
      at('package.json').writeAsStringSync('not json');
      expect(usesNgxTranslate(tmp.path), isFalse);
    });

    test('names base keys the service lacks and knows a nested file', () {
      final File fr = at('fr.json');
      expect(localOnlyNgxKeys(fr, <String>{'a'}), isEmpty);
      fr.writeAsStringSync(jsonEncode(<String, dynamic>{
        r'$schema': 'x',
        'a': 'A',
        'b': <String, String>{'c': 'C'},
      }));
      expect(localOnlyNgxKeys(fr, <String>{'a'}), <String>['b.c']);
      expect(isNestedNgxFile(fr), isTrue);
      fr.writeAsStringSync('{"a.b": "x"}');
      expect(isNestedNgxFile(fr), isFalse);
      fr.writeAsStringSync('{broken');
      expect(isNestedNgxFile(fr), isFalse);
      expect(localOnlyNgxKeys(fr, <String>{}), isEmpty);
      expect(isNestedNgxFile(File(p.join(tmp.path, 'none.json'))), isFalse);
    });
  });

  group('orderNgxLike', () {
    test('keeps the file\'s order, objects included, and appends new keys', () {
      final Directory tmp = Directory.systemTemp.createTempSync('ngx_order');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final File fr = File('${tmp.path}/fr.json')
        ..writeAsStringSync(jsonEncode(<String, dynamic>{
          'z': 'old',
          'HOME': <String, dynamic>{'TITLE': 't', 'SUB': 's'},
          'gone': 'x',
        }));
      final String body = jsonEncode(<String, dynamic>{
        'HOME': <String, dynamic>{'SUB': 'S', 'TITLE': 'T', 'NEW': 'n'},
        'a': 'new',
        'z': 'Z',
      });
      final Map<String, dynamic> out =
          jsonDecode(orderNgxLike(body, fr)) as Map<String, dynamic>;
      expect(out.keys, <String>['z', 'HOME', 'a']);
      expect((out['HOME'] as Map<String, dynamic>).keys,
          <String>['TITLE', 'SUB', 'NEW']);
      expect(orderNgxLike(body, File('${tmp.path}/none.json')), body);
      fr.writeAsStringSync('{broken');
      expect(orderNgxLike(body, fr), body);
    });
  });
}
