/// The project glossary, language styles and never-translate keys.
///
/// What the backend tells its translator about a project beyond the strings:
/// terms kept as written (a brand name) or pinned to one translation per
/// locale, formal or informal address per language, and keys that are never
/// sent for translation at all. Shared by `fl` and the MCP server, like
/// [Operations].
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_localisation_cli/src/exceptions.dart';
import 'package:flutter_localisation_cli/src/locales.dart';
import 'package:flutter_localisation_cli/src/management_client.dart';
import 'package:flutter_localisation_cli/src/operations.dart';

/// `de=Schnipsel` pairs from `--as`, keyed by canonical locale.
Map<String, String> parseTermTranslations(final List<String> raw) {
  final Map<String, String> out = <String, String>{};
  for (final String pair in raw) {
    final int eq = pair.indexOf('=');
    if (eq <= 0 || eq == pair.length - 1) {
      throw ManagementException(
        'Expected <locale>=<translation>, e.g. `--as de=Schnipsel`; got "$pair".',
      );
    }
    out[canonicalizeOrKeep(pair.substring(0, eq).trim())] =
        pair.substring(eq + 1).trim();
  }
  return out;
}

/// The terms of a glossary file: a JSON list, `{"terms": [...]}`, or a CSV
/// whose header names `term` and any of `keep`, `case_sensitive`, `note` and
/// locale codes (`term,keep,de,fr`).
List<Map<String, dynamic>> readGlossaryFile(final String path) {
  final File file = File(path);
  if (!file.existsSync()) throw ManagementException('No such file: $path');
  final String text = file.readAsStringSync();
  if (path.toLowerCase().endsWith('.csv')) return _parseCsv(text);
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException catch (e) {
    throw ManagementException('$path is not valid JSON: ${e.message}');
  }
  final Object? list =
      decoded is Map<String, dynamic> ? decoded['terms'] : decoded;
  if (list is! List) {
    throw ManagementException(
      '$path must hold a list of terms or {"terms": [...]}.',
    );
  }
  return <Map<String, dynamic>>[
    for (final Object? row in list)
      if (row is Map<String, dynamic>)
        _termPayload(row)
      else
        throw ManagementException('Every term in $path must be an object.'),
  ];
}

Map<String, dynamic> _termPayload(final Map<String, dynamic> row) =>
    <String, dynamic>{
      'term': row['term'],
      if (row.containsKey('do_not_translate') || row.containsKey('keep'))
        'do_not_translate': row['do_not_translate'] ?? row['keep'],
      if (row.containsKey('case_sensitive'))
        'case_sensitive': row['case_sensitive'],
      if (row['translations'] is Map) 'translations': row['translations'],
      if (row.containsKey('note')) 'note': row['note'],
    };

List<Map<String, dynamic>> _parseCsv(final String text) {
  final List<List<String>> rows = _csvRows(text);
  if (rows.isEmpty) return const <Map<String, dynamic>>[];
  final List<String> header =
      rows.first.map((final String h) => h.trim()).toList();
  final int termAt = header.indexOf('term');
  if (termAt < 0) {
    throw ManagementException('The CSV header must have a "term" column.');
  }
  const Set<String> flags = <String>{'keep', 'do_not_translate', 'case_sensitive', 'note'};
  final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
  for (final List<String> row in rows.skip(1)) {
    if (row.every((final String c) => c.trim().isEmpty)) continue;
    String cell(final int i) => i < row.length ? row[i].trim() : '';
    bool truthy(final String v) =>
        <String>{'1', 'true', 'yes', 'y', 'x'}.contains(v.toLowerCase());
    final Map<String, String> translations = <String, String>{};
    final Map<String, dynamic> term = <String, dynamic>{'term': cell(termAt)};
    for (int i = 0; i < header.length; i++) {
      final String name = header[i];
      if (i == termAt || name.isEmpty) continue;
      final String value = cell(i);
      if (name == 'keep' || name == 'do_not_translate') {
        if (value.isNotEmpty) term['do_not_translate'] = truthy(value);
      } else if (name == 'case_sensitive') {
        if (value.isNotEmpty) term['case_sensitive'] = truthy(value);
      } else if (name == 'note') {
        if (value.isNotEmpty) term['note'] = value;
      } else if (!flags.contains(name) && value.isNotEmpty) {
        translations[canonicalizeOrKeep(name)] = value;
      }
    }
    if (translations.isNotEmpty) term['translations'] = translations;
    out.add(term);
  }
  return out;
}

