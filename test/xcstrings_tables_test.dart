import 'dart:convert';
import 'dart:io';

import 'package:flutter_localisation_cli/src/config.dart';
import 'package:flutter_localisation_cli/src/exceptions.dart';
import 'package:flutter_localisation_cli/src/init_detect.dart';
import 'package:flutter_localisation_cli/src/xcstrings.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory(Directory.systemTemp
      .createTempSync('fl_tables_test')
      .resolveSymbolicLinksSync()));
  tearDown(() => tmp.deleteSync(recursive: true));

  File file(final String rel) => File(p.join(tmp.path, rel));

  void write(final String rel, final Map<String, dynamic> strings) => file(rel)
    ..createSync(recursive: true)
    ..writeAsStringSync(jsonEncode(<String, dynamic>{
      'sourceLanguage': 'en',
      'strings': strings,
      'version': '1.0',
    }));

  Map<String, dynamic> unit(final String value,
          {final String state = 'translated'}) =>
      <String, dynamic>{
        'stringUnit': <String, String>{'state': state, 'value': value},
      };
  Map<String, dynamic> entry(final Map<String, dynamic> byLocale) =>
      <String, dynamic>{
        'extractionState': 'manual',
        'localizations': byLocale,
      };

  group('named tables', () {
    late List<CatalogTarget> targets;

    setUp(() {
      write('App/Localizable.xcstrings', <String, dynamic>{
        'home.title': entry(<String, dynamic>{'en': unit('Home')}),
        'shared.ok': entry(<String, dynamic>{
          'en': unit('OK'),
          'fr': unit("D'accord"),
        }),
      });
      write('App/Posts/Posts.xcstrings', <String, dynamic>{
        'posts.title': entry(<String, dynamic>{'en': unit('Posts')}),
        'shared.ok': entry(<String, dynamic>{
          'en': unit('OK', state: 'needs_review'),
          'de': unit('OK'),
        }),
      });
      targets = <CatalogTarget>[
        CatalogTarget(p.join(tmp.path, 'App')),
        CatalogTarget.table(p.join(tmp.path, 'App/Posts/Posts.xcstrings')),
      ];
    });

    test('a table is its own file, in the folder that holds it', () {
      expect(targets[1].localizable.path,
          p.join(tmp.path, 'App', 'Posts', 'Posts.xcstrings'));
      expect(targets[1].dir, p.join(tmp.path, 'App', 'Posts'));
      expect(targets[1].table, isNotNull);
      expect(targets[0].table, isNull);
    });

    test('the same text in two files is one key, with every language', () {
      expect(catalogConflicts(targets), isEmpty,
          reason: 'a review state is not a text, and a language only one '
              'file has is not a difference');
      final Map<String, dynamic> strings =
          mergeTargetCatalogs(targets)['strings'] as Map<String, dynamic>;
      expect(strings.keys, <String>['home.title', 'shared.ok', 'posts.title']);
      expect(
        (strings['shared.ok'] as Map<String, dynamic>)['localizations'],
        <String, dynamic>{
          'en': unit('OK'),
          'fr': unit("D'accord"),
          'de': unit('OK'),
        },
      );
    });

    test('a different text in any language is a conflict naming both files',
        () {
      write('App/Posts/Posts.xcstrings', <String, dynamic>{
        'shared.ok': entry(<String, dynamic>{
          'en': unit('OK'),
          'fr': unit('Oui'),
        }),
      });
      final List<CatalogConflict> conflicts = catalogConflicts(targets);
      expect(conflicts, hasLength(1));
      expect(conflicts.single.key, 'shared.ok');
      expect(conflicts.single.languages, <String>['fr']);
      expect(conflicts.single.files, <String>[
        targets[0].localizable.path,
        targets[1].localizable.path,
      ]);
      final String said = describeCatalogConflicts(conflicts,
          shown: (final String f) => p.relative(f, from: tmp.path));
      expect(said, contains('Nothing was sent'));
      expect(
          said,
          contains('shared.ok: ${p.join('App', 'Localizable.xcstrings')}, '
              '${p.join('App', 'Posts', 'Posts.xcstrings')} (fr)'));
      expect(said, contains('Rename the key in one table'));
      expect(catalogConflicts(targets, only: <String>{'home.title'}), isEmpty);
    });

    test('a plural against a plain string is a conflict', () {
      write('App/Posts/Posts.xcstrings', <String, dynamic>{
        'shared.ok': entry(<String, dynamic>{
          'en': <String, dynamic>{
            'variations': <String, dynamic>{
              'plural': <String, dynamic>{
                'one': unit('OK'),
                'other': unit('OK'),
              },
            },
          },
        }),
      });
      expect(catalogConflicts(targets).single.languages, <String>['en']);
    });

    test('an entry Xcode extracted with no text yet is not a conflict', () {
      write('App/Posts/Posts.xcstrings', <String, dynamic>{
        'shared.ok': <String, dynamic>{},
      });
      expect(catalogConflicts(targets), isEmpty);
    });

    test('split writes a table only the keys it declares', () {
      final String served = jsonEncode(<String, dynamic>{
        'sourceLanguage': 'en',
        'version': '1.0',
        'strings': <String, dynamic>{
          'home.title': entry(<String, dynamic>{'en': unit('Home')}),
          'shared.ok': entry(<String, dynamic>{'en': unit('OK')}),
          'posts.title': entry(<String, dynamic>{'en': unit('Posts')}),
          'gone': entry(<String, dynamic>{'en': unit('Gone')}),
        },
      });
      final ({Map<String, String> files, List<String> unassigned}) cut =
          splitCatalog(served, targets);
      Iterable<String> keys(final CatalogTarget t) =>
          catalogKeys(jsonDecode(cut.files[t.localizable.path]!));
      expect(keys(targets[0]), <String>['home.title', 'shared.ok']);
      expect(keys(targets[1]), <String>['posts.title', 'shared.ok']);
      expect(cut.files[targets[1].localizable.path],
          startsWith('{\n  "sourceLanguage" : "en",\n  "strings" : {\n'));
      expect(cut.unassigned, <String>['gone']);
    });
  });

  group('config', () {
    File cfg(final List<Object> catalogs) => file('flutterlocalisation.json')
      ..writeAsStringSync(jsonEncode(<String, Object>{
        'project': 'Gush',
        'xcstrings_catalogs': catalogs,
      }));

    test('folders, a table by its file, a Localizable path is its folder', () {
      final ProjectConfig c = ProjectConfig.load(
          path: cfg(<Object>[
        'App/Posts/Posts.xcstrings',
        'App',
        'Widgets/Localizable.xcstrings',
      ]).path);
      final List<CatalogTarget> t = c.xcstringsCatalogs!;
      expect(t[0].table, p.join(tmp.path, 'App', 'Posts', 'Posts.xcstrings'));
      expect(t[1].table, isNull);
      expect(t[1].localizable.path,
          p.join(tmp.path, 'App', 'Localizable.xcstrings'));
      expect(t[2].table, isNull);
      expect(t[2].dir, p.join(tmp.path, 'Widgets'));
      expect(c.catalogDir, p.join(tmp.path, 'App'),
          reason: 'InfoPlist goes beside the first folder, not a table');
    });

    test('InfoPlist and AppShortcuts are not listed', () {
      for (final String name in <String>[
        'App/InfoPlist.xcstrings',
        'App/AppShortcuts.xcstrings',
      ]) {
        expect(
          () => ProjectConfig.load(path: cfg(<Object>['App', name]).path),
          throwsA(isA<ConfigException>().having(
              (final ConfigException e) => e.message,
              'message',
              contains('written beside the first folder'))),
        );
      }
    });
  });

  test('init finds every catalog, the InfoPlist folder first', () {
    write('StudioPostingWidgets/Localizable.xcstrings', <String, dynamic>{});
    write('StudioPosting/Resources/Localizable.xcstrings', <String, dynamic>{});
    write('StudioPosting/Resources/InfoPlist.xcstrings', <String, dynamic>{});
    write('StudioPosting/Posts/Posts.xcstrings', <String, dynamic>{});
    write('StudioPosting/Brand/Brand.xcstrings', <String, dynamic>{});
    write('build/Copy/Localizable.xcstrings', <String, dynamic>{});
    expect(
        catalogEntries(tmp),
        <String>[
          'StudioPosting/Resources',
          'StudioPostingWidgets',
          'StudioPosting/Brand/Brand.xcstrings',
          'StudioPosting/Posts/Posts.xcstrings',
        ],
        reason: 'written to the config, so the same on every OS');
  });

  test('init leaves an app with one catalog to xcstrings_dir', () {
    write('App/Localizable.xcstrings', <String, dynamic>{});
    write('App/InfoPlist.xcstrings', <String, dynamic>{});
    expect(catalogEntries(tmp), isNull);
  });

  test('catalog paths take the separator of the OS, a path matches either way',
      () {
    final CatalogTarget folder = CatalogTarget(p.join(tmp.path, 'App'));
    final CatalogTarget table =
        CatalogTarget.table('${tmp.path}/App/Posts/Posts.xcstrings');
    for (final String path in <String>[
      folder.localizable.path,
      folder.infoPlist.path,
      table.localizable.path,
      table.infoPlist.path,
    ]) {
      expect(path, p.normalize(path));
    }
    expect(table.localizable.path,
        p.join(tmp.path, 'App', 'Posts', 'Posts.xcstrings'));
    expect(
        catalogsNamed('${tmp.path}/App/Localizable.xcstrings',
            <CatalogTarget>[table, folder]).single,
        same(folder));
  });

  // On macOS and Linux '/' is the separator, so a path written as
  // '$dir/$file' only shows up wrong on Windows; this catches it everywhere.
  test('the catalog code joins paths with package:path', () {
    final RegExp slashJoin = RegExp(r'''['"]\$\{?[\w.!()]+\}?/\$''');
    for (final String source in <String>[
      'lib/src/xcstrings.dart',
      'lib/src/init_detect.dart',
      'lib/src/repo_platforms.dart',
      'lib/src/file_diff.dart',
    ]) {
      final List<String> lines = File(source).readAsLinesSync();
      for (int i = 0; i < lines.length; i++) {
        expect(slashJoin.hasMatch(lines[i]), isFalse,
            reason: '$source:${i + 1}: ${lines[i].trim()}');
      }
    }
  });
}
