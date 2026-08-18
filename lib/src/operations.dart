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
    return _verify(ids, backendErrors);
  }

  /// Re-fetches the project and checks that each of [ids] actually changed.
  ///
  /// Split out of [_translateAndVerify] so a chunked bulk run can issue many
  /// batch calls and pay for the (whole-project) re-fetch once at the end
  /// instead of once per chunk.
  Future<({int translated, List<({int id, String reason})> failed})> _verify(
    final List<int> ids,
    final Map<int, String> backendErrors,
  ) async {
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

    // When a specific NON-BASE locale is targeted (`--language fr`), write ONLY
    // that locale: applying a translated file to all languages would clobber
    // every other language with French text.
    //
    // A base-language import seeds every locale, so a fresh key exists in all of
    // them and is ready to translate. Naming the base language explicitly
    // (`--language en` on an en-base project) MUST behave exactly like omitting
    // it. It did not: `languageCode == null` was false, only `en` got rows, and
    // `--translate` then found nothing to translate and reported success. The
    // caller's only working fallback was add-then-translate per key — thousands
    // of round trips instead of one import. Compare against the base code, not
    // against null.
    final String? baseCodeBefore = project.baseLanguage(flavor)?.code;
    final bool targetsBaseLanguage =
        languageCode == null || languageCode == baseCodeBefore;
    await client.importArb(projectId, fl.id, lang, arbContent,
        overwriteExisting: overwrite,
        applyToAllLanguages: targetsBaseLanguage);

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
      // "Nothing to translate" has two very different causes and reporting both
      // as success is what cost a caller thousands of redundant requests:
      //
      //  a) every locale already holds a real translation — genuinely nothing
      //     to do, success;
      //  b) the non-base locales have NO ROW for these keys at all, so there was
      //     nothing to hand the batch translator. Success here is a lie: the
      //     user asked for translation and got none.
      //
      // Case (b) must fail loudly and say how to fix it, because the symptom a
      // caller sees ("✓ imported; nothing to translate" then 0% in `status`) is
      // otherwise indistinguishable from (a).
      final List<String> unseeded = <String>[];
      for (final LanguageData l in after.flavor(flavor).languages) {
        if (l.code == baseCode) continue;
        final Set<String> present = <String>{
          for (final TranslationEntry t in l.translations) t.key,
        };
        if (importedKeys.any((final String k) => !present.contains(k))) {
          unseeded.add(l.code);
        }
      }
      if (unseeded.isNotEmpty) {
        return OpResult(
          false,
          'Imported $keyCount key(s), but ${unseeded.join(", ")} have no rows for '
          'them, so --translate had nothing to work on. Re-run the import against '
          'the base language (omit --language) so every locale is seeded, then '
          'translate. Do NOT fall back to per-key add/translate.',
          <String, dynamic>{
            'imported': keyCount,
            'translated': 0,
            'unseeded_locales': unseeded,
          },
        );
      }
      return OpResult(
        true,
        'Imported $keyCount key(s); every locale already translated.',
        <String, dynamic>{'imported': keyCount, 'translated': 0},
      );
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
      // A locale with no row for this key is invisible to `entriesForKey`, so it
      // silently drops out of the selection and the command claims there is
      // nothing to translate — even under `--all`, where the caller explicitly
      // asked for every locale. Name the gap instead of swallowing it.
      final Set<String> covered = <String>{
        for (final ({bool empty, int id, String locale}) e in entries) e.locale,
      };
      final List<String> missing = <String>[
        for (final LanguageData l in project.flavor(flavor).languages)
          if (l.code != baseCode && !covered.contains(l.code)) l.code,
      ];
      if (missing.isNotEmpty) {
        return OpResult(
          false,
          'Cannot translate "$key": ${missing.join(", ")} have no row for it. '
          'Re-import the key against the base language so every locale is seeded.',
          <String, dynamic>{'key': key, 'unseeded_locales': missing},
        );
      }
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

  /// AI-translate, across whole locales, every value that still needs work.
  ///
  /// [translate] is per-key, so filling a locale through it costs one request
  /// per key. This walks the key list once and hands the batch endpoint every
  /// id that needs work, in chunks of [chunkSize].
  ///
  /// A value needs work when it is empty, or when it is byte-identical to the
  /// base value and not yet [TranslationEntry.isChecked]. The second case is
  /// the one no other command can reach: a locale whose rows hold the base
  /// text is *filled* but not *translated*, so completion reporting counts it
  /// as done while the app ships in the source language. [translate] cannot
  /// repair it — those rows are not missing — and `--all` is still one key per
  /// call.
  ///
  /// Two exclusions keep repeat runs from re-translating the same rows for
  /// ever:
  ///
  /// - A row equal to its source but marked checked is treated as deliberate.
  ///   Some strings are correctly identical in a given language — loanwords,
  ///   product names, notation, values that are only placeholders — and
  ///   marking one checked is how a reviewer records that decision. No
  ///   heuristic here tries to guess which strings those are; that judgement
  ///   belongs to whoever reviews the locale.
  /// - A key whose base value is itself empty has nothing to translate from.
  Future<OpResult> retranslate({
    final List<String>? locales,
    final bool dryRun = false,
    final int chunkSize = 100,
  }) async {
    final ProjectData project = await client.getProject(projectId);
    final FlavorData f = project.flavor(flavor);
    final String? baseCode = project.baseLanguage(flavor)?.code;
    if (baseCode == null) {
      return OpResult(false, 'No base language on flavor "${f.name}".');
    }
    final Map<String, String> baseByKey = <String, String>{
      for (final LanguageData l in f.languages)
        if (l.code == baseCode)
          for (final TranslationEntry t in l.translations) t.key: t.value,
    };

    if (locales != null && locales.isNotEmpty) {
      final Set<String> known = <String>{
        for (final LanguageData l in f.languages) l.code,
      };
      final List<String> unknown =
          locales.where((final String c) => !known.contains(c)).toList();
      if (unknown.isNotEmpty) {
        return OpResult(
          false,
          'Not a locale on "${f.name}": ${unknown.join(", ")}.',
          <String, dynamic>{'unknown_locales': unknown},
        );
      }
    }

    final List<int> ids = <int>[];
    final Map<String, int> perLocale = <String, int>{};
    for (final LanguageData l in f.languages) {
      if (l.code == baseCode) continue;
      if (locales != null && locales.isNotEmpty && !locales.contains(l.code)) {
        continue;
      }
      var n = 0;
      for (final TranslationEntry t in l.translations) {
        final String? base = baseByKey[t.key];
        if (base == null || base.trim().isEmpty) continue;
        final bool needsWork = t.value.trim().isEmpty ||
            (t.value.trim() == base.trim() && !t.isChecked);
        if (needsWork) {
          ids.add(t.id);
          n++;
        }
      }
      if (n > 0) perLocale[l.code] = n;
    }

    if (ids.isEmpty) {
      return OpResult(true, 'Nothing to translate — every locale differs from the base.');
    }
    if (dryRun) {
      return OpResult(
        true,
        'DRY RUN: would translate ${ids.length} value(s) across '
        '${perLocale.length} locale(s).',
        <String, dynamic>{'pending': ids.length, 'per_locale': perLocale},
      );
    }

    final Map<int, String> backendErrors = <int, String>{};
    for (var i = 0; i < ids.length; i += chunkSize) {
      final List<int> chunk =
          ids.sublist(i, i + chunkSize > ids.length ? ids.length : i + chunkSize);
      final BatchTranslateResult r = await client.aiBatchTranslate(chunk);
      for (final ({int id, String error}) fail in r.failed) {
        backendErrors[fail.id] = fail.error;
      }
    }

    final ({int translated, List<({int id, String reason})> failed}) result =
        await _verify(ids, backendErrors);
    return OpResult(
      result.failed.isEmpty,
      'Translated ${result.translated}/${ids.length} value(s) across '
      '${perLocale.length} locale(s)'
      '${result.failed.isNotEmpty ? ' (${result.failed.length} failed)' : ''}.',
      <String, dynamic>{
        'translated': result.translated,
        'attempted': ids.length,
        'per_locale': perLocale,
        'failed': _failedJson(result.failed),
      },
    );
  }

  /// List the locales on the selected flavor.
  Future<OpResult> listLanguages() async {
    final ProjectData project = await client.getProject(projectId);
    final FlavorData f = project.flavor(flavor);
    return OpResult(
      true,
      'Languages on "${project.name}" / flavor "${f.name}".',
      <String, dynamic>{
        'flavor': f.name,
        'locales': <Map<String, dynamic>>[
          for (final LanguageData l in f.languages)
            <String, dynamic>{
              'locale': l.code,
              'base': l.isBase,
              'keys': l.translations.length,
              'filled':
                  l.translations.where((final TranslationEntry t) => !t.isEmpty).length,
            },
        ],
      },
    );
  }

  /// Add a locale to the flavor, optionally AI-filling every existing key.
  ///
  /// This is the bulk primitive for a new language: one request, and the backend
  /// back-fills all existing keys. Callers must never iterate keys themselves.
  Future<OpResult> addLanguage(
    final String languageCode, {
    final bool autoTranslate = false,
    final bool dryRun = false,
  }) async {
    final ProjectData project = await client.getProject(projectId);
    final FlavorData f = project.flavor(flavor);

    final LanguageData? existing = f.languages
        .where((final LanguageData l) => l.code == languageCode)
        .firstOrNull;
    if (existing != null) {
      return OpResult(
        false,
        'Locale "$languageCode" is already on flavor "${f.name}".',
        <String, dynamic>{'locale': languageCode},
      );
    }

    final int keyCount = f.languages.isEmpty ? 0 : f.languages.first.translations.length;
    if (dryRun) {
      return OpResult(
        true,
        'DRY RUN: would add "$languageCode" to "${f.name}"'
        '${autoTranslate ? ', AI-filling $keyCount existing key(s)' : ''}.',
        <String, dynamic>{'locale': languageCode, 'keys': keyCount},
      );
    }

    await client.addLanguage(projectId, f.id, languageCode,
        autoTranslate: autoTranslate);

    // Verify rather than trust. Reporting a success the backend did not deliver
    // is exactly what sends callers back to per-key loops, so re-read the
    // project and say what actually landed.
    final ProjectData after = await client.getProject(projectId);
    final LanguageData? added = after
        .flavor(flavor)
        .languages
        .where((final LanguageData l) => l.code == languageCode)
        .firstOrNull;
    if (added == null) {
      return OpResult(
        false,
        'Backend accepted the request but "$languageCode" is not on the project. '
        'It may not be in the supported language list.',
        <String, dynamic>{'locale': languageCode},
      );
    }
    final int filled =
        added.translations.where((final TranslationEntry t) => !t.isEmpty).length;
    if (autoTranslate && keyCount > 0 && filled == 0) {
      return OpResult(
        false,
        'Added "$languageCode", but auto-translate filled 0 of $keyCount key(s). '
        'Re-run `fl translate` for the affected keys, or check the AI translation '
        'quota — do NOT fall back to per-key adds.',
        <String, dynamic>{'locale': languageCode, 'keys': keyCount, 'filled': 0},
      );
    }
    return OpResult(
      true,
      'Added "$languageCode" to "${f.name}"'
      '${autoTranslate ? ' and filled $filled/${added.translations.length} key(s)' : ''}.',
      <String, dynamic>{
        'locale': languageCode,
        'keys': added.translations.length,
        'filled': filled,
      },
    );
  }

  /// Remove a locale and every translation it holds.
  Future<OpResult> removeLanguage(
    final String languageCode, {
    final bool dryRun = false,
  }) async {
    final ProjectData project = await client.getProject(projectId);
    final FlavorData f = project.flavor(flavor);
    final LanguageData? target = f.languages
        .where((final LanguageData l) => l.code == languageCode)
        .firstOrNull;
    if (target == null) {
      return OpResult(false, 'Locale "$languageCode" is not on flavor "${f.name}".');
    }
    if (target.isBase) {
      return OpResult(false, 'Refusing to remove "$languageCode": it is the base language.');
    }
    if (dryRun) {
      return OpResult(
        true,
        'DRY RUN: would remove "$languageCode" and its '
        '${target.translations.length} translation(s).',
      );
    }
    await client.deleteLanguage(target.id);
    return OpResult(true, 'Removed "$languageCode" from "${f.name}".',
        <String, dynamic>{'locale': languageCode});
  }

  /// Completion status per locale for the selected flavor.
  Future<OpResult> status() async {
    final ProjectData project = await client.getProject(projectId);
    final FlavorData f = project.flavor(flavor);
    // `filled` counts non-empty rows, which treats a row still holding the
    // base text as done — so a locale can report 100% while the app ships in
    // the source language.
    //
    // `filled` and `percent` keep their original meaning: they are part of the
    // published response and existing callers parse them. The distinction is
    // added alongside as `translated` / `untranslated` / `translated_percent`
    // rather than folded into the old fields.
    final String? baseCode = project.baseLanguage(flavor)?.code;
    final Map<String, String> baseByKey = <String, String>{
      for (final LanguageData l in f.languages)
        if (l.code == baseCode)
          for (final TranslationEntry t in l.translations) t.key: t.value,
    };
    final List<Map<String, dynamic>> rows = <Map<String, dynamic>>[];
    for (final LanguageData l in f.languages) {
      final int total = l.translations.length;
      final int filled = l.translations.where((final TranslationEntry t) => !t.isEmpty).length;
      // Rows a reviewer has marked checked are counted as translated even when
      // they equal the source: that is how a deliberate match is recorded.
      final int sameAsBase = l.isBase
          ? 0
          : l.translations.where((final TranslationEntry t) {
              final String? base = baseByKey[t.key];
              return base != null &&
                  base.trim().isNotEmpty &&
                  t.value.trim() == base.trim() &&
                  !t.isChecked;
            }).length;
      final int translated = l.isBase ? total : filled - sameAsBase;
      rows.add(<String, dynamic>{
        'locale': l.code,
        'base': l.isBase,
        'filled': filled,
        'untranslated': sameAsBase,
        'translated': translated,
        'total': total,
        'percent': total == 0 ? 100 : ((filled / total) * 100).round(),
        'translated_percent':
            total == 0 ? 100 : ((translated / total) * 100).round(),
      });
    }
    return OpResult(true, 'Status for "${project.name}" / flavor "${f.name}".',
        <String, dynamic>{'flavor': f.name, 'locales': rows},);
  }
}
