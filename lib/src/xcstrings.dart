/// Xcode String Catalogs (`.xcstrings`), for projects that ship a native iOS app.
///
/// The CLI never builds a catalog itself: the backend renders it (ICU to printf,
/// plurals to variations, Xcode's own formatting) and `fl pull` / `fl export`
/// write the bytes as served, so the file never differs from what the git
/// mirror holds. What lives here is the little the CLI has to understand on
/// its own: recognising a catalog it is asked to import, and reading its keys
/// for the local-only guard.
///
/// Pure Dart, no network.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// The table every `String(localized:)` call reads from.
const String kLocalizableCatalog = 'Localizable.xcstrings';

/// The permission alerts and the display name, drawn by iOS from the bundle.
const String kInfoPlistCatalog = 'InfoPlist.xcstrings';

/// True for a decoded `.xcstrings` document: a `strings` map plus the
/// `sourceLanguage` Xcode always writes. A bare `{"strings": ...}` is still a
/// plausible hand-written ARB with a key called "strings", which is why both
/// are required.
bool isCatalogJson(final Object? decoded) =>
    decoded is Map<String, dynamic> &&
    decoded['strings'] is Map<String, dynamic> &&
    decoded.containsKey('sourceLanguage');

/// True when [content] is a catalog, by extension or by shape. The extension
/// alone is not enough: the MCP tool receives raw content with no name.
bool looksLikeCatalog(final String content, {final String? fileName}) {
  if (fileName != null && fileName.endsWith('.xcstrings')) return true;
  try {
    return isCatalogJson(jsonDecode(content));
  } catch (_) {
    return false;
  }
}

/// The keys of a catalog's `strings` table, in file order.
List<String> catalogKeys(final Object? decoded) {
  if (!isCatalogJson(decoded)) return const <String>[];
  return ((decoded! as Map<String, dynamic>)['strings'] as Map<String, dynamic>)
      .keys
      .toList();
}

/// Keys present in the catalog on disk that the service does not have.
///
/// The catalog counterpart of `localOnlyKeys` for ARBs: a pull rewrites the
/// file from the service, so a key an iOS developer added in Xcode and never
/// imported would be lost without this check.
List<String> localOnlyCatalogKeys(
  final File catalogFile,
  final Set<String> serviceKeys,
) {
  if (!catalogFile.existsSync()) return const <String>[];
  Object? decoded;
  try {
    decoded = jsonDecode(catalogFile.readAsStringSync());
  } catch (_) {
    return const <String>[];
  }
  return <String>[
    // Xcode extracts Text("") as an empty key, which the service never
    // stores. Counting it blocked every export with an unnamed "1 key".
    for (final String key in catalogKeys(decoded))
      if (key.isNotEmpty && !serviceKeys.contains(key)) key,
  ]..sort();
}

/// App Shortcut phrases, which Xcode reads from their own catalog.
const String kAppShortcutsCatalog = 'AppShortcuts.xcstrings';

final RegExp _infoPlistKey = RegExp(
    r'^(NS[A-Za-z]+UsageDescription|CFBundle(DisplayName|Name)|NSHumanReadableCopyright)$');

/// One catalog of an app with several: a target's folder, whose
/// `Localizable.xcstrings` holds the strings that target's code uses, or a
/// named table (`Posts.xcstrings`, read in Swift with `tableName: "Posts"`).
///
/// [infoPlistPrefix] is for a second target with an Info.plist of its own (a
/// Mac app beside the iPhone one): its permission sentences are kept on the
/// service under that prefix (`mac.NSMicrophoneUsageDescription`) and written
/// to this folder's `InfoPlist.xcstrings` without it.
class CatalogTarget {
  const CatalogTarget(this.dir, {this.infoPlistPrefix}) : table = null;

  /// A named table: [path] is the `.xcstrings` file itself.
  CatalogTarget.table(final String path)
      : dir = p.dirname(p.normalize(path)),
        table = p.normalize(path),
        infoPlistPrefix = null;

  final String dir;
  final String? infoPlistPrefix;

  /// The path of a named table, null for a folder.
  final String? table;

  File get localizable => File(table ?? p.join(dir, kLocalizableCatalog));
  File get infoPlist => File(p.join(dir, kInfoPlistCatalog));
}

/// The catalogs of `xcstrings_catalogs` a path names, or a catalog on its
/// own when the config does not list it.
List<CatalogTarget> catalogsNamed(
    final String path, final List<CatalogTarget>? targets) {
  for (final CatalogTarget t in targets ?? const <CatalogTarget>[]) {
    if (p.equals(t.localizable.path, path)) {
      return <CatalogTarget>[t];
    }
  }
  return <CatalogTarget>[CatalogTarget.table(path)];
}

Map<String, dynamic> _stringsOf(final File file) {
  if (!file.existsSync()) return <String, dynamic>{};
  final Object? decoded = jsonDecode(file.readAsStringSync());
  if (!isCatalogJson(decoded)) return <String, dynamic>{};
  return (decoded! as Map<String, dynamic>)['strings'] as Map<String, dynamic>;
}

