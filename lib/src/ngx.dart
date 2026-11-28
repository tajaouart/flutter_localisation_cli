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

/// A translation JSON: no `@@locale` and no `@key` metadata. A value that is
/// not a string (an array, a number) does not make it something else; the
/// service lists it and it stays in the file.
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
      if (v is Map<String, dynamic> && !plain(v)) return false;
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

final RegExp _ngxPlaceholder = RegExp(r'\{\{\s*([^{}]*?)\s*\}\}');
final RegExp _plainName = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
final RegExp _wholeIcu = RegExp(
    r'^\{\s*[A-Za-z_][A-Za-z0-9_]*\s*,\s*(plural|select|selectordinal)\s*,');

/// Whether the service refuses [value] on import, so it can only live in the
/// file: not a string, a placeholder that is a path or an expression
/// (`{{ user.name }}`), or a literal brace. Same rules as the service's.
bool ngxRefuses(final Object? value) {
  if (value is! String) return true;
  if (_wholeIcu.hasMatch(value.trim())) return false;
  int names = 0;
  bool plain = true;
  final String converted =
      value.replaceAllMapped(_ngxPlaceholder, (final Match m) {
    names++;
    if (!_plainName.hasMatch(m[1]!)) plain = false;
    return '{x}';
  });
  return !plain ||
      '{'.allMatches(converted).length != names ||
      '}'.allMatches(converted).length != names;
}

/// {dotted key: path}: where each value sits in [doc], in file order. A file
/// may hold `"a.b": ".."` beside `{"c": {"d": ".."}}`; both keep their place.
Map<String, List<String>> ngxLayout(final Map<String, dynamic> doc) {
  final Map<String, List<String>> paths = <String, List<String>>{};
  void walk(final Map<String, dynamic> node, final List<String> prefix) {
    for (final MapEntry<String, dynamic> e in node.entries) {
      final List<String> at = <String>[...prefix, e.key];
      final Object? v = e.value;
      if (v is Map<String, dynamic>) {
        walk(v, at);
      } else {
        paths[at.join('.')] = at;
      }
    }
  }

  walk(doc, const <String>[]);
  return paths;
}

Object? _valueAt(final Map<String, dynamic> doc, final List<String> at) {
  Object? node = doc;
  for (final String part in at) {
    node = (node! as Map<String, dynamic>)[part];
  }
  return node;
}

bool _place(final Map<String, dynamic> root, final List<String> at,
    final Object? value) {
  if (at.any((final String part) => part.isEmpty)) return false;
  final List<String> parents = at.sublist(0, at.length - 1);
  Map<String, dynamic> node = root;
  for (final String part in parents) {
    if (!node.containsKey(part)) {
      node = <String, dynamic>{};
      continue;
    }
    final Object? child = node[part];
    if (child is! Map<String, dynamic>) return false;
    node = child;
  }
  if (node.containsKey(at.last)) return false;
  node = root;
  for (final String part in parents) {
    node = node.putIfAbsent(part, () => <String, dynamic>{})
        as Map<String, dynamic>;
  }
  node[at.last] = value;
  return true;
}

/// The document for dotted keys: each key where [paths] has it, a key
/// [paths] does not know nested when [nested], flat otherwise. A key that
/// cannot be nested (it is also the parent of another key) stays flat.
Map<String, dynamic> assembleNgx(
  final Map<String, dynamic> flat, {
  final Map<String, List<String>> paths = const <String, List<String>>{},
  final bool nested = false,
}) {
  final Map<String, dynamic> root = <String, dynamic>{};
  for (final MapEntry<String, dynamic> e in flat.entries) {
    final List<String> at =
        paths[e.key] ?? (nested ? e.key.split('.') : <String>[e.key]);
    if (_place(root, at, e.value)) continue;
    final Object? held = root[e.key];
    root[e.key] = e.value;
    if (held is Map<String, dynamic>) {
      // The key was the parent of strings placed before it.
      for (final MapEntry<String, List<String>> sub
          in ngxLayout(held).entries) {
        root['${e.key}.${sub.key}'] = _valueAt(held, sub.value);
      }
    }
  }
  return root;
}

Map<String, dynamic>? _readDoc(final File? file) {
  if (file == null || !file.existsSync()) return null;
  try {
    final Object? doc = jsonDecode(file.readAsStringSync());
    return doc is Map<String, dynamic> ? doc : null;
  } on FormatException {
    return null;
  }
}

/// What to write to [existing] for [body], the flat translation JSON the
/// service sent for that language.
///
/// The file keeps its shape and its line order, and a language with no file
/// yet takes those of [shapeOf], the source language's file. What the file
/// holds and the service cannot (`$schema`, an array, a `{{ user.name }}`
/// string it refuses) is written back as it was: left out, the app would show
/// the key. With [keepLocalOnly] every string only the file has is kept: an
/// import just ran, so what is still missing is what the service refused.
String composeNgx(
  final String body,
  final File existing, {
  final File? shapeOf,
  final bool keepLocalOnly = false,
}) {
  final Object? served = jsonDecode(body);
  if (served is! Map<String, dynamic>) return body;
  final Map<String, dynamic>? old = _readDoc(existing);
  final Map<String, dynamic>? shape = old ?? _readDoc(shapeOf);
  final Map<String, List<String>> paths =
      shape == null ? <String, List<String>>{} : ngxLayout(shape);
  final Map<String, dynamic> flat = <String, dynamic>{};
  for (final MapEntry<String, List<String>> e in paths.entries) {
    if (served.containsKey(e.key)) {
      flat[e.key] = served[e.key];
    } else if (old != null) {
      final Object? was = _valueAt(old, e.value);
      if (e.key.startsWith(r'$') || keepLocalOnly || ngxRefuses(was)) {
        flat[e.key] = was;
      }
    }
  }
  for (final MapEntry<String, dynamic> e in served.entries) {
    flat.putIfAbsent(e.key, () => e.value);
  }
  final Map<String, dynamic> doc = assembleNgx(flat,
      paths: paths,
      nested: paths.values.any((final List<String> at) => at.length > 1));
  return '${const JsonEncoder.withIndent('  ').convert(doc)}\n';
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

/// Keys of the base language's file at [file] the service does not have and
/// would take, sorted: what it refuses on import (see [ngxRefuses]) stays in
/// the file whatever the pull writes. Empty when there is no such file.
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
    for (final MapEntry<String, String> e
        in flattenNgx(doc! as Map<String, dynamic>).entries)
      if (!serviceKeys.contains(e.key) && !ngxRefuses(e.value)) e.key,
  ]..sort();
}

/// An Angular app localized with `@angular/localize`: one that loads its
/// strings with ngx-translate has no `extract-i18n` setup to check.
bool looksLikeLocalizeApp(final String root) =>
    File(p.join(root, 'angular.json')).existsSync() && !usesNgxTranslate(root);
