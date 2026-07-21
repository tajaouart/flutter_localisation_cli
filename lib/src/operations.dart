/// High-level operations composed from [ManagementClient].
///
/// These are the units the CLI and the MCP server both call, so behaviour (and the
/// add→translate→resolve sequencing) stays identical across surfaces. Each returns a
/// plain map so it can be printed by the CLI or returned as JSON by MCP. Every op supports
/// `dryRun` to compute the plan without mutating.
library;

import 'dart:convert';

import 'package:flutter_localisation_cli/src/management_client.dart';

/// Parse `--placeholder name:type[:format]` specs into the backend's placeholder
/// map: `{name: {type, format?}}`. Returns null when [raw] is empty so callers
/// don't send an empty map that would clobber backend auto-detected placeholders.
Map<String, dynamic>? parsePlaceholderSpecs(final List<String> raw) {
  if (raw.isEmpty) return null;
  final Map<String, dynamic> out = <String, dynamic>{};
  for (final String p in raw) {
    final List<String> parts = p.split(':');
    final String name = parts.first;
    final String type =
        parts.length > 1 && parts[1].isNotEmpty ? parts[1] : 'String';
    final Map<String, String> meta = <String, String>{'type': type};
    if (parts.length > 2 && parts[2].isNotEmpty) meta['format'] = parts[2];
    out[name] = meta;
  }
  return out;
}

class OpResult {
  OpResult(this.ok, this.message, [this.data = const <String, dynamic>{}]);

  final bool ok;
  final String message;
  final Map<String, dynamic> data;

  Map<String, dynamic> toJson() => <String, dynamic>{'ok': ok, 'message': message, ...data};
}

class Operations {
  Operations(this.client, this.projectId, {this.flavor});

  final ManagementClient client;
  final int projectId;
  final String? flavor;

  /// Runs the batch translate for [ids], then RE-FETCHES the project and verifies
  /// each target actually changed. Defends against a backend that reports
  /// "translated" while writing the base text straight back (a silent false
  /// success): any locale whose value still equals its key's non-empty base value
  /// is counted as failed, not translated — so the CLI never over-reports.
  Future<({int translated, List<({int id, String reason})> failed})>
      _translateAndVerify(final List<int> ids) async {
    final BatchTranslateResult r = await client.aiBatchTranslate(ids);
    final Map<int, String> backendErrors = <int, String>{
      for (final ({int id, String error}) f in r.failed) f.id: f.error,
    };

    final ProjectData after = await client.getProject(projectId);
    final FlavorData fl = after.flavor(flavor);
    final String? baseCode = after.baseLanguage(flavor)?.code;
    final Map<String, String> baseByKey = <String, String>{
      for (final LanguageData l in fl.languages)
        if (l.code == baseCode)
          for (final TranslationEntry t in l.translations) t.key: t.value,
    };
    final Map<int, TranslationEntry> byId = <int, TranslationEntry>{
      for (final LanguageData l in fl.languages)
        for (final TranslationEntry t in l.translations) t.id: t,
    };

    var translated = 0;
    final List<({int id, String reason})> failed = <({int id, String reason})>[];
    for (final int id in ids) {
      if (backendErrors.containsKey(id)) {
        final String e = backendErrors[id]!;
        failed.add((id: id, reason: e.isEmpty ? 'translation failed' : e));
        continue;
      }
      final TranslationEntry? t = byId[id];
      final String? base = t == null ? null : baseByKey[t.key];
      final bool unchanged = t != null &&
          base != null &&
          base.trim().isNotEmpty &&
          t.value.trim() == base.trim();
      if (unchanged) {
        failed.add((
          id: id,
          reason: 'unchanged from source — base text written back, not translated',
        ));
      } else {
        translated++;
      }
    }
    return (translated: translated, failed: failed);
  }

  static List<Map<String, Object>> _failedJson(
          final List<({int id, String reason})> failed) =>
      failed
          .map((final ({int id, String reason}) f) =>
              <String, Object>{'id': f.id, 'error': f.reason})
          .toList();

  /// Add a key with its base value, optionally AI-translating the other locales.
  Future<OpResult> add(
    final String key,
    final String baseValue, {
    final bool translate = false,
    final Map<String, dynamic>? placeholders,
    final bool? isPlaceholdersEnabled,
    final String? description,
    final bool dryRun = false,
  }) async {
    if (dryRun) {
      return OpResult(true, 'DRY RUN: would add "$key" = "$baseValue"'
          '${translate ? ' and AI-translate all other locales' : ''}.');
    }
    await client.addKey(
      projectId,
      key,
      baseValue,
      placeholders: placeholders,
      isPlaceholdersEnabled: isPlaceholdersEnabled,
      description: description,
    );

    if (!translate) {
      return OpResult(true, 'Added "$key".', <String, dynamic>{'key': key});
    }

    final ProjectData project = await client.getProject(projectId);
    final String? baseCode = project.baseLanguage(flavor)?.code;
    final List<int> targets = project
        .entriesForKey(key, flavorName: flavor)
        .where((final ({bool empty, int id, String locale}) e) => e.locale != baseCode)
        .map((final ({bool empty, int id, String locale}) e) => e.id)
        .toList();

    if (targets.isEmpty) {
      return OpResult(true, 'Added "$key" (no other locales to translate).',
          <String, dynamic>{'key': key},);
    }
    final ({int translated, List<({int id, String reason})> failed}) result =
        await _translateAndVerify(targets);
    return OpResult(
      result.failed.isEmpty,
      'Added "$key" and translated ${result.translated}/${targets.length} locales'
      '${result.failed.isNotEmpty ? ' (${result.failed.length} failed)' : ''}.',
      <String, dynamic>{
        'key': key,
        'translated': result.translated,
        'failed': _failedJson(result.failed),
      },
    );
  }