/// Every string the targets' catalogs hold, under the key the service knows
/// it by, as one catalog. The first target that declares a key provides it,
/// and a language only a later catalog translates is added to it.
///
/// What `fl pull --adopt` imports for an app with several catalogs: the
/// service has one flat set of keys, and a string shared by the app and its
/// widget is one key there. [catalogConflicts] is asked first, so the texts
/// that meet here are the same.
///
/// [only] keeps just those keys: the new ones are all an import needs, and a
/// whole app in thirty languages is too large for one upload.
Map<String, dynamic> mergeTargetCatalogs(
  final List<CatalogTarget> targets, {
  final String sourceLanguage = 'en',
  final Set<String>? only,
}) {
  final Map<String, dynamic> all = <String, dynamic>{};
  final Map<String, dynamic> strings = only == null ? all : <String, dynamic>{};
  void add(final String key, final dynamic v) {
    final Object? had = all[key];
    if (had == null) {
      all[key] = v;
      return;
    }
    final Object? mine = had is Map ? had['localizations'] : null;
    final Object? theirs = v is Map ? v['localizations'] : null;
    if (mine is! Map || theirs is! Map) {
      if (mine == null && theirs is Map) all[key] = v;
      return;
    }
    final Iterable<Object?> missing =
        theirs.keys.where((final Object? l) => !mine.containsKey(l));
    if (missing.isEmpty) return;
    all[key] = <String, dynamic>{
      ...had as Map<String, dynamic>,
      'localizations': <String, dynamic>{
        ...mine as Map<String, dynamic>,
        for (final Object? l in missing) l! as String: theirs[l],
      },
    };
  }

  for (final CatalogTarget target in targets) {
    _stringsOf(target.localizable).forEach((final String key, final dynamic v) {
      // Xcode extracts Text("") as an empty key, which the service refuses.
      if (key.isNotEmpty) add(key, v);
    });
    final String? prefix = target.infoPlistPrefix;
    if (prefix != null) {
      _stringsOf(target.infoPlist).forEach((final String key, final dynamic v) {
        add('$prefix$key', v);
      });
    }
  }
  if (only != null) {
    all.forEach((final String key, final dynamic v) {
      if (only.contains(key)) strings[key] = v;
    });
  }
  return <String, dynamic>{
    'sourceLanguage': sourceLanguage,
    'strings': strings,
    'version': '1.0',
  };
}

/// Keys the targets' catalogs hold that the service does not have, sorted.
List<String> localOnlyTargetKeys(
  final List<CatalogTarget> targets,
  final Set<String> serviceKeys,
) =>
    <String>[
      for (final String key
          in (mergeTargetCatalogs(targets)['strings'] as Map<String, dynamic>)
              .keys)
        if (!serviceKeys.contains(key)) key,
    ]..sort();

/// What a language of a catalog entry says, without the review `state`
/// Xcode and the service each set their own way: a plural or a device
/// variation keeps its shape, so a plural against a plain string differs.
Object? _textOf(final Object? node) {
  if (node is Map) {
    return <String, Object?>{
      for (final MapEntry<dynamic, dynamic> e in node.entries)
        if (e.key != 'state') e.key as String: _textOf(e.value),
    };
  }
  if (node is List) return node.map(_textOf).toList();
  return node;
}

/// The languages whose text differs between two entries of one key, among
/// those both translate.
List<String> catalogTextDifferences(final Object? a, final Object? b) {
  final Object? la = a is Map ? a['localizations'] : null;
  final Object? lb = b is Map ? b['localizations'] : null;
  if (la is! Map || lb is! Map) return const <String>[];
  return <String>[
    for (final Object? lang in la.keys)
      if (lb.containsKey(lang) &&
          jsonEncode(_textOf(la[lang])) != jsonEncode(_textOf(lb[lang])))
        lang! as String,
  ];
}

/// One key whose text is not the same in every catalog that declares it.
class CatalogConflict {
  const CatalogConflict(this.key, this.files, this.languages);

  final String key;

  /// Every file that declares the key, in config order.
  final List<String> files;

  /// The languages whose text differs between them.
  final List<String> languages;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'key': key,
        'files': files,
        'languages': languages,
      };
}

/// Keys declared by several catalogs with a different text in at least one
/// language both translate. The service keeps one text per key, so these
/// cannot be imported or written back without one of them being lost.
///
/// A language only one catalog has is not a difference, and neither is an
/// entry Xcode extracted with no text yet. [only] narrows to those keys.
List<CatalogConflict> catalogConflicts(
  final List<CatalogTarget> targets, {
  final Set<String>? only,
}) {
  final Map<String, List<(String, Object?)>> seen =
      <String, List<(String, Object?)>>{};
  for (final CatalogTarget target in targets) {
    _stringsOf(target.localizable).forEach((final String key, final dynamic v) {
      if (key.isEmpty || (only != null && !only.contains(key))) return;
      (seen[key] ??= <(String, Object?)>[]).add((target.localizable.path, v));
    });
  }
  final List<CatalogConflict> conflicts = <CatalogConflict>[];
  seen.forEach((final String key, final List<(String, Object?)> at) {
    if (at.length < 2) return;
    final Set<String> languages = <String>{
      for (int i = 0; i < at.length; i++)
        for (int j = i + 1; j < at.length; j++)
          ...catalogTextDifferences(at[i].$2, at[j].$2),
    };
    if (languages.isEmpty) return;
    conflicts.add(CatalogConflict(
      key,
      <String>[for (final (String, Object?) a in at) a.$1],
      languages.toList()..sort(),
    ));
  });
  return conflicts;
}

