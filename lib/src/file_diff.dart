/// A local translation file against what the service holds for the same
/// language: what an import would add, change or leave, and what the service
/// has that the file no longer does.
library;

import 'dart:convert';

import 'package:flutter_localisation_cli/src/angular.dart';
import 'package:flutter_localisation_cli/src/exceptions.dart';
import 'package:flutter_localisation_cli/src/locales.dart';
import 'package:flutter_localisation_cli/src/management_client.dart';
import 'package:flutter_localisation_cli/src/ngx.dart';
import 'package:flutter_localisation_cli/src/operations.dart';
import 'package:flutter_localisation_cli/src/platform.dart';
import 'package:flutter_localisation_cli/src/xcstrings.dart';

/// The outcome of comparing one file with one language of the service.
class FileDiff {
  FileDiff({
    required this.language,
    required this.isBase,
    required this.format,
    required this.added,
    required this.changed,
    required this.same,
    required this.gone,
    this.standIns = const <String>[],
  });

  final String language;
  final bool isBase;

  /// `angular`, `ngx` or `arb`.
  final String format;

  /// In the file, not on the service.
  final List<String> added;

  /// In both, with a different text: key -> (file, service).
  final Map<String, ({String local, String remote})> changed;

  /// In both, with the same text.
  final int same;

  /// On the service, not in the file.
  final List<String> gone;

  /// Keys of [changed] whose service row is an unchecked copy of the source
  /// text: the import replaces it without --overwrite.
  final List<String> standIns;

  bool get isEmpty => added.isEmpty && changed.isEmpty && gone.isEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'language': language,
        'base': isBase,
        'format': format,
        'added': added,
        'changed': <String, dynamic>{
          for (final MapEntry<String, ({String local, String remote})> e
              in changed.entries)
            e.key: <String, String>{
              'file': e.value.local,
              'service': e.value.remote
            },
        },
        'same': same,
        'gone': gone,
        'stand_ins': standIns,
      };
}

/// [local] against [remote], keeping the file's order for what it lists.
FileDiff compareMessages(
  final Map<String, String> local,
  final Map<String, String> remote, {
  required final String language,
  required final bool isBase,
  required final String format,
}) {
  final List<String> added = <String>[];
  final Map<String, ({String local, String remote})> changed =
      <String, ({String local, String remote})>{};
  int same = 0;
  for (final MapEntry<String, String> e in local.entries) {
    final String? there = remote[e.key];
    if (there == null) {
      added.add(e.key);
    } else if (there == e.value) {
      same++;
    } else {
      changed[e.key] = (local: e.value, remote: there);
    }
  }
  return FileDiff(
    language: language,
    isBase: isBase,
    format: format,
    added: added,
    changed: changed,
    same: same,
    gone: <String>[
      for (final String k in remote.keys)
        if (!local.containsKey(k)) k,
    ],
  );
}

/// The messages of an ARB-shaped document: every non-`@` string value.
Map<String, String> arbMessages(final Map<String, dynamic> doc) =>
    <String, String>{
      for (final MapEntry<String, dynamic> e in doc.entries)
        if (!e.key.startsWith('@') && e.value is String)
          e.key: e.value as String,
    };

