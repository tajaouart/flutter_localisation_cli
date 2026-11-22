/// Angular apps that translate at runtime with ngx-translate (or Transloco):
/// one `<locale>.json` per language, usually in `src/assets/i18n`, keys flat
/// (`"a.b": "..."`) or nested (`{"a": {"b": "..."}}`), placeholders written
/// `{{ name }}`.
///
/// The service converts the placeholders both ways; the CLI only moves the
/// files and keeps a nested file nested.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'locales.dart';

const String kNgxDefaultDir = 'src/assets/i18n';

/// Folders an ngx-translate app usually loads its files from.
const List<String> kNgxCandidateDirs = <String>[
  'src/assets/i18n',
  'public/i18n',
  'src/assets/locale',
  'assets/i18n',
];

String ngxFileName(final String code) => '$code.json';

/// A translation JSON: no `@@locale`, no `@key` metadata, only strings and
/// objects of strings.
bool isNgxDoc(final Object? parsed) {
  if (parsed is! Map<String, dynamic> || parsed.isEmpty) return false;
  if (parsed.containsKey('@@locale')) return false;
  if (parsed.containsKey('sourceLanguage') && parsed.containsKey('strings')) {
    return false;
  }
  bool plain(final Map<String, dynamic> node) {
    for (final MapEntry<String, dynamic> e in node.entries) {
      if (e.key.startsWith('@')) return false;
      final Object? v = e.value;
      if (v is Map<String, dynamic>) {
        if (!plain(v)) return false;
      } else if (v is! String) {
        return false;
      }
    }
    return true;
  }

  return plain(parsed);
}

/// Dotted keys of a translation JSON, `$schema` and other `$` keys left out.
Map<String, String> flattenNgx(final Map<String, dynamic> doc) {
  final Map<String, String> flat = <String, String>{};
  void walk(final Map<String, dynamic> node, final String prefix) {
    for (final MapEntry<String, dynamic> e in node.entries) {
      final String key = prefix.isEmpty ? e.key : '$prefix.${e.key}';
      final Object? v = e.value;
      if (v is Map<String, dynamic>) {
        walk(v, key);
      } else if (v is String && !key.startsWith(r'$')) {
        flat[key] = v;
      }
    }
  }

  walk(doc, '');
  return flat;
}

/// Whether the JSON at [file] keeps its keys in objects.
bool isNestedNgxFile(final File file) {
  if (!file.existsSync()) return false;
  try {
    final Object? doc = jsonDecode(file.readAsStringSync());
    return doc is Map<String, dynamic> &&
        doc.values.any((final Object? v) => v is Map);
  } on FormatException {
    return false;
  }
}

/// [body] (a downloaded translation JSON) with its keys in the order the
/// file at [existing] already has them, objects included; keys the file lacks
/// follow in the service's order. A pull then rewrites only the lines that
/// changed instead of sorting the developer's file.
String orderNgxLike(final String body, final File existing) {
  if (!existing.existsSync()) return body;
  final Object? doc = jsonDecode(body);
  final Object? old;
  try {
    old = jsonDecode(existing.readAsStringSync());
  } on FormatException {
    return body;
  }
  if (doc is! Map<String, dynamic> || old is! Map<String, dynamic>) return body;
  return '${const JsonEncoder.withIndent('  ').convert(_orderLike(doc, old))}\n';
}

Map<String, dynamic> _orderLike(
    final Map<String, dynamic> doc, final Map<String, dynamic> old) {
  final Map<String, dynamic> out = <String, dynamic>{};
  for (final String k in old.keys) {
    if (!doc.containsKey(k)) continue;
    final Object? v = doc[k];
    final Object? was = old[k];
    out[k] = v is Map<String, dynamic> && was is Map<String, dynamic>
        ? _orderLike(v, was)
        : v;
  }
  for (final MapEntry<String, dynamic> e in doc.entries) {
    out.putIfAbsent(e.key, () => e.value);
  }
  return out;
}

/// The locales a file name may carry, most likely first: `fr.json`,
/// `de-DE.json`, `pt_BR.json`, then without a prefix (`frx_fr.json`,
/// `app_pt_BR.json`). A two-letter language comes before a three-letter one,
/// which in a file name is more often a word (`frx_fr` is `fr`).
List<String> ngxLocaleCandidates(final String fileName) {
  final String name = p.basename(fileName);
  if (!name.endsWith('.json')) return const <String>[];
  final List<String> parts =
      name.substring(0, name.length - '.json'.length).split('_');
  final List<String> found = <String>[];
  for (int start = 0; start < parts.length; start++) {
    try {
      final String code = canonicalize(parts.sublist(start).join('_'));
      if (!found.contains(code)) found.add(code);
    } on InvalidLocaleCode {
      continue;
    }
  }
  return <String>[
    ...found.where((final String c) => c.split('-').first.length == 2),
    ...found.where((final String c) => c.split('-').first.length != 2),
  ];
}

/// The likeliest locale of a file name, or null.
String? ngxLocaleOf(final String fileName) {
  final List<String> found = ngxLocaleCandidates(fileName);
  return found.isEmpty ? null : found.first;
}

/// The first usual folder under [root] that holds a `<locale>.json`, or null.
String? ngxDirIn(final String root) {
  for (final String dir in kNgxCandidateDirs) {
    final Directory d = Directory(p.join(root, dir));
    if (!d.existsSync()) continue;
    final bool hasLocaleFile = d.listSync().whereType<File>().any(
        (final File f) =>
            f.path.endsWith('.json') && ngxLocaleOf(f.path) != null);
    if (hasLocaleFile) return dir;
  }
  return null;
}

/// Whether the app at [root] depends on ngx-translate or Transloco.
bool usesNgxTranslate(final String root) {
  final File pkg = File(p.join(root, 'package.json'));
  if (!pkg.existsSync()) return false;
  try {
    final Object? doc = jsonDecode(pkg.readAsStringSync());
    if (doc is! Map<String, dynamic>) return false;
    for (final String section in <String>[
      'dependencies',
      'devDependencies',
    ]) {
      final Object? deps = doc[section];
      if (deps is Map &&
          (deps.containsKey('@ngx-translate/core') ||
              deps.containsKey('@jsverse/transloco') ||
              deps.containsKey('@ngneat/transloco'))) {
        return true;
      }
    }
  } on FormatException {
    return false;
  }
  return false;
}

/// Keys of the base language's file at [file] the service does not have,
/// sorted. Empty when there is no such file.
List<String> localOnlyNgxKeys(final File file, final Set<String> serviceKeys) {
  if (!file.existsSync()) return const <String>[];
  final Object? doc;
  try {
    doc = jsonDecode(file.readAsStringSync());
  } on FormatException {
    return const <String>[];
  }
  if (!isNgxDoc(doc)) return const <String>[];
  return <String>[
    for (final String key in flattenNgx(doc! as Map<String, dynamic>).keys)
      if (!serviceKeys.contains(key)) key,
  ]..sort();
}

/// An Angular app localized with `@angular/localize`: one that loads its
/// strings with ngx-translate has no `extract-i18n` setup to check.
bool looksLikeLocalizeApp(final String root) =>
    File(p.join(root, 'angular.json')).existsSync() && !usesNgxTranslate(root);