  /// Bulk-create keys by importing a whole ARB file in ONE request (instead of
  /// N per-key adds). Resolves the flavor id + the language the file represents
  /// (defaults to the base language). With [translate], batch-translates every
  /// empty non-base locale afterwards. This is the right primitive for large
  /// migrations — put all the strings in a file and import it once.
  Future<OpResult> importArb(
    final String arbContent, {
    final String? languageCode,
    final bool overwrite = false,
    final bool translate = false,
    final bool dryRun = false,
  }) async {
    int keyCount;
    try {
      final Object? parsed = jsonDecode(arbContent);
      if (parsed is! Map<String, dynamic>) {
        return OpResult(false, 'Invalid ARB: top-level value must be a JSON object.');
      }
      keyCount = parsed.keys.where((final String k) => !k.startsWith('@')).length;
    } catch (_) {
      return OpResult(false, 'Invalid ARB: not valid JSON.');
    }

    final ProjectData project = await client.getProject(projectId);
    final FlavorData fl = project.flavor(flavor);
    final String lang =
        languageCode ?? project.baseLanguage(flavor)?.code ?? 'en';

    if (dryRun) {
      return OpResult(
        true,
        'DRY RUN: would import $keyCount key(s) into flavor "${fl.name}" '
        '(language "$lang"${overwrite ? ', overwriting existing' : ''})'
        '${translate ? ', then batch-translate the other locales' : ''}.',
        <String, dynamic>{'keys': keyCount, 'flavor': fl.name, 'language': lang},
      );
    }

    // When a specific locale is targeted (`--language fr`), write ONLY that
    // locale. `apply_to_all_languages` must stay true only for a base-language
    // import, where seeding every locale with the base text is intended (so a
    // fresh key is ready to translate). Passing a locale but applying to all
    // would clobber every other language with this file's values.
    await client.importArb(projectId, fl.id, lang, arbContent,
        overwriteExisting: overwrite,
        applyToAllLanguages: languageCode == null);

    if (!translate) {
      return OpResult(true, 'Imported $keyCount key(s) into "${fl.name}".',
          <String, dynamic>{'imported': keyCount, 'flavor': fl.name});
    }

    // Collect non-base locale-strings that still need translation: either empty,
    // or still equal to the base value (untranslated). The import seeds every
    // locale with the base text (apply_to_all_languages), so a fresh key's other
    // locales are non-empty but identical to the base — those must be translated
    // too, not just the literally-empty ones. Restrict to the keys we imported.
    final ProjectData after = await client.getProject(projectId);
    final String? baseCode = after.baseLanguage(flavor)?.code;
    final Set<String> importedKeys = <String>{};
    try {
      final Object? p = jsonDecode(arbContent);
      if (p is Map<String, dynamic>) {
        importedKeys.addAll(p.keys.where((final String k) => !k.startsWith('@')));
      }
    } catch (_) {}
    final Map<String, String> baseValues = <String, String>{};
    for (final LanguageData l in after.flavor(flavor).languages) {
      if (l.code != baseCode) continue;
      for (final TranslationEntry t in l.translations) {
        baseValues[t.key] = t.value;
      }
    }
    final List<int> targets = <int>[];
    for (final LanguageData l in after.flavor(flavor).languages) {
      if (l.code == baseCode) continue;
      for (final TranslationEntry t in l.translations) {
        if (!importedKeys.contains(t.key)) continue;
        final String? base = baseValues[t.key];
        final bool untranslated = t.isEmpty ||
            (base != null &&
                base.trim().isNotEmpty &&
                t.value.trim() == base.trim());
        if (untranslated) targets.add(t.id);
      }
    }
    if (targets.isEmpty) {
      return OpResult(true, 'Imported $keyCount key(s); nothing to translate.',
          <String, dynamic>{'imported': keyCount});
    }
    final ({int translated, List<({int id, String reason})> failed}) result =
        await _translateAndVerify(targets);
    return OpResult(
      result.failed.isEmpty,
      'Imported $keyCount key(s) and translated '
      '${result.translated}/${targets.length} locale-strings'
      '${result.failed.isNotEmpty ? ' (${result.failed.length} failed)' : ''}.',
      <String, dynamic>{
        'imported': keyCount,
        'translated': result.translated,
        'failed': _failedJson(result.failed),
      },
    );
  }