extension FileCompare on Operations {
  /// Compare a translation file with the language of the service it stands for.
  ///
  /// The language is [languageCode] when given, else what the file says:
  /// Angular's extraction is the source, a translated Angular or Flutter file
  /// names its `@@locale`, an ngx-translate file its file name.
  Future<FileDiff> compareFile(
    final String content, {
    final String? fileName,
    final String? languageCode,
  }) async {
    final Object? parsed;
    try {
      parsed = jsonDecode(content);
    } catch (_) {
      throw ManagementException('Not valid JSON: ${fileName ?? 'the file'}.');
    }
    if (parsed is! Map<String, dynamic>) {
      throw ManagementException(
          '${fileName ?? 'The file'} is not a JSON object.');
    }
    if (isCatalogJson(parsed) ||
        (fileName != null && fileName.endsWith('.xcstrings'))) {
      throw ManagementException(
          'A String Catalog carries every locale; compare it with `fl pull`, '
          'which names the keys only the catalog on disk has.');
    }
    final ProjectData project = await client.getProject(projectId);
    final FlavorData fl = project.flavor(flavor);
    final String base = project.baseLanguage(flavor)?.code ?? 'en';

    String match(final String code) {
      final String wanted = canonicalizeOrKeep(code);
      for (final LanguageData l in fl.languages) {
        if (canonicalizeOrKeep(l.code) == wanted) return l.code;
      }
      throw ManagementException(
          '${fileName ?? 'The file'} is "$code", and flavor "${fl.name}" has '
          'no such language (${fl.languages.map((final LanguageData l) => l.code).join(', ')}).');
    }

    final bool angularFile = isAngularArbJson(parsed) ||
        fileName == kAngularSource ||
        (project.shipsAngular &&
            !project.shipsFlutter &&
            fileName != null &&
            RegExp(r'^messages(\.[A-Za-z0-9_-]+)?\.arb$').hasMatch(fileName));
    final bool ngxFile = !angularFile &&
        isNgxDoc(parsed) &&
        (fileName == null || fileName.endsWith('.json'));

    if (angularFile) {
      final bool source = fileName == kAngularSource ||
          parsed.entries.any((final MapEntry<String, dynamic> e) =>
              e.key.startsWith('@') &&
              e.value is Map &&
              (e.value as Map).containsKey('x-locations'));
      final String code = languageCode != null
          ? match(languageCode)
          : source
              ? base
              : match((parsed['@@locale'] as String?) ?? base);
      final Map<String, dynamic> served =
          jsonDecode(await client.downloadAngular(projectId, fl.id, code))
              as Map<String, dynamic>;
      return compareMessages(arbMessages(parsed), arbMessages(served),
          language: code, isBase: code == base, format: 'angular');
    }

    if (ngxFile) {
      final List<String> candidates =
          fileName == null ? <String>[] : ngxLocaleCandidates(fileName);
      String code = base;
      if (languageCode != null) {
        code = match(languageCode);
      } else {
        for (final String c in candidates) {
          try {
            code = match(c);
            break;
          } on ManagementException {
            continue;
          }
        }
      }
      final Map<String, dynamic> served =
          jsonDecode(await client.downloadNgx(projectId, fl.id, code))
              as Map<String, dynamic>;
      return compareMessages(flattenNgx(parsed), flattenNgx(served),
          language: code, isBase: code == base, format: 'ngx');
    }

    final ({String code, String source})? inferred =
        inferArbLocale(parsed, fileName);
    final String code = languageCode != null
        ? match(languageCode)
        : inferred == null
            ? base
            : match(inferred.code);
    final LanguageData lang =
        fl.languages.firstWhere((final LanguageData l) => l.code == code);
    // What a Flutter app gets: its own text, and only the keys it ships.
    final Set<String> notFlutter = <String>{
      for (final LanguageData l in fl.languages)
        for (final TranslationEntry t in l.translations)
          if (!t.shipsTo(AppPlatform.flutter)) t.key,
    };
    final FileDiff d = compareMessages(
      arbMessages(parsed),
      <String, String>{
        for (final TranslationEntry t in lang.translations)
          if (!notFlutter.contains(t.key))
            t.key: t.textFor(AppPlatform.flutter.wire),
      },
      language: code,
      isBase: code == base,
      format: 'arb',
    );
    if (d.isBase || d.changed.isEmpty) return d;
    final Map<String, String> source = <String, String>{
      for (final TranslationEntry t
          in project.baseLanguage(flavor)?.translations ?? <TranslationEntry>[])
        t.key: t.value,
    };
    final Map<String, TranslationEntry> rows = <String, TranslationEntry>{
      for (final TranslationEntry t in lang.translations) t.key: t,
    };
    // The service's rule (process_arb_data): the row is not checked and holds
    // the source text, so the import replaces it.
    return FileDiff(
      language: d.language,
      isBase: d.isBase,
      format: d.format,
      added: d.added,
      changed: d.changed,
      same: d.same,
      gone: d.gone,
      standIns: <String>[
        for (final MapEntry<String, ({String local, String remote})> e
            in d.changed.entries)
          if (rows[e.key]?.isChecked == false &&
              e.value.remote.trim().isNotEmpty &&
              e.value.remote.trim() == source[e.key]?.trim())
            e.key,
      ],
    );
  }
}

