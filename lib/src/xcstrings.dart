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

final RegExp _printfSpec = RegExp(
    r'%(?:(\d+)\$)?[-+ 0#]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|h|ll|l|q|z|t|L)?([@diouxXfFeEgGaAcsSpC%])');

/// `{argN}` for every printf specifier, numbered the way the service numbers
/// a catalog on import: a positional `%2$@` is `{arg2}`, an unnumbered one
/// takes the next free slot. `%%` becomes `%`.
String printfToArgs(final String text) => printfToArgsWithSpecs(text).text;

/// [printfToArgs], plus the specifiers it replaced (`%@`, `%lld`), unnumbered.
({String text, List<String> specs}) printfToArgsWithSpecs(final String text) {
  final List<int> seen = <int>[];
  final List<String> specs = <String>[];
  final String out = text.replaceAllMapped(_printfSpec, (final Match m) {
    if (m.group(2) == '%') return '%';
    specs.add(m.group(0)!.replaceFirst(RegExp(r'^%\d+\$'), '%'));
    final int index = m.group(1) != null
        ? int.parse(m.group(1)!)
        : (seen.isEmpty ? 0 : seen.reduce((final int a, final int b) => a > b ? a : b)) + 1;
    seen.add(index);
    return '{arg$index}';
  });
  return (text: out, specs: specs);
}
