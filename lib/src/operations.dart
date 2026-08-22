/// High-level operations composed from [ManagementClient].
///
/// These are the units the CLI and the MCP server both call, so behaviour (and the
/// add→translate→resolve sequencing) stays identical across surfaces. Each returns a
/// plain map so it can be printed by the CLI or returned as JSON by MCP. Every op supports
/// `dryRun` to compute the plan without mutating.
library;

import 'dart:convert';

import 'package:flutter_localisation_cli/src/exceptions.dart';
import 'package:flutter_localisation_cli/src/locales.dart';
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

/// What a translate run actually did, split three ways.
///
/// `failed` and `unchanged` were one bucket until it became clear they are not
/// the same event and do not have the same remedy:
///
/// - **failed** is a backend error for that row — a validation rejection, a
///   timeout, a dead service. Something is wrong and someone must act.
/// - **unchanged** is a value that came back byte-identical to its source.
///   Usually that is *the correct answer*: "OK", "Premium", "PRO", "Normal",
///   "Start", "Reset", "Detail" and every other loanword is spelled the same
///   in the target language, and French really does write "Nature" and German
///   "Name".
///
/// Merging them meant a healthy run reported dozens of "failures", which cost
/// more than tidiness. It trained readers to skip the number; it made
/// [retranslate] re-send the same correct-but-identical rows on every run for
/// ever; and it hid the handful of genuine backend errors sitting in the same
/// count. Keeping them apart is what lets `failed` mean something again.
///
/// The remedy for an unchanged row is to mark it checked — see
/// [Operations.retranslate]'s `acceptUnchanged` — which both [status] and
/// [retranslate] already honour.
typedef VerifyOutcome = ({
  int translated,
  List<({int id, String reason})> failed,
  List<({int id, String key, String locale})> unchanged,
});

class Operations {
  Operations(this.client, this.projectId, {this.flavor});

  final ManagementClient client;
  final int projectId;
  final String? flavor;

  /// Rows per AI batch request — one full parallel round on the server.
  ///
  /// Sized against what the endpoint actually does rather than guessed.
  /// `AIBatchTranslateAPIView` no longer splits by a fixed count: `_pack_batches`
  /// packs greedily up to `MAX_BATCH_OUTPUT_CHARS` of *estimated response*, hard
  /// capped at `MAX_BATCH_ITEMS` (400), and runs `MAX_WORKERS` (4) of the
  /// resulting calls at once. So one saturated round is **4 × 400 = 1,600 rows**.
  ///
  /// This was 400, written when the server did split at a fixed `BATCH_SIZE` of
  /// 100 — back then 400 rows really was 4 calls. Once the server started
  /// packing by size, 400 rows became ONE call and three of the four workers sat
  /// idle on every request: the exact waste the old value existed to avoid,
  /// inverted by a change on the other side.
  ///
  /// Both directions still cost something:
  ///
  /// - **Too small** leaves workers idle and multiplies request count against a
  ///   15 requests/minute quota.
  /// - **Everything at once** is what `import --translate` did, and 25,110 rows
  ///   in one call is a 504. The keys were created and none of the values were,
  ///   from a command that looked like it had failed outright.
  ///
  /// Measured on gemini-2.5-flash, real UI strings, English→Ukrainian — rows in
  /// a single Gemini call against throughput:
  ///
  ///     100 rows   26.1s    3.8 rows/sec
  ///     400 rows   39.0s   10.3 rows/sec   ← peak
  ///     800 rows  114.9s    7.0 rows/sec
  ///   1,600 rows  248.8s    6.4 rows/sec
  ///   3,200 rows      —     finishReason MAX_TOKENS, unparseable body
  ///
  /// Output decoding is sequential, so a bigger single call buys nothing past
  /// ~400 items; parallelism across calls is what pays. Hence 400 per call on
  /// the server and four calls per request here.
  ///
  /// Note the ceiling this does NOT lift: Gemini's 15 requests/minute still caps
  /// throughput however the work is shaped. Chunking decides how much of that
  /// budget each request buys, not whether the budget exists.
  static const int _defaultChunkSize = 1600;

