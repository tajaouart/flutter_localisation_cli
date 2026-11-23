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
    return compareMessages(
      arbMessages(parsed),
      <String, String>{
        for (final TranslationEntry t in lang.translations) t.key: t.value,
      },
      language: code,
      isBase: code == base,
      format: 'arb',
    );
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