/// RFC 4180-ish: quoted cells may hold commas, quotes ("") and newlines.
List<List<String>> _csvRows(final String text) {
  final List<List<String>> rows = <List<String>>[];
  List<String> row = <String>[];
  final StringBuffer cell = StringBuffer();
  bool quoted = false;
  for (int i = 0; i < text.length; i++) {
    final String c = text[i];
    if (quoted) {
      if (c == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          cell.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        cell.write(c);
      }
    } else if (c == '"') {
      quoted = true;
    } else if (c == ',') {
      row.add(cell.toString());
      cell.clear();
    } else if (c == '\n' || c == '\r') {
      if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      row.add(cell.toString());
      cell.clear();
      rows.add(row);
      row = <String>[];
    } else {
      cell.write(c);
    }
  }
  if (cell.isNotEmpty || row.isNotEmpty) {
    row.add(cell.toString());
    rows.add(row);
  }
  return rows;
}

/// How the backend matches a term: whole words where the term starts or ends
/// with a letter or digit, so "Pro" is not found in "Professional".
RegExp termPattern(final String term, {final bool caseSensitive = false}) {
  bool word(final String c) => RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(c);
  final String start = term.isNotEmpty && word(term[0]) ? r'(?<![\p{L}\p{N}_])' : '';
  final String end =
      term.isNotEmpty && word(term[term.length - 1]) ? r'(?![\p{L}\p{N}_])' : '';
  return RegExp('$start${RegExp.escape(term)}$end',
      unicode: true, caseSensitive: caseSensitive);
}

class GlossaryOperations {
  GlossaryOperations(this.client, this.projectId);

  final ManagementClient client;
  final int projectId;

  static const String _retranslateHint =
      'Strings already translated keep their text until `fl glossary apply` '
      're-translates them.';

  Future<List<Map<String, dynamic>>> _terms() async =>
      ((await client.listGlossary(projectId))['terms'] as List<dynamic>? ??
              const <dynamic>[])
          .cast<Map<String, dynamic>>();

  Future<OpResult> list() async {
    final List<Map<String, dynamic>> terms = await _terms();
    return OpResult(
      true,
      terms.isEmpty
          ? 'The glossary is empty. `fl glossary suggest` lists terms worth adding.'
          : '${terms.length} glossary term(s).',
      <String, dynamic>{'terms': terms},
    );
  }

  /// Add a term, or update it when it exists (matched case-insensitively).
  Future<OpResult> add(
    final String term, {
    final bool keep = false,
    final Map<String, String> translations = const <String, String>{},
    final String? note,
    final bool? caseSensitive,
    final bool dryRun = false,
  }) async {
    if (term.trim().isEmpty) throw ManagementException('The term is empty.');
    if (keep && translations.isNotEmpty) {
      throw ManagementException(
        'A term kept as written cannot also have translations: pass --keep '
        'or --as, not both.',
      );
    }
    final Map<String, dynamic> payload = <String, dynamic>{
      'term': term.trim(),
      'do_not_translate': keep,
      if (translations.isNotEmpty) 'translations': translations,
      if (note != null) 'note': note,
      if (caseSensitive != null) 'case_sensitive': caseSensitive,
    };
    if (dryRun) {
      return OpResult(true, 'Would save "${term.trim()}".', <String, dynamic>{'term': payload});
    }
    final Map<String, dynamic> r =
        await client.upsertGlossary(projectId, <Map<String, dynamic>>[payload]);
    final List<dynamic> created = r['created'] as List<dynamic>? ?? const <dynamic>[];
    final Map<String, dynamic> saved = (created.isNotEmpty
        ? created.first
        : (r['updated'] as List<dynamic>).first) as Map<String, dynamic>;
    final int count = (saved['string_count'] as int?) ?? 0;
    return OpResult(
      true,
      '${created.isNotEmpty ? 'Added' : 'Updated'} "${saved['term']}" '
      '(${_describe(saved)}); it occurs in $count string(s).'
      '${count > 0 ? ' $_retranslateHint' : ''}',
      <String, dynamic>{'term': saved},
    );
  }