  /// Edit one locale's value (or plural/placeholder fields) of an existing key.
  Future<OpResult> edit(
    final String key,
    final String locale, {
    final String? value,
    final bool? isPluralEnabled,
    final String? zeroCase,
    final String? singularCase,
    final String? pluralCase,
    final String? pluralParam,
    final bool? isPlaceholdersEnabled,
    final Map<String, dynamic>? placeholders,
    final String? description,
    final bool? isChecked,
    final bool dryRun = false,
  }) async {
    final ProjectData project = await client.getProject(projectId);
    final int id = project.resolveId(key, locale, flavorName: flavor);
    if (dryRun) {
      return OpResult(true, 'DRY RUN: would update "$key" [$locale] (id $id).');
    }
    await client.updateTranslation(
      id,
      value: value,
      isPluralEnabled: isPluralEnabled,
      zeroCase: zeroCase,
      singularCase: singularCase,
      pluralCase: pluralCase,
      pluralParam: pluralParam,
      isPlaceholdersEnabled: isPlaceholdersEnabled,
      placeholders: placeholders,
      description: description,
      isChecked: isChecked,
    );
    return OpResult(true, 'Updated "$key" [$locale].', <String, dynamic>{'key': key, 'locale': locale});
  }

  /// Delete a key. Without [locale] the whole key is removed (all locales + the key
  /// itself). With [locale], only that one locale's translation is deleted.
  Future<OpResult> delete(
    final String key, {
    final String? locale,
    final bool dryRun = false,
  }) async {
    // Whole-key delete: one call, removes the TranslationKey too (no orphaned empty key).
    if (locale == null) {
      if (dryRun) {
        return OpResult(true, 'DRY RUN: would delete the whole key "$key" (all locales).');
      }
      await client.deleteKey(projectId, key);
      return OpResult(
        true,
        'Deleted key "$key" (all locales).',
        <String, dynamic>{'key': key},
      );
    }

    // Single-locale delete: remove just that locale's translation.
    final ProjectData project = await client.getProject(projectId);
    final List<({String locale, int id, bool empty})> targets = project
        .entriesForKey(key, flavorName: flavor)
        .where((final ({bool empty, int id, String locale}) e) => e.locale == locale)
        .toList();

    if (targets.isEmpty) {
      return OpResult(false, 'Nothing to delete for "$key" [$locale].');
    }
    if (dryRun) {
      return OpResult(true, 'DRY RUN: would delete "$key" [$locale].');
    }
    await client.deleteTranslation(targets.first.id);
    return OpResult(true, 'Deleted "$key" [$locale].',
        <String, dynamic>{'key': key, 'locale': locale},);
  }

  /// AI-translate a key's locales. Defaults to the missing ones; pass [all] for every
  /// non-base locale, or [locales] for a specific set.
  Future<OpResult> translate(
    final String key, {
    final List<String>? locales,
    final bool all = false,
    final bool dryRun = false,
  }) async {
    final ProjectData project = await client.getProject(projectId);
    final String? baseCode = project.baseLanguage(flavor)?.code;
    final List<({String locale, int id, bool empty})> entries =
        project.entriesForKey(key, flavorName: flavor);

    Iterable<({String locale, int id, bool empty})> selected =
        entries.where((final ({bool empty, int id, String locale}) e) => e.locale != baseCode);
    if (locales != null && locales.isNotEmpty) {
      selected = selected.where((final ({bool empty, int id, String locale}) e) => locales.contains(e.locale));
    } else if (!all) {
      selected = selected.where((final ({bool empty, int id, String locale}) e) => e.empty); // only-missing default
    }
    final List<int> ids = selected.map((final ({bool empty, int id, String locale}) e) => e.id).toList();
    if (ids.isEmpty) {
      return OpResult(true, 'Nothing to translate for "$key".');
    }
    if (dryRun) {
      return OpResult(true, 'DRY RUN: would translate ${ids.length} locale(s) for "$key".');
    }
    final ({int translated, List<({int id, String reason})> failed}) result =
        await _translateAndVerify(ids);
    return OpResult(
      result.failed.isEmpty,
      'Translated ${result.translated}/${ids.length} locale(s) for "$key"'
      '${result.failed.isNotEmpty ? ' (${result.failed.length} failed)' : ''}.',
      <String, dynamic>{
        'translated': result.translated,
        'failed': _failedJson(result.failed),
      },
    );
  }

  /// Completion status per locale for the selected flavor.
  Future<OpResult> status() async {
    final ProjectData project = await client.getProject(projectId);
    final FlavorData f = project.flavor(flavor);
    final List<Map<String, dynamic>> rows = <Map<String, dynamic>>[];
    for (final LanguageData l in f.languages) {
      final int total = l.translations.length;
      final int filled = l.translations.where((final TranslationEntry t) => !t.isEmpty).length;
      rows.add(<String, dynamic>{
        'locale': l.code,
        'base': l.isBase,
        'filled': filled,
        'total': total,
        'percent': total == 0 ? 100 : ((filled / total) * 100).round(),
      });
    }
    return OpResult(true, 'Status for "${project.name}" / flavor "${f.name}".',
        <String, dynamic>{'flavor': f.name, 'locales': rows},);
  }
}