/// String Catalogs against the service's `Localizable` catalog, file by
/// file: the keys each declares that the service lacks, those whose text
/// differs in a language both have, and the service keys no file declares.
///
/// [files] are compared; [all] (default [files]) are the catalogs searched
/// for a key declared twice with two texts, which refuses the comparison:
/// there is no one local text to set against the service's.
extension CatalogCompare on Operations {
  Future<OpResult> compareCatalogs(
    final List<CatalogTarget> files, {
    final List<CatalogTarget>? all,
    final String Function(String path)? shown,
  }) async {
    String show(final String path) => shown == null ? path : shown(path);
    final List<String> missing = <String>[
      for (final CatalogTarget t in files)
        if (!t.localizable.existsSync()) show(t.localizable.path),
    ];
    if (missing.isNotEmpty) {
      return OpResult(false, 'No catalog at ${missing.join(', ')}.',
          <String, dynamic>{'missing': missing});
    }
    final Set<String> declared = <String>{
      for (final CatalogTarget t in files)
        ...catalogKeys(jsonDecode(t.localizable.readAsStringSync())),
    };
    final List<CatalogConflict> conflicts =
        catalogConflicts(all ?? files, only: declared);
    if (conflicts.isNotEmpty) {
      return OpResult(
        false,
        describeCatalogConflicts(conflicts, shown: show),
        <String, dynamic>{
          'error': 'catalog_conflicts',
          'conflicts': <Map<String, dynamic>>[
            for (final CatalogConflict c in conflicts) c.toJson(),
          ],
        },
      );
    }
    final ProjectData project = await client.getProject(projectId);
    final FlavorData fl = project.flavor(flavor);
    final Map<String, dynamic> served =
        (jsonDecode(await client.downloadCatalog(projectId, fl.id))
            as Map<String, dynamic>)['strings'] as Map<String, dynamic>;
    final List<Map<String, dynamic>> rows = <Map<String, dynamic>>[];
    final Set<String> seen = <String>{};
    for (final CatalogTarget t in files) {
      final Map<String, dynamic> local =
          (jsonDecode(t.localizable.readAsStringSync())
              as Map<String, dynamic>)['strings'] as Map<String, dynamic>;
      final List<String> added = <String>[];
      final Map<String, List<String>> changed = <String, List<String>>{};
      int same = 0;
      local.forEach((final String key, final dynamic v) {
        if (key.isEmpty) return;
        seen.add(key);
        if (!served.containsKey(key)) {
          added.add(key);
          return;
        }
        final List<String> diff = catalogTextDifferences(v, served[key]);
        if (diff.isEmpty) {
          same++;
        } else {
          changed[key] = diff;
        }
      });
      rows.add(<String, dynamic>{
        'file': show(t.localizable.path),
        'keys': local.keys.where((final String k) => k.isNotEmpty).length,
        'added': added,
        'changed': changed,
        'same': same,
      });
    }
    final List<String> gone = <String>[
      for (final String key in served.keys)
        if (!seen.contains(key)) key,
    ]..sort();
    String list(final Iterable<String> keys) =>
        '${keys.take(10).join(', ')}${keys.length > 10 ? ', …' : ''}';
    final List<String> lines = <String>[
      for (final Map<String, dynamic> r in rows) ...<String>[
        '${r['file']}: ${r['keys']} key(s)',
        '  ${(r['added'] as List<String>).length} new, not on the service yet'
            '${(r['added'] as List<String>).isEmpty ? '' : ': ${list(r['added'] as List<String>)}'}',
        '  ${(r['changed'] as Map<String, List<String>>).length} different'
            '${(r['changed'] as Map<String, List<String>>).isEmpty ? '' : ': ${list((r['changed'] as Map<String, List<String>>).entries.map((final MapEntry<String, List<String>> e) => '${e.key} (${e.value.join(', ')})'))}'}',
        '  ${r['same']} the same.',
      ],
      '${gone.length} on the service are in none of these catalogs'
          '${gone.isEmpty ? '.' : ': ${list(gone)}'}',
    ];
    return OpResult(true, lines.join('\n'), <String, dynamic>{
      'format': 'xcstrings',
      'files': rows,
      'gone': gone,
    });
  }
}

/// [d] in a few lines: counts, and the keys of each list up to [limit].
String describeDiff(final FileDiff d, final String fileName,
    {final int limit = 20}) {
  String keys(final List<String> list) {
    final List<String> shown = list.take(limit).toList();
    return shown.join(', ') +
        (list.length > limit
            ? ' … and ${list.length - limit} more (--json lists all)'
            : '');
  }

  final List<String> lines = <String>[
    '$fileName against "${d.language}"${d.isBase ? ' (the source)' : ''} on the service:',
    '  ${d.added.length} new, not on the service yet${d.added.isEmpty ? '' : ': ${keys(d.added)}'}',
    '  ${d.changed.length} different${d.changed.isEmpty ? '' : ':'}',
    for (final MapEntry<String, ({String local, String remote})> e
        in d.changed.entries.take(limit))
      '    ${e.key}\n      file:    ${jsonEncode(e.value.local)}\n      service: ${jsonEncode(e.value.remote)}',
    if (d.changed.length > limit)
      '    … and ${d.changed.length - limit} more (--json lists all)',
    '  ${d.gone.length} only on the service${d.gone.isEmpty ? '' : ': ${keys(d.gone)}'}',
    '  ${d.same} the same.',
  ];
  return lines.join('\n');
}