  Future<OpResult> remove(final String term, {final bool dryRun = false}) async {
    final Map<String, dynamic>? found = await _find(term);
    if (found == null) {
      return OpResult(false, '"$term" is not in the glossary.');
    }
    if (dryRun) return OpResult(true, 'Would remove "${found['term']}".');
    await client.deleteGlossaryTerm(projectId, found['id'] as int);
    return OpResult(true, 'Removed "${found['term']}".');
  }

  Future<OpResult> importFile(final String path, {final bool dryRun = false}) async {
    final List<Map<String, dynamic>> terms = readGlossaryFile(path);
    if (terms.isEmpty) return OpResult(false, '$path holds no terms.');
    if (dryRun) {
      return OpResult(true, 'Would save ${terms.length} term(s) from $path.',
          <String, dynamic>{'terms': terms});
    }
    final List<Map<String, dynamic>> created = <Map<String, dynamic>>[];
    final List<Map<String, dynamic>> updated = <Map<String, dynamic>>[];
    // The endpoint takes 500 at a time; a bigger file goes in chunks.
    for (int i = 0; i < terms.length; i += 500) {
      final Map<String, dynamic> r = await client.upsertGlossary(
        projectId,
        terms.sublist(i, i + 500 > terms.length ? terms.length : i + 500),
      );
      created.addAll((r['created'] as List<dynamic>? ?? const <dynamic>[]).cast());
      updated.addAll((r['updated'] as List<dynamic>? ?? const <dynamic>[]).cast());
    }
    return OpResult(
      true,
      'Imported $path: ${created.length} added, ${updated.length} updated. '
      '$_retranslateHint',
      <String, dynamic>{'created': created, 'updated': updated},
    );
  }

