/// Angular apps localized the official way: `@angular/localize`, an `@@id`
/// on every message, `ng extract-i18n --format=arb` writing the source
/// `messages.arb`, and one `messages.<locale>.arb` per locale listed under
/// `i18n.locales` in `angular.json`.
///
/// The service converts between Angular's placeholders and its own; the CLI
/// only moves files, keeps `angular.json` in step, and says before an upload
/// what the service would leave out.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

const String kAngularSource = 'messages.arb';
const String kAngularDefaultDir = 'src/locale';

String angularTargetName(final String code) => 'messages.$code.arb';

final RegExp _hashId = RegExp(r'^\d+$');

/// An ARB that Angular wrote: only its extraction writes `x-locations`, and
/// only Angular writes `{$NAME}` placeholders.
bool isAngularArbJson(final Object? parsed) {
  if (parsed is! Map<String, dynamic> || parsed['@@locale'] is! String) {
    return false;
  }
  for (final MapEntry<String, dynamic> e in parsed.entries) {
    if (e.key.startsWith('@') &&
        e.value is Map &&
        (e.value as Map).containsKey('x-locations')) {
      return true;
    }
    if (!e.key.startsWith('@') &&
        e.value is String &&
        (e.value as String).contains(r'{$')) {
      return true;
    }
  }
  return false;
}

/// Messages of an extraction the service will not import, each with the fix.
List<String> angularImportProblems(final Map<String, dynamic> doc) {
  final List<String> problems = <String>[];
  final bool hasSentenceIcu = doc.entries.any(
      (final MapEntry<String, dynamic> e) =>
          !e.key.startsWith('@') &&
          e.value is String &&
          (e.value as String).contains(r'{$ICU'));
  for (final MapEntry<String, dynamic> e in doc.entries) {
    if (e.key.startsWith('@') || e.value is! String) continue;
    final String text = e.value as String;
    if (text.contains(r'{$ICU')) {
      problems.add('${e.key}: a plural or select inside a sentence; make it '
          'the whole message, with the sentence inside each case');
    } else if (_hashId.hasMatch(e.key)) {
      // The hash sub-message of a sentence above is the same problem.
      if (hasSentenceIcu && text.trimLeft().startsWith('{')) continue;
      problems.add('${e.key}: no @@id; give it one with i18n="@@your.id" '
          r'or $localize`:@@your.id:...`');
    }
  }
  return problems;
}

/// The `angular.json` of the app at [root], or null.
File? angularJsonOf(final String root) {
  final File f = File(p.join(root, 'angular.json'));
  return f.existsSync() ? f : null;
}

bool looksLikeAngularApp(final String root) => angularJsonOf(root) != null;

/// The application project of an `angular.json`: the only one, or the one at
/// the workspace root.
({String name, Map<String, dynamic> project})? _appProject(
    final Map<String, dynamic> workspace) {
  final Map<String, dynamic> projects =
      (workspace['projects'] as Map<String, dynamic>?) ?? <String, dynamic>{};
  final List<MapEntry<String, dynamic>> apps = <MapEntry<String, dynamic>>[
    for (final MapEntry<String, dynamic> e in projects.entries)
      if (e.value is Map<String, dynamic> &&
          (e.value as Map<String, dynamic>)['projectType'] != 'library')
        e,
  ];
  if (apps.isEmpty) return null;
  final MapEntry<String, dynamic> app = apps.length == 1
      ? apps.single
      : apps.firstWhere(
          (final MapEntry<String, dynamic> e) =>
              ((e.value as Map<String, dynamic>)['root'] ?? '') == '',
          orElse: () => apps.first);
  return (name: app.key, project: app.value as Map<String, dynamic>);
}

/// Where `ng extract-i18n` writes in this app (`outputPath`), or null.
String? angularExtractDir(final String root) {
  final File? f = angularJsonOf(root);
  if (f == null) return null;
  try {
    final project =
        _appProject(jsonDecode(f.readAsStringSync()) as Map<String, dynamic>);
    final Object? out = (((project?.project['architect']
                as Map<String, dynamic>?)?['extract-i18n']
            as Map<String, dynamic>?)?['options']
        as Map<String, dynamic>?)?['outputPath'];
    return out is String && out.isNotEmpty ? out : null;
  } on FormatException {
    return null;
  }
}