  /// Runs the batch translate for [ids], then RE-FETCHES the project and verifies
  /// each target actually changed. Defends against a backend that reports
  /// "translated" while writing the base text straight back (a silent false
  /// success): any locale whose value still equals its key's non-empty base value
  /// is reported as unchanged rather than translated — so the CLI never
  /// over-reports.
  Future<VerifyOutcome> _translateAndVerify(
    final List<int> ids, {
    final int chunkSize = _defaultChunkSize,
  }) async {
    final Map<int, String> backendErrors = <int, String>{};
    final List<String> unattributed = <String>[];
    // One re-fetch at the end rather than one per chunk: _verify reads the
    // whole project, and that cost should not multiply with the row count.
    for (var i = 0; i < ids.length; i += chunkSize) {
      final int end = i + chunkSize > ids.length ? ids.length : i + chunkSize;
      unattributed.addAll(await _batchInto(ids.sublist(i, end), backendErrors));
    }
    final VerifyOutcome out = await _verify(ids, backendErrors);
    return _withUnattributed(out, unattributed);
  }

  /// Runs one batch and records its per-row errors into [into].
  ///
  /// Returns the reasons that could not be attributed to a row. The endpoint
  /// answers 400 when every row in the chunk failed, which the client raises —
  /// but "every row failed" is the *normal* outcome for a chunk that is all
  /// loanwords, and aborting there means a project whose remaining gap is
  /// entirely loanwords can never finish a run. So a body carrying per-row
  /// detail is unpacked and the run continues; only a rejection with no row
  /// detail at all is re-thrown, because that is a genuine outage.
  Future<List<String>> _batchInto(
    final List<int> ids,
    final Map<int, String> into,
  ) async {
    List<({int? id, String error})> rows;
    try {
      final BatchTranslateResult r = await client.aiBatchTranslate(ids);
      rows = <({int? id, String error})>[
        for (final ({int id, String error}) f in r.failed)
          (id: f.id, error: f.error),
      ];
    } on ApiException catch (e) {
      rows = batchRowErrorsFrom(e.body);
      if (rows.isEmpty) rethrow;
    }

    final List<String> unattributed = <String>[];
    for (final ({int? id, String error}) row in rows) {
      if (row.id != null) {
        into[row.id!] = row.error;
      } else if (!_isIdenticalToSource(row.error)) {
        // A row we cannot pin to an id still must not vanish: an identical-to-
        // source reason is recoverable from the re-fetch, but anything else
        // would be lost silently.
        unattributed.add(row.error);
      }
    }
    return unattributed;
  }

  /// Fold reasons that could not be attributed to a row into the outcome.
  static VerifyOutcome _withUnattributed(
    final VerifyOutcome out,
    final List<String> unattributed,
  ) {
    if (unattributed.isEmpty) return out;
    return (
      translated: out.translated,
      failed: <({int id, String reason})>[
        ...out.failed,
        for (final String reason in unattributed) (id: -1, reason: reason),
      ],
      unchanged: out.unchanged,
    );
  }