  /// The glossary as a file `fl glossary import` reads back.
  Future<OpResult> export(final String path) async {
    final List<Map<String, dynamic>> terms = await _terms();
    final List<Map<String, dynamic>> rows = <Map<String, dynamic>>[
      for (final Map<String, dynamic> t in terms)
        <String, dynamic>{
          'term': t['term'],
          if (t['do_not_translate'] == true) 'do_not_translate': true,
          if (t['case_sensitive'] == true) 'case_sensitive': true,
          if ((t['translations'] as Map?)?.isNotEmpty ?? false)
            'translations': t['translations'],
          if ((t['note'] as String? ?? '').isNotEmpty) 'note': t['note'],
        },
    ];
    File(path).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(<String, dynamic>{'terms': rows})}\n',
    );
    return OpResult(true, 'Wrote ${rows.length} term(s) to $path.',
        <String, dynamic>{'path': path, 'count': rows.length});
  }

  Future<OpResult> suggest({final bool apply = false, final bool dryRun = false}) async {
    final List<Map<String, dynamic>> suggestions =
        await client.glossarySuggestions(projectId);
    if (suggestions.isEmpty) {
      return OpResult(true, 'Nothing to suggest.', <String, dynamic>{'suggestions': suggestions});
    }
    if (!apply || dryRun) {
      return OpResult(
        true,
        '${suggestions.length} suggestion(s). Review them, then add the ones '
        'you want with `fl glossary add`, or all of them with '
        '`fl glossary suggest --apply`.',
        <String, dynamic>{'suggestions': suggestions},
      );
    }
    final Map<String, dynamic> r = await client.upsertGlossary(projectId, <Map<String, dynamic>>[
      for (final Map<String, dynamic> s in suggestions)
        <String, dynamic>{'term': s['term'], 'do_not_translate': s['do_not_translate'] == true},
    ]);
    final int created = (r['created'] as List<dynamic>? ?? const <dynamic>[]).length;
    return OpResult(true, 'Added $created term(s). $_retranslateHint',
        <String, dynamic>{'created': r['created']});
  }

  /// Re-translate every string that contains a glossary term ([only] narrows
  /// it to some terms), so translations made before the term was added follow
  /// it. Changing a language style is applied the same way, with [all].
  Future<OpResult> apply(
    final Operations ops, {
    final List<String> only = const <String>[],
    final bool all = false,
    final List<String>? locales,
    final bool dryRun = false,
  }) async {
    if (all) {
      return ops.retranslateWhere((final String _) => true,
          locales: locales, dryRun: dryRun);
    }
    final List<Map<String, dynamic>> terms = await _terms();
    final Set<String> wanted =
        only.map((final String t) => t.trim().toLowerCase()).toSet();
    final List<Map<String, dynamic>> chosen = <Map<String, dynamic>>[
      for (final Map<String, dynamic> t in terms)
        if (wanted.isEmpty || wanted.contains((t['term'] as String).toLowerCase())) t,
    ];
    final Set<String> unknown = wanted.difference(<String>{
      for (final Map<String, dynamic> t in chosen) (t['term'] as String).toLowerCase(),
    });
    if (unknown.isNotEmpty) {
      return OpResult(false, 'Not in the glossary: ${unknown.join(', ')}.');
    }
    if (chosen.isEmpty) {
      return OpResult(false, 'The glossary is empty; nothing to apply.');
    }
    final List<RegExp> patterns = <RegExp>[
      for (final Map<String, dynamic> t in chosen)
        termPattern(t['term'] as String, caseSensitive: t['case_sensitive'] == true),
    ];
    return ops.retranslateWhere(
      (final String base) => patterns.any((final RegExp p) => p.hasMatch(base)),
      locales: locales,
      dryRun: dryRun,
    );
  }

  Future<OpResult> styles() async {
    final Map<String, dynamic> r = await client.listLanguageStyles(projectId);
    return OpResult(true, 'Language styles.', <String, dynamic>{'languages': r['languages'] ?? const <dynamic>[]});
  }

  Future<OpResult> setStyle(
    final String code, {
    required final String formality,
    final String instructions = '',
    final bool dryRun = false,
  }) async {
    final String locale = canonicalizeOrKeep(code);
    if (dryRun) {
      return OpResult(true, 'Would set $locale to ${formality.isEmpty ? "translator's choice" : formality}.');
    }
    final Map<String, dynamic> saved = await client.setLanguageStyle(
      projectId,
      locale,
      formality: formality,
      instructions: instructions,
    );
    return OpResult(
      true,
      '$locale: ${formality.isEmpty ? "translator's choice" : formality}'
      '${instructions.isNotEmpty ? ', with instructions' : ''}. Regional '
      'variants without their own style follow it. $_retranslateHint',
      <String, dynamic>{'style': saved},
    );
  }

  Future<OpResult> clearStyle(final String code, {final bool dryRun = false}) async {
    final String locale = canonicalizeOrKeep(code);
    if (dryRun) return OpResult(true, 'Would clear the style of $locale.');
    await client.deleteLanguageStyle(projectId, locale);
    return OpResult(true, 'Cleared the style of $locale.');
  }

  Future<OpResult> lock(
    final List<String> keys, {
    final bool on = true,
    final bool dryRun = false,
  }) async {
    if (keys.isEmpty) throw ManagementException('Name at least one key.');
    if (dryRun) {
      return OpResult(true, 'Would ${on ? 'lock' : 'unlock'} ${keys.length} key(s).');
    }
    final Map<String, dynamic> r =
        await client.setDoNotTranslate(projectId, keys, doNotTranslate: on);
    return OpResult(
      true,
      on
          ? 'Locked ${r['updated']} key(s): every locale now shows the base '
              'text (${r['values_copied']} value(s) reset) and they are never '
              'sent for translation.'
          : 'Unlocked ${r['updated']} key(s). Run `fl retranslate` to '
              'translate them.',
      r,
    );
  }

  Future<Map<String, dynamic>?> _find(final String term) async {
    final String folded = term.trim().toLowerCase();
    for (final Map<String, dynamic> t in await _terms()) {
      if ((t['term'] as String).toLowerCase() == folded) return t;
    }
    return null;
  }

  static String _describe(final Map<String, dynamic> t) {
    if (t['do_not_translate'] == true) return 'kept as written';
    final Map<String, dynamic> tr =
        (t['translations'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
    if (tr.isEmpty) return 'no fixed translation';
    return tr.entries.map((final MapEntry<String, dynamic> e) => '${e.key}: ${e.value}').join(', ');
  }

  /// One line per term, for the CLI listing.
  static String describeTerm(final Map<String, dynamic> t) {
    final String note = (t['note'] as String? ?? '').isEmpty ? '' : '  (${t['note']})';
    return '${t['term']} → ${_describe(t)}  [${t['string_count'] ?? 0} string(s)]$note';
  }
}