/// [conflicts] for a person, each key with its files, then what to do.
/// [shown] turns a path into what the user would type; [refused] says
/// the command stopped on them.
String describeCatalogConflicts(
  final List<CatalogConflict> conflicts, {
  final String Function(String path)? shown,
  final bool refused = true,
}) =>
    <String>[
      '${conflicts.length} key(s) have a different text in different '
          'catalogs, and the service keeps one text per key. '
          '${refused ? 'Nothing was sent or written:' : 'Pull, export and import stop on them:'}',
      for (final CatalogConflict c in conflicts)
        '  ${c.key}: ${c.files.map(shown ?? (final String f) => f).join(', ')} '
            '(${c.languages.join(', ')})',
      'Rename the key in one table (in its catalog and in the Swift that reads '
          'it) so each text has its own key, or make the texts the same.',
    ].join('\n');

/// The service's one `Localizable` catalog, cut into the targets' files.
///
/// Each target keeps the keys its catalog declares now: Xcode decides which
/// string belongs to which target when it extracts them from the code, and
/// the service only fills in the languages. [files] maps a path to its new
/// contents; [unassigned] are service keys no target declares, usually
/// strings the code stopped using.
({Map<String, String> files, List<String> unassigned}) splitCatalog(
  final String served,
  final List<CatalogTarget> targets,
) {
  final Map<String, dynamic> catalog =
      jsonDecode(served) as Map<String, dynamic>;
  final Map<String, dynamic> all = catalog['strings'] as Map<String, dynamic>;
  final List<String> prefixes = <String>[
    for (final CatalogTarget t in targets)
      if (t.infoPlistPrefix != null) t.infoPlistPrefix!,
  ];
  bool prefixed(final String key) => prefixes.any((final String p) =>
      key.startsWith(p) && _infoPlistKey.hasMatch(key.substring(p.length)));

  Map<String, dynamic> wrap(final Map<String, dynamic> strings) =>
      <String, dynamic>{...catalog, 'strings': strings};

  final Map<String, String> files = <String, String>{};
  final Set<String> assigned = <String>{};
  for (final CatalogTarget target in targets) {
    final Map<String, dynamic> mine = <String, dynamic>{
      for (final String key in _stringsOf(target.localizable).keys)
        if (all.containsKey(key) && !prefixed(key)) key: all[key],
    };
    assigned.addAll(mine.keys);
    files[target.localizable.path] = serializeCatalog(wrap(mine));
    final String? prefix = target.infoPlistPrefix;
    if (prefix == null) continue;
    final Map<String, dynamic> plist = <String, dynamic>{
      for (final MapEntry<String, dynamic> e in all.entries)
        if (e.key.startsWith(prefix) &&
            _infoPlistKey.hasMatch(e.key.substring(prefix.length)))
          e.key.substring(prefix.length): e.value,
    };
    assigned.addAll(plist.keys.map((final String k) => '$prefix$k'));
    if (plist.isNotEmpty) {
      files[target.infoPlist.path] = serializeCatalog(wrap(plist));
    }
  }
  return (
    files: files,
    unassigned: <String>[
      for (final String key in all.keys)
        if (!assigned.contains(key)) key,
    ]..sort(),
  );
}

/// A catalog in Xcode's own formatting: sorted keys, two-space indent, ` : `
/// between key and value, an empty object spread over three lines. The same
/// bytes the service writes, so a build in Xcode leaves the file alone.
String serializeCatalog(final Map<String, dynamic> catalog) {
  final StringBuffer out = StringBuffer();
  void write(final Object? node, final String indent) {
    if (node is Map) {
      if (node.isEmpty) {
        out.write('{\n\n$indent}');
        return;
      }
      final List<String> keys = node.keys.cast<String>().toList()..sort();
      out.write('{\n');
      for (int i = 0; i < keys.length; i++) {
        out.write('$indent  ${jsonEncode(keys[i])} : ');
        write(node[keys[i]], '$indent  ');
        out.write(i == keys.length - 1 ? '\n' : ',\n');
      }
      out.write('$indent}');
    } else if (node is List) {
      if (node.isEmpty) {
        out.write('[]');
        return;
      }
      out.write('[\n');
      for (int i = 0; i < node.length; i++) {
        out.write('$indent  ');
        write(node[i], '$indent  ');
        out.write(i == node.length - 1 ? '\n' : ',\n');
      }
      out.write('$indent]');
    } else {
      out.write(jsonEncode(node));
    }
  }

  write(catalog, '');
  out.write('\n');
  return out.toString();
}