  /// Re-fetches the project and checks that each of [ids] actually changed.
  ///
  /// Split out of [_translateAndVerify] so a chunked bulk run can issue many
  /// batch calls and pay for the (whole-project) re-fetch once at the end
  /// instead of once per chunk.
  Future<VerifyOutcome> _verify(
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
    final Map<int, ({TranslationEntry entry, String locale})> byId =
        <int, ({TranslationEntry entry, String locale})>{
      for (final LanguageData l in fl.languages)
        for (final TranslationEntry t in l.translations)
          t.id: (entry: t, locale: l.code),
    };

    var translated = 0;
    final List<({int id, String reason})> failed = <({int id, String reason})>[];
    final List<({int id, String key, String locale})> unchanged =
        <({int id, String key, String locale})>[];
    for (final int id in ids) {
      final ({TranslationEntry entry, String locale})? row = byId[id];
      final TranslationEntry? t = row?.entry;
      final String? base = t == null ? null : baseByKey[t.key];
      final bool isUnchanged = t != null &&
          base != null &&
          base.trim().isNotEmpty &&
          t.value.trim() == base.trim();

      final String? backendError = backendErrors[id];
      if (backendError != null) {
        // When the backend gave a reason, the reason decides — NOT the
        // re-fetch. Every row selected for retranslation was already identical
        // to its source, and a row that fails validation keeps the value it
        // had, so `isUnchanged` is true for genuine failures too. Consulting it
        // here would file every real error under `unchanged`, where
        // --accept-unchanged would then mark a broken row as deliberate.
        //
        // The one error class that belongs in `unchanged` is the backend's own
        // "AI returned text identical to the source": same event this method
        // detects by re-fetching, same cause, same remedy. Left in `failed` it
        // puts every loanword in the error list — the exact problem
        // `unchanged` exists to solve, arriving from the other side.
        if (_isIdenticalToSource(backendError)) {
          unchanged.add((
            id: id,
            key: t?.key ?? '?',
            locale: row?.locale ?? '?',
          ));
        } else {
          failed.add((
            id: id,
            reason: backendError.isEmpty ? 'translation failed' : backendError,
          ));
        }
        continue;
      }

      if (isUnchanged) {
        unchanged.add((id: id, key: t.key, locale: row!.locale));
      } else {
        translated++;
      }
    }
    return (translated: translated, failed: failed, unchanged: unchanged);
  }

  /// Whether a per-row backend error is the "came back the same" class.
  ///
  /// Matched on text because that is all the batch endpoint gives — there is
  /// no error code. Kept deliberately narrow: anything unrecognised stays a
  /// real failure, so a new backend error is never silently downgraded.
  static bool _isIdenticalToSource(final String reason) {
    final String r = reason.toLowerCase();
    return r.contains('identical to the source') ||
        r.contains('identical to source');
  }

  /// The trailing detail on a run message, e.g. `" (2 failed, 14 unchanged)"`.
  static String _outcomeSuffix(final VerifyOutcome r) {
    final List<String> parts = <String>[
      if (r.failed.isNotEmpty) '${r.failed.length} failed',
      if (r.unchanged.isNotEmpty) '${r.unchanged.length} unchanged',
    ];
    return parts.isEmpty ? '' : ' (${parts.join(", ")})';
  }

  static List<Map<String, Object>> _failedJson(
          final List<({int id, String reason})> failed) =>
      failed
          .map((final ({int id, String reason}) f) =>
              <String, Object>{'id': f.id, 'error': f.reason})
          .toList();

