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
    // An array or a number is still a translation file; the service lists it.
    expect(isNgxDoc(<String, dynamic>{'a': 1}), isTrue);
    expect(
        isNgxDoc(<String, dynamic>{
          'a': <String, dynamic>{
            'b': <String>['x']
          }
        }),
        isTrue);
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

    test('names base keys the service lacks and would take', () {
      final File fr = at('fr.json');
      expect(localOnlyNgxKeys(fr, <String>{'a'}), isEmpty);
      fr.writeAsStringSync(jsonEncode(<String, dynamic>{
        r'$schema': 'x',
        'a': 'A',
        'b': <String, String>{'c': 'C'},
      }));
      expect(localOnlyNgxKeys(fr, <String>{'a'}), <String>['b.c']);
      // What the service refuses is not waiting to be imported.
      fr.writeAsStringSync(jsonEncode(<String, dynamic>{
        'a': 'A',
        'path': 'Hi {{ user.name }}',
        'brace': 'Use {curly}',
        'days': <String>['Mon'],
        'ok': 'Hi {{ name }}',
      }));
      expect(localOnlyNgxKeys(fr, <String>{'a'}), <String>['ok']);
      fr.writeAsStringSync('{broken');
      expect(localOnlyNgxKeys(fr, <String>{}), isEmpty);
    });
  });

  test('ngxRefuses follows the rules of the service', () {
    expect(ngxRefuses('Hello {{ name }}, {{count}} posts'), isFalse);
    expect(ngxRefuses('plain <b>text</b>'), isFalse);
    expect(ngxRefuses('{n, plural, one {# post} other {# posts}}'), isFalse);
    expect(ngxRefuses('Hi {{ user.name }}'), isTrue);
    expect(ngxRefuses('Total {{ n | number }}'), isTrue);
    expect(ngxRefuses('Use {curly}'), isTrue);
    expect(ngxRefuses('a } b'), isTrue);
    expect(ngxRefuses(<String>['Mon']), isTrue);
    expect(ngxRefuses(3), isTrue);
    expect(ngxRefuses(null), isTrue);
  });

  group('composeNgx', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('ngx_compose'));
    tearDown(() => tmp.deleteSync(recursive: true));
    Map<String, dynamic> compose(
            final Map<String, dynamic> served, final File file,
            {final File? shapeOf, final bool keepLocalOnly = false}) =>
        jsonDecode(composeNgx(jsonEncode(served), file,
            shapeOf: shapeOf,
            keepLocalOnly: keepLocalOnly)) as Map<String, dynamic>;

    test('keeps the order and the shape of each key, and appends new keys', () {
      final File fr = File('${tmp.path}/fr.json')
        ..writeAsStringSync(jsonEncode(<String, dynamic>{
          'z': 'old',
          'HOME': <String, dynamic>{'TITLE': 't', 'SUB': 's'},
          'pdp.cart.label': 'flat',
          'gone': 'x',
        }));
      final Map<String, dynamic> out = compose(<String, dynamic>{
        'HOME.NEW': 'n',
        'HOME.SUB': 'S',
        'HOME.TITLE': 'T',
        'a.b': 'new',
        'pdp.cart.label': 'Flat',
        'z': 'Z',
      }, fr);
      expect(out.keys, <String>['z', 'HOME', 'pdp.cart.label', 'a']);
      expect(
          out['HOME'], <String, dynamic>{'TITLE': 'T', 'SUB': 'S', 'NEW': 'n'});
      expect((out['HOME'] as Map<String, dynamic>).keys,
          <String>['TITLE', 'SUB', 'NEW']);
      expect(out['a'], <String, dynamic>{'b': 'new'});
    });

    test('a flat file stays flat, and so does a first file', () {
      final File fr = File('${tmp.path}/fr.json')
        ..writeAsStringSync('{"b.c": "x"}');
      final Map<String, dynamic> served = <String, dynamic>{
        'a.b': 'A',
        'b.c': 'B'
      };
      expect(compose(served, fr).keys, <String>['b.c', 'a.b']);
      expect(compose(served, File('${tmp.path}/none.json')), served);
      fr.writeAsStringSync('{broken');
      expect(compose(served, fr), served);
    });

    test('what the service cannot hold is written back', () {
      final Map<String, dynamic> mine = <String, dynamic>{
        r'$schema': './schema.json',
        'PATH': 'Signed in as {{ user.name }}',
        'OK': 'old',
        'MENU': <String, dynamic>{
          'DAYS': <String>['Mon', 'Tue'],
          'BRACE': 'Use {curly}',
          'COUNT': 3,
          'NIL': null,
        },
        'gone': 'deleted in the dashboard',
      };
      final File en = File('${tmp.path}/en.json')
        ..writeAsStringSync(jsonEncode(mine));
      final Map<String, dynamic> out =
          compose(<String, dynamic>{'OK': 'Okay'}, en);
      expect(out, <String, dynamic>{...mine, 'OK': 'Okay'}..remove('gone'));
      expect(out.keys, <String>[r'$schema', 'PATH', 'OK', 'MENU']);
      // After an import, what is still only in the file was refused.
      expect(
          compose(<String, dynamic>{'OK': 'Okay'}, en,
              keepLocalOnly: true)['gone'],
          'deleted in the dashboard');
    });

    test('a new language takes the shape and the order of the base file', () {
      final File en = File('${tmp.path}/en.json')
        ..writeAsStringSync(jsonEncode(<String, dynamic>{
          r'$schema': 's',
          'HOME': <String, dynamic>{'TITLE': 't', 'PATH': '{{ a.b }}'},
          'flat.key': 'f',
        }));
      final Map<String, dynamic> out = compose(<String, dynamic>{
        'flat.key': 'F',
        'HOME.TITLE': 'T',
        'other.one': 'o',
      }, File('${tmp.path}/de.json'), shapeOf: en);
      expect(out, <String, dynamic>{
        'HOME': <String, dynamic>{'TITLE': 'T'},
        'flat.key': 'F',
        'other': <String, dynamic>{'one': 'o'},
      });
      expect(out.keys, <String>['HOME', 'flat.key', 'other']);
    });

    test('a key that is also a parent stays flat', () {
      expect(
          assembleNgx(<String, dynamic>{'a': 'x', 'a.b': 'y', 'c.d': 'z'},
              nested: true),
          <String, dynamic>{
            'a': 'x',
            'a.b': 'y',
            'c': <String, dynamic>{'d': 'z'}
          });
      expect(assembleNgx(<String, dynamic>{'a.b': 'y', 'a': 'x'}, nested: true),
          <String, dynamic>{'a': 'x', 'a.b': 'y'});
    });
  });
}
