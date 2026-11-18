import 'dart:convert';
import 'dart:io';

import 'package:flutter_localisation_cli/src/xcstrings.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('fl_targets_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  CatalogTarget target(final String dir, {final String? prefix}) =>
      CatalogTarget('${tmp.path}/$dir', infoPlistPrefix: prefix);

  void write(final File file, final Map<String, dynamic> strings) => file
    ..createSync(recursive: true)
    ..writeAsStringSync(jsonEncode(<String, dynamic>{
      'sourceLanguage': 'en',
      'strings': strings,
      'version': '1.0',
    }));

  Map<String, dynamic> unit(final String value) => <String, dynamic>{
        'localizations': <String, dynamic>{
          'en': <String, dynamic>{
            'stringUnit': <String, String>{
              'state': 'translated',
              'value': value
            },
          },
        },
      };

  group('serializeCatalog', () {
    test('writes what Xcode writes', () {
      expect(
        serializeCatalog(<String, dynamic>{
          'version': '1.0',
          'strings': <String, dynamic>{
            'b "quoted"': <String, dynamic>{},
            'a': <String, dynamic>{
              'shouldTranslate': false,
              'localizations': <String, dynamic>{
                'en': <String, dynamic>{
                  'stringUnit': <String, String>{
                    'value': 'Café\n100% — %lld',
                    'state': 'translated',
                  },
                },
              },
            },
          },
          'sourceLanguage': 'en',
        }),
        '{\n'
        '  "sourceLanguage" : "en",\n'
        '  "strings" : {\n'
        '    "a" : {\n'
        '      "localizations" : {\n'
        '        "en" : {\n'
        '          "stringUnit" : {\n'
        '            "state" : "translated",\n'
        '            "value" : "Café\\n100% — %lld"\n'
        '          }\n'
        '        }\n'
        '      },\n'
        '      "shouldTranslate" : false\n'
        '    },\n'
        '    "b \\"quoted\\"" : {\n'
        '\n'
        '    }\n'
        '  },\n'
        '  "version" : "1.0"\n'
        '}\n',
      );
    });

    test('an empty catalog and a list', () {
      expect(
        serializeCatalog(<String, dynamic>{
          'strings': <String, dynamic>{},
          'tags': <String>['a', 'b'],
          'none': <String>[],
        }),
        '{\n  "none" : [],\n  "strings" : {\n\n  },\n'
        '  "tags" : [\n    "a",\n    "b"\n  ]\n}\n',
      );
    });
  });

  group('several targets', () {
    late List<CatalogTarget> targets;
    late String served;

    setUp(() {
      targets = <CatalogTarget>[
        target('App'),
        target('Widgets'),
        target('Mac', prefix: 'mac.'),
      ];
      write(targets[0].localizable, <String, dynamic>{
        'Start': unit('Start (app)'),
        'Shared': unit('Shared'),
        '': <String, dynamic>{},
      });
      write(targets[1].localizable, <String, dynamic>{
        'Shared': unit('Shared (widget copy)'),
        'Widget': unit('Widget'),
      });
      write(targets[2].localizable, <String, dynamic>{'Start': unit('Start')});
      write(targets[2].infoPlist, <String, dynamic>{
        'NSMicrophoneUsageDescription': unit('Mac hears you'),
      });
      served = jsonEncode(<String, dynamic>{
        'sourceLanguage': 'en',
        'version': '1.0',
        'strings': <String, dynamic>{
          'Start': unit('S'),
          'Shared': unit('Sh'),
          'Widget': unit('W'),
          'Unused': unit('U'),
          'mac.NSMicrophoneUsageDescription': unit('M'),
          'mac.note': unit('not a plist key'),
        },
      });
    });

    test('merge is one flat catalog, first target wins, prefix applied', () {
      final Map<String, dynamic> merged =
          mergeTargetCatalogs(targets, sourceLanguage: 'de');
      expect(merged['sourceLanguage'], 'de');
      final Map<String, dynamic> strings =
          merged['strings'] as Map<String, dynamic>;
      expect(strings.keys, <String>[
        'Start',
        'Shared',
        'Widget',
        'mac.NSMicrophoneUsageDescription',
      ]);
      expect(strings['Shared'], unit('Shared'));
      expect(strings['Start'], unit('Start (app)'));
      expect(isCatalogJson(merged), isTrue);
    });

    test('local-only keys are named by their service key', () {
      expect(
        localOnlyTargetKeys(targets, <String>{'Start', 'Shared'}),
        <String>['Widget', 'mac.NSMicrophoneUsageDescription'],
      );
      expect(
        localOnlyTargetKeys(targets, <String>{
          'Start',
          'Shared',
          'Widget',
          'mac.NSMicrophoneUsageDescription',
        }),
        isEmpty,
      );
    });

    test('split gives each file its keys and reports the rest', () {
      final ({Map<String, String> files, List<String> unassigned}) cut =
          splitCatalog(served, targets);
      Map<String, dynamic> strings(final File f) =>
          (jsonDecode(cut.files[f.path]!) as Map<String, dynamic>)['strings']
              as Map<String, dynamic>;

      expect(cut.files.keys, <String>[
        targets[0].localizable.path,
        targets[1].localizable.path,
        targets[2].localizable.path,
        targets[2].infoPlist.path,
      ]);
      expect(strings(targets[0].localizable),
          <String, dynamic>{'Start': unit('S'), 'Shared': unit('Sh')});
      expect(strings(targets[1].localizable),
          <String, dynamic>{'Shared': unit('Sh'), 'Widget': unit('W')});
      expect(strings(targets[2].localizable),
          <String, dynamic>{'Start': unit('S')});
      expect(strings(targets[2].infoPlist),
          <String, dynamic>{'NSMicrophoneUsageDescription': unit('M')});
      expect(cut.unassigned, <String>['Unused', 'mac.note']);
      expect(cut.files[targets[0].localizable.path],
          contains('"sourceLanguage" : "en"'));
    });

    test('a target that declares nothing gets an empty catalog', () {
      write(targets[1].localizable, <String, dynamic>{});
      final ({Map<String, String> files, List<String> unassigned}) cut =
          splitCatalog(served, <CatalogTarget>[targets[1]]);
      expect(
        cut.files[targets[1].localizable.path],
        '{\n  "sourceLanguage" : "en",\n  "strings" : {\n\n  },\n'
        '  "version" : "1.0"\n}\n',
      );
      expect(cut.unassigned, hasLength(6));
    });

    test('a file that is missing or not a catalog declares nothing', () {
      targets[1].localizable.writeAsStringSync('{"strings": 3}');
      targets[0].localizable.deleteSync();
      expect(
        (mergeTargetCatalogs(targets)['strings'] as Map<String, dynamic>).keys,
        <String>['Start', 'mac.NSMicrophoneUsageDescription'],
      );
    });
  });
}