  static List<Map<String, Object>> _unchangedJson(
          final List<({int id, String key, String locale})> unchanged) =>
      unchanged
          .map((final ({int id, String key, String locale}) e) =>
              <String, Object>{'id': e.id, 'key': e.key, 'locale': e.locale})
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
    final VerifyOutcome result = await _translateAndVerify(targets);
    return OpResult(
      result.failed.isEmpty,
      'Added "$key" and translated ${result.translated}/${targets.length} locales'
      '${_outcomeSuffix(result)}.',
      <String, dynamic>{
        'key': key,
        'translated': result.translated,
        'failed': _failedJson(result.failed),
        'unchanged': _unchangedJson(result.unchanged),
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
    final int chunkSize = _defaultChunkSize,
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
    final Map<String, dynamic> importResponse = await client.importArb(
        projectId, fl.id, lang, arbContent,
        overwriteExisting: overwrite,
        applyToAllLanguages: targetsBaseLanguage,
        // Ask the server to fill the locales in the SAME request. Older
        // backends ignore the field and answer without a `translation` block,
        // which is what the fallback below keys off — so this stays correct
        // against a deployment that predates it.
        autoTranslate: translate);

    if (!translate) {
      return OpResult(true, 'Imported $keyCount key(s) into "${fl.name}".',
          <String, dynamic>{'imported': keyCount, 'flavor': fl.name});
    }

    // The server did the filling: one round trip, and no re-fetch to work out
    // which rows were new. It declines only when the job is too big to finish
    // inside a request, in which case the chunked client-side path below is
    // exactly the right fallback.
    final Object? serverSide = importResponse['translation'];
    if (serverSide is Map<String, dynamic> &&
        serverSide['status'] != 'too_large') {
      final int filled = (serverSide['translated'] as int?) ?? 0;
      final int failedRows = (serverSide['failed'] as int?) ?? 0;
      final bool ok = serverSide['status'] != 'error';
      return OpResult(
        ok,
        ok
            ? 'Imported $keyCount key(s) and translated $filled locale-string(s)'
                '${failedRows > 0 ? ' ($failedRows failed)' : ''}.'
            : (serverSide['message'] as String?) ??
                'Imported $keyCount key(s); translating them failed.',
        <String, dynamic>{
          'imported': keyCount,
          'translated': filled,
          'failed_count': failedRows,
          'server_side': true,
        },
      );
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
    // The import has already been written at this point, so a failure in the
    // translate phase must not be reported as a failure of the whole command.
    // Letting the exception escape produced a bare "Error: Gateway Time-out"
    // from a run whose keys were all safely created — the caller's next move is
    // one command (`fl retranslate`), and nothing on screen said so or even
    // hinted the keys were in. A large `--translate` is exactly the request
    // most likely to time out, so this is the common case, not the edge.
    final VerifyOutcome result;
    try {
      result = await _translateAndVerify(targets, chunkSize: chunkSize);
    } on ManagementException catch (e) {
      return OpResult(
        false,
        'Imported $keyCount key(s), but translating them failed: ${e.message}. '
        'The keys ARE created and hold the base text — run `fl retranslate` to '
        'fill them (it works in chunks, so it survives what one big request '
        'does not).',
        <String, dynamic>{
          'imported': keyCount,
          'translated': 0,
          'translate_error': e.message,
          'pending': targets.length,
        },
      );
    }

    return OpResult(
      result.failed.isEmpty,
      'Imported $keyCount key(s) and translated '
      '${result.translated}/${targets.length} locale-strings'
      '${_outcomeSuffix(result)}.',
      <String, dynamic>{
        'imported': keyCount,
        'translated': result.translated,
        'failed': _failedJson(result.failed),
        'unchanged': _unchangedJson(result.unchanged),
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
    final String? twoCase,
    final String? fewCase,
    final String? manyCase,
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
      twoCase: twoCase,
      fewCase: fewCase,
      manyCase: manyCase,
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
    final VerifyOutcome result = await _translateAndVerify(ids);
    return OpResult(
      result.failed.isEmpty,
      'Translated ${result.translated}/${ids.length} locale(s) for "$key"'
      '${_outcomeSuffix(result)}.',
      <String, dynamic>{
        'translated': result.translated,
        'failed': _failedJson(result.failed),
        'unchanged': _unchangedJson(result.unchanged),
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
  ///
  /// [acceptUnchanged] closes the loop those exclusions imply. A row that is
  /// *correctly* identical to its source — a loanword, a product name, "OK" —
  /// is selected by this command on every run, comes back identical every
  /// time, and is reported every time, for ever. Nothing in the pipeline ever
  /// marks such a row checked, so nothing can ever remove it from the queue.
  /// With [acceptUnchanged], every row that survives a real translation
  /// attempt still identical to its source is marked checked: the translator
  /// has now been asked and has given the same answer twice, which is as close
  /// to a confirmation as an automated pass can get. Reviewers can still flip
  /// any of them back with `fl edit --no-checked`.
  ///
  /// COST: there is no bulk endpoint for the checked flag, so this is one
  /// request per row — and each write appears to trigger an ARB commit and push
  /// on the backend, so it runs at seconds per row, not milliseconds. 175 rows
  /// took roughly an hour against the live service. It is a one-off per
  /// project (that is the whole point — the rows never come back), but it is
  /// not something to run casually, and a bulk `is_checked` endpoint would
  /// remove the cost entirely.
  Future<OpResult> retranslate({
    final List<String>? locales,
    final bool dryRun = false,
    final int chunkSize = _defaultChunkSize,
    final bool acceptUnchanged = false,
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
    final List<String> unattributed = <String>[];
    for (var i = 0; i < ids.length; i += chunkSize) {
      final List<int> chunk =
          ids.sublist(i, i + chunkSize > ids.length ? ids.length : i + chunkSize);
      unattributed.addAll(await _batchInto(chunk, backendErrors));
    }

    final VerifyOutcome result =
        _withUnattributed(await _verify(ids, backendErrors), unattributed);

    var accepted = 0;
    final List<({int id, String reason})> acceptFailed =
        <({int id, String reason})>[];
    if (acceptUnchanged) {
      for (final ({int id, String key, String locale}) e in result.unchanged) {
        try {
          await client.updateTranslation(e.id, isChecked: true);
          accepted++;
        } on ManagementException catch (err) {
          // One row refusing the flag is not a reason to abandon the rest —
          // but the reason must survive. Swallowing it here reproduces exactly
          // the defect this whole change exists to fix: a bare count that says
          // something is wrong without saying what, when the message is
          // actionable ("'many_case' must be provided for locale 'fr'").
          acceptFailed.add((
            id: e.id,
            reason: '${e.locale} ${e.key}: ${err.message}',
          ));
        }
      }
    }

    return OpResult(
      result.failed.isEmpty,
      'Translated ${result.translated}/${ids.length} value(s) across '
      '${perLocale.length} locale(s)${_outcomeSuffix(result)}'
      '${accepted > 0 ? ', $accepted accepted as checked' : ''}'
      '${acceptFailed.isNotEmpty ? ', ${acceptFailed.length} could not be accepted' : ''}.',
      <String, dynamic>{
        'translated': result.translated,
        'attempted': ids.length,
        'per_locale': perLocale,
        'failed': _failedJson(result.failed),
        'unchanged': _unchangedJson(result.unchanged),
        if (acceptUnchanged) 'accepted': accepted,
        if (acceptFailed.isNotEmpty)
          'accept_failed': _failedJson(acceptFailed),
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
    final String rawLanguageCode, {
    final bool autoTranslate = false,
    final bool dryRun = false,
  }) async {
    // The backend canonicalises on save, so `pt_br` and `pt-BR` are one row
    // there and would be two different strings in the comparison below.
    final String languageCode = canonicalizeOrKeep(rawLanguageCode);
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

    try {
      await client.addLanguage(projectId, f.id, languageCode,
          autoTranslate: autoTranslate);
    } on ApiException catch (e) {
      // `--auto-translate` fills every existing key in one server-side pass, so
      // the request can outlive the socket on a project with thousands of rows.
      // The retry then reaches a locale the first attempt already created, and
      // reporting that as a failure would be exactly backwards: the work
      // succeeded. Fall through to the verify below, which reads the truth.
      final String detail =
          '${e.message} ${e.body ?? ''}'.toLowerCase();
      final bool alreadyExists =
          e.statusCode == 400 && detail.contains('already exists');
      if (!alreadyExists) rethrow;
    }

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
    final String rawLanguageCode, {
    final bool dryRun = false,
  }) async {
    final String languageCode = canonicalizeOrKeep(rawLanguageCode);
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