/// Lists [codes] under `i18n.locales` of the app in `angular.json`, each
/// pointing at its `messages.<code>.arb` in [dir] (relative to [root]).
/// Locales already listed keep what they say. Returns the codes added, or
/// null when there is no `angular.json` to update.
List<String>? syncAngularLocales(
  final String root,
  final String dir,
  final List<String> codes, {
  final String? sourceLocale,
  final bool dryRun = false,
}) {
  final File? f = angularJsonOf(root);
  if (f == null) return null;
  final Map<String, dynamic> workspace =
      jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  final app = _appProject(workspace);
  if (app == null) return null;
  final Map<String, dynamic> i18n =
      (app.project['i18n'] as Map<String, dynamic>?) ?? <String, dynamic>{};
  final Map<String, dynamic> locales =
      (i18n['locales'] as Map<String, dynamic>?) ?? <String, dynamic>{};
  final List<String> added = <String>[];
  for (final String code in codes) {
    if (locales.containsKey(code)) continue;
    locales[code] = <String, dynamic>{
      'translation': p.posix.join(dir, angularTargetName(code)),
    };
    added.add(code);
  }
  final bool setSource = sourceLocale != null && i18n['sourceLocale'] == null;
  if (added.isEmpty && !setSource) return added;
  if (setSource) i18n['sourceLocale'] = sourceLocale;
  i18n['locales'] = locales;
  app.project['i18n'] = i18n;
  if (!dryRun) {
    f.writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(workspace)}\n');
  }
  return added;
}

/// What stands between an Angular app at [root] and translated builds, with
/// [dir] the folder of its `messages*.arb` files. Empty when all is in place.
List<String> angularSetupIssues(final String root, final String dir) {
  final File? f = angularJsonOf(root);
  if (f == null) return const <String>[];
  final List<String> issues = <String>[];
  final Map<String, dynamic> workspace;
  try {
    workspace = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  } on FormatException {
    return <String>['angular.json: not valid JSON'];
  }
  final app = _appProject(workspace);
  if (app == null) return <String>['angular.json: no application project'];
  final Map<String, dynamic> architect =
      (app.project['architect'] as Map<String, dynamic>?) ??
          <String, dynamic>{};
  final Object? polyfills =
      ((architect['build'] as Map<String, dynamic>?)?['options']
          as Map<String, dynamic>?)?['polyfills'];
  final bool localize = polyfills is List
      ? polyfills.contains('@angular/localize/init')
      : polyfills == '@angular/localize/init';
  if (!localize) {
    issues.add('angular.json: @angular/localize is not set up; run '
        '`ng add @angular/localize`');
  }
  final Object? format =
      ((architect['extract-i18n'] as Map<String, dynamic>?)?['options']
          as Map<String, dynamic>?)?['format'];
  if (format != 'arb') {
    issues.add('angular.json: extract-i18n does not write ARB; set "format": '
        '"arb" and "outputPath": "$dir" in its options');
  }
  final File source = File(p.join(root, dir, kAngularSource));
  if (!source.existsSync()) {
    issues.add('$dir/$kAngularSource: missing; run `ng extract-i18n`');
  } else {
    final Object? doc = jsonDecode(source.readAsStringSync());
    if (doc is Map<String, dynamic>) {
      issues.addAll(angularImportProblems(doc)
          .map((final String problem) => '$dir/$kAngularSource: $problem'));
    }
  }
  final Map<String, dynamic> listed = ((app.project['i18n']
          as Map<String, dynamic>?)?['locales'] as Map<String, dynamic>?) ??
      <String, dynamic>{};
  final Directory folder = Directory(p.join(root, dir));
  if (folder.existsSync()) {
    for (final FileSystemEntity e in folder.listSync()) {
      final RegExpMatch? m = RegExp(r'^messages\.([A-Za-z0-9_-]+)\.arb$')
          .firstMatch(p.basename(e.path));
      if (m != null && !listed.containsKey(m.group(1))) {
        issues.add('angular.json: ${m.group(1)} has a file '
            '(${p.basename(e.path)}) but is not under i18n.locales, so no '
            'build uses it; `fl pull` lists it');
      }
    }
  }
  for (final MapEntry<String, dynamic> e in listed.entries) {
    final Object? file =
        e.value is Map ? (e.value as Map)['translation'] : e.value;
    if (file is String && !File(p.join(root, file)).existsSync()) {
      issues.add('angular.json: i18n.locales.${e.key} points at $file, which '
          'does not exist; run `fl pull`');
    }
  }
  return issues;
}
