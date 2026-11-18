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

/// One target's folder of an app with several: its `Localizable.xcstrings`
/// holds the strings that target's code uses.
///
/// [infoPlistPrefix] is for a second target with an Info.plist of its own (a
/// Mac app beside the iPhone one): its permission sentences are kept on the
/// service under that prefix (`mac.NSMicrophoneUsageDescription`) and written
/// to this folder's `InfoPlist.xcstrings` without it.
class CatalogTarget {
  const CatalogTarget(this.dir, {this.infoPlistPrefix});

  final String dir;
  final String? infoPlistPrefix;

  File get localizable => File('$dir/$kLocalizableCatalog');
  File get infoPlist => File('$dir/$kInfoPlistCatalog');
}

Map<String, dynamic> _stringsOf(final File file) {
  if (!file.existsSync()) return <String, dynamic>{};
  final Object? decoded = jsonDecode(file.readAsStringSync());
  if (!isCatalogJson(decoded)) return <String, dynamic>{};
  return (decoded! as Map<String, dynamic>)['strings'] as Map<String, dynamic>;
}

/// Every string the targets' catalogs hold, under the key the service knows
/// it by, as one catalog. The first target that declares a key provides it.
///
/// What `fl pull --adopt` imports for an app with several catalogs: the
/// service has one flat set of keys, and a string shared by the app and its
/// widget is one key there.
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
  for (final CatalogTarget target in targets) {
    _stringsOf(target.localizable).forEach((final String key, final dynamic v) {
      // Xcode extracts Text("") as an empty key, which the service refuses.
      if (key.isNotEmpty) all.putIfAbsent(key, () => v);
    });
    final String? prefix = target.infoPlistPrefix;
    if (prefix != null) {
      _stringsOf(target.infoPlist).forEach((final String key, final dynamic v) {
        all.putIfAbsent('$prefix$key', () => v);
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
