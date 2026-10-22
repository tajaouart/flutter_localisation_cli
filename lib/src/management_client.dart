/// Management API client — the shared core for the CLI and the MCP server.
///
/// Mirrors exactly what the dashboard does: add key, edit translation (value / plural /
/// placeholders), delete translation, AI-translate (persisted via batch), and read the
/// project to resolve `(key, locale) → translation_id`.
///
/// Pure Dart (`dart:io` + `http`), no Flutter imports — runs under `dart run`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show stderr;

import 'package:http/http.dart' as http;

import 'package:flutter_localisation_cli/src/exceptions.dart';
import 'package:flutter_localisation_cli/src/locales.dart';

// --------------------------------------------------------------------------- //
// Data models
// --------------------------------------------------------------------------- //

class TranslationEntry {
  TranslationEntry({
    required this.id,
    required this.key,
    required this.value,
    required this.isChecked,
    required this.isPluralEnabled,
    required this.isAiTranslated,
    this.description = '',
    this.placeholders = const <String, dynamic>{},
  });

  final int id;
  final String key;
  final String value;
  final bool isChecked;
  final bool isPluralEnabled;
  final bool isAiTranslated;

  /// Key description (`@key.description` in ARB). Round-tripped from the backend.
  final String description;

  /// Placeholder metadata (`@key.placeholders`): `{name: {type, format?}}`.
  final Map<String, dynamic> placeholders;

  bool get isEmpty => value.trim().isEmpty && !isPluralEnabled;

  factory TranslationEntry.fromJson(final Map<String, dynamic> j) => TranslationEntry(
        id: j['id'] as int,
        key: (j['key'] ?? '') as String,
        value: (j['value'] ?? '') as String,
        isChecked: (j['is_checked'] ?? false) as bool,
        isPluralEnabled: (j['is_plural_enabled'] ?? false) as bool,
        isAiTranslated: (j['is_ai_translated'] ?? false) as bool,
        description: (j['description'] ?? '') as String,
        placeholders:
            (j['placeholders'] ?? const <String, dynamic>{}) as Map<String, dynamic>,
      );
}

class LanguageData {
  LanguageData({
    required this.id,
    required this.code,
    required this.isBase,
    required this.translations,
  });

  /// Server id of the flavor-language row — what `/api/delete-language/<id>/`
  /// addresses. Defaults to 0 for payloads that omit it (older fixtures).
  final int id;
  final String code;
  final bool isBase;
  final List<TranslationEntry> translations;

  factory LanguageData.fromJson(final Map<String, dynamic> j) => LanguageData(
        id: (j['id'] ?? 0) as int,
        code: (j['code'] ?? '') as String,
        isBase: (j['is_base_language'] ?? false) as bool,
        translations: ((j['translations'] ?? const <dynamic>[]) as List)
            .map((final e) => TranslationEntry.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class FlavorData {
  FlavorData({required this.id, required this.name, required this.languages});

  final int id;
  final String name;
  final List<LanguageData> languages;

  factory FlavorData.fromJson(final Map<String, dynamic> j) => FlavorData(
        id: (j['id'] ?? 0) as int,
        name: (j['name'] ?? '') as String,
        languages: ((j['languages'] ?? const <dynamic>[]) as List)
            .map((final e) => LanguageData.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// The git repo the backend pushes generated ARBs to, as configured in the
/// dashboard (Project → Git).
///
/// This is the repo you clone into `arb_dir`; the backend is the only writer.
/// Exactly one provider can be linked at a time, so [url] is the linked one.
class GitRepository {
  GitRepository({
    required this.provider,
    required this.url,
    this.needsReauth = false,
  });

  /// `github`, `gitlab`, `bitbucket` or `bitbucket_server`.
  final String provider;
  final String url;

  /// True when the backend's git token is dead and must be reconnected in the
  /// dashboard — ARB pushes are failing, so a `pull` won't see new strings.
  final bool needsReauth;

  /// Reads the `is_<provider>_linked` / `<provider>_repository_url` pairs the
  /// project detail endpoint returns, and picks the linked one. Returns null
  /// when no provider is linked (nothing to clone yet).
  static GitRepository? fromProjectJson(final Map<String, dynamic> j) {
    const Map<String, String> providers = <String, String>{
      'github': 'github',
      'gitlab': 'gitlab',
      'bitbucket': 'bitbucket',
      'bitbucket_server': 'bitbucket_server',
    };
    for (final MapEntry<String, String> p in providers.entries) {
      final bool linked = (j['is_${p.key}_linked'] ?? false) as bool;
      final String? url = j['${p.key}_repository_url'] as String?;
      if (linked && url != null && url.isNotEmpty) {
        return GitRepository(
          provider: p.value,
          url: url,
          needsReauth: (j['git_needs_reauth'] ?? false) as bool,
        );
      }
    }
    return null;
  }
}

/// The `platforms` list a project JSON carries, defaulting to Flutter.
///
/// Every project that predates the field is a Flutter project, and a backend
/// that predates it omits the field altogether, so absence means Flutter.
List<String> platformsFromJson(final Object? raw) {
  if (raw is! List) return const <String>['flutter'];
  final List<String> found = raw.whereType<String>().toList();
  return found.isEmpty ? const <String>['flutter'] : found;
}

class ProjectData {
  ProjectData({
    required this.id,
    required this.name,
    required this.flavors,
    this.repository,
    this.platforms = const <String>['flutter'],
    this.xcstringsDir = '',
  });

  final int id;
  final String name;
  final List<FlavorData> flavors;

  /// The linked ARB repo, or null when the dashboard has no git provider set up.
  final GitRepository? repository;

  /// What consumes the strings: `flutter` (ARBs) and/or `ios` (String
  /// Catalogs). Decides which files `pull` and `export` write.
  final List<String> platforms;

  /// Folder of the catalogs inside the git mirror; empty means `<flavor>/`.
  final String xcstringsDir;

  bool get shipsFlutter => platforms.contains('flutter');
  bool get shipsIos => platforms.contains('ios');

  factory ProjectData.fromJson(final Map<String, dynamic> j) => ProjectData(
        id: j['id'] as int,
        name: (j['name'] ?? '') as String,
        repository: GitRepository.fromProjectJson(j),
        platforms: platformsFromJson(j['platforms']),
        xcstringsDir: (j['xcstrings_dir'] ?? '') as String,
        flavors: ((j['flavors'] ?? const <dynamic>[]) as List)
            .map((final e) => FlavorData.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  /// Choose a flavor by [name]; if null and exactly one flavor exists, use it.
  FlavorData flavor(final String? name) {
    if (name != null) {
      return flavors.firstWhere(
        (final FlavorData f) => f.name == name,
        orElse: () => throw ResolveException(
          'Flavor "$name" not found. Available: ${flavors.map((final FlavorData f) => f.name).join(", ")}.',
        ),
      );
    }
    if (flavors.length == 1) return flavors.first;
    throw ResolveException(
      'Multiple flavors exist (${flavors.map((final FlavorData f) => f.name).join(", ")}); '
      'specify one with --flavor.',
    );
  }

  LanguageData? baseLanguage(final String? flavorName) {
    final FlavorData f = flavor(flavorName);
    for (final LanguageData l in f.languages) {
      if (l.isBase) return l;
    }
    return f.languages.isEmpty ? null : f.languages.first;
  }

  /// Resolve `(key, locale) → translation id` within a flavor.
  int resolveId(final String key, final String locale, {final String? flavorName}) {
    final FlavorData f = flavor(flavorName);
    final LanguageData lang = f.languages.firstWhere(
      (final LanguageData l) => l.code == locale,
      orElse: () => throw ResolveException(
        'Locale "$locale" not found in flavor "${f.name}".',
      ),
    );
    final TranslationEntry entry = lang.translations.firstWhere(
      (final TranslationEntry t) => t.key == key,
      orElse: () =>
          throw ResolveException('Key "$key" not found for locale "$locale".'),
    );
    return entry.id;
  }

  /// All `(locale, id)` pairs for [key] in a flavor (every locale).
  List<({String locale, int id, bool empty})> entriesForKey(
    final String key, {
    final String? flavorName,
  }) {
    final FlavorData f = flavor(flavorName);
    final List<({String locale, int id, bool empty})> out = <({bool empty, int id, String locale})>[];
    for (final LanguageData l in f.languages) {
      for (final TranslationEntry t in l.translations) {
        if (t.key == key) {
          out.add((locale: l.code, id: t.id, empty: t.isEmpty));
        }
      }
    }
    return out;
  }
}

/// The per-row failures carried on a batch response body, if it has any.
///
/// The batch endpoint answers 400 — not 207 — when *every* row in the chunk
/// failed, and the interesting detail is still in `results.failed`. A caller
/// that only sees the thrown top-level message ("All translations failed.")
/// cannot tell a dead service from a chunk that happened to be all loanwords.
///
/// `translation_id` is null on some of these rows, so an entry is not always
/// attributable to a specific translation; callers must handle a null id
/// rather than assume one.
List<({int? id, String error})> batchRowErrorsFrom(
  final Map<String, dynamic>? body,
) {
  final Object? results = body?['results'];
  if (results is! Map<String, dynamic>) return const <({int? id, String error})>[];
  final Object? failed = results['failed'];
  if (failed is! List) return const <({int? id, String error})>[];
  return <({int? id, String error})>[
    for (final Object? row in failed)
      if (row is Map<String, dynamic>)
        (id: row['translation_id'] as int?, error: (row['error'] ?? '') as String),
  ];
}

class BatchTranslateResult {
  BatchTranslateResult({
    required this.status,
    required this.successCount,
    required this.failedCount,
    required this.failed,
  });

  final String status; // success | partial | error
  final int successCount;
  final int failedCount;
  final List<({int id, String error})> failed;

  factory BatchTranslateResult.fromJson(final Map<String, dynamic> j) {
    final Map<String, dynamic> r =
        (j['results'] ?? const <String, dynamic>{}) as Map<String, dynamic>;
    return BatchTranslateResult(
      status: (j['status'] ?? 'success') as String,
      successCount: (r['success_count'] ?? 0) as int,
      failedCount: (r['failed_count'] ?? 0) as int,
      failed: ((r['failed'] ?? const <dynamic>[]) as List)
          .map((final e) => (
                id: (e['translation_id'] ?? 0) as int,
                error: (e['error'] ?? '') as String,
              ),)
          .toList(),
    );
  }
}

/// A lightweight project entry from `GET /api/projects/` (no translations).
class ProjectSummary {
  ProjectSummary({
    required this.id,
    required this.name,
    required this.workspace,
    required this.flavors,
    this.gitNeedsReauth = false,
    this.platforms = const <String>['flutter'],
  });

  final int id;
  final String name;
  final String workspace;
  final List<FlavorSummary> flavors;

  /// True when the backend's git provider token is dead and needs reconnecting in the
  /// dashboard — ARB pushes are failing, so `pull` won't see new strings.
  final bool gitNeedsReauth;

  /// `flutter` and/or `ios`; see [ProjectData.platforms].
  final List<String> platforms;

  factory ProjectSummary.fromJson(final Map<String, dynamic> j) =>
      ProjectSummary(
        id: j['id'] as int,
        name: (j['name'] ?? '') as String,
        workspace: (j['workspace'] ?? '') as String,
        gitNeedsReauth: (j['git_needs_reauth'] ?? false) as bool,
        platforms: platformsFromJson(j['platforms']),
        flavors: ((j['flavors'] ?? const <dynamic>[]) as List)
            .map((final e) =>
                FlavorSummary.fromJson(e as Map<String, dynamic>),)
            .toList(),
      );
}

class FlavorSummary {
  FlavorSummary({
    required this.name,
    required this.baseLanguage,
    required this.languages,
  });

  final String name;
  final String? baseLanguage;
  final List<String> languages;

  factory FlavorSummary.fromJson(final Map<String, dynamic> j) => FlavorSummary(
        name: (j['name'] ?? '') as String,
        baseLanguage: j['base_language'] as String?,
        languages: ((j['languages'] ?? const <dynamic>[]) as List)
            .map((final e) => e as String)
            .toList(),
      );
}

// --------------------------------------------------------------------------- //
// Client
// --------------------------------------------------------------------------- //

class ManagementClient {
  ManagementClient({
    required this.baseUrl,
    required this.token,
    final http.Client? httpClient,
    this.maxRetries = 3,
  }) : _http = httpClient ?? http.Client();

  final String baseUrl;
  final String token;
  final int maxRetries;
  final http.Client _http;

  void close() => _http.close();

  Map<String, String> get _headers => <String, String>{
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      };

  Uri _uri(final String path) => Uri.parse('$baseUrl$path');

  /// List the projects (with flavors + locales) this token/user can access.
  Future<List<ProjectSummary>> listProjects() async {
    final http.Response res = await _send('GET', '/api/projects/');
    final List<dynamic> raw =
        (_json(res)['projects'] ?? const <dynamic>[]) as List<dynamic>;
    return raw
        .map((final dynamic e) =>
            ProjectSummary.fromJson(e as Map<String, dynamic>),)
        .toList();
  }

  /// GET the full project (structure + translation ids).
  Future<ProjectData> getProject(final int projectId) async {
    final http.Response res =
        await _send('GET', '/api/projects/$projectId/');
    return ProjectData.fromJson(_json(res));
  }

  /// Add a translation key with its base value. Idempotent server-side.
  ///
  /// Optional [placeholders] (`{name: {type, format?}}`), [isPlaceholdersEnabled]
  /// and [description] carry ARB `@key` metadata through to the backend. When the
  /// caller omits [placeholders] the backend auto-detects `{name}` tokens, so the
  /// fields are only sent when explicitly provided/non-empty (never clobber).
  Future<void> addKey(
    final int projectId,
    final String key,
    final String baseValue, {
    final Map<String, dynamic>? placeholders,
    final bool? isPlaceholdersEnabled,
    final String? description,
  }) async {
    final Map<String, dynamic> body = <String, dynamic>{
      'key': key,
      'base_value': baseValue,
      if (placeholders != null && placeholders.isNotEmpty)
        'placeholders': placeholders,
      if (isPlaceholdersEnabled != null)
        'is_placeholders_enabled': isPlaceholdersEnabled,
      if (description != null && description.isNotEmpty) 'description': description,
    };
    await _send(
      'POST',
      '/api/projects/$projectId/translation_keys/',
      body: body,
    );
  }

  /// Update a single translation. Only non-null fields are sent (partial update).
  ///
  /// Note that "partial" applies to what is *sent*, not to what is *validated*:
  /// the backend re-validates the whole row, so a row missing a plural case its
  /// locale requires rejects even an update that touches nothing but
  /// `is_checked`. That is why every CLDR category is settable here — without
  /// `many`, a French or Polish plural row cannot be completed, and therefore
  /// cannot be edited at all.
  /// Set `is_checked` on many rows in ONE request.
  ///
  /// The single-row path calls `generate_and_push_arb_files` per call, so
  /// accepting a run's loanword rows one at a time cost a request *and* a full
  /// ARB regeneration each — ~1,400 of both for one `--accept-unchanged` pass.
  /// Returns how many rows the backend actually updated.
  Future<int> bulkCheckTranslations(
    final List<int> ids, {
    final bool isChecked = true,
  }) async {
    if (ids.isEmpty) return 0;
    final http.Response res = await _send(
      'POST',
      '/api/translations/bulk-check/',
      body: <String, dynamic>{
        'translation_ids': ids,
        'is_checked': isChecked,
      },
    );
    final Map<String, dynamic> j = _json(res);
    return (j['updated'] as int?) ?? 0;
  }

  Future<Map<String, dynamic>> updateTranslation(
    final int translationId, {
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
  }) async {
    final Map<String, dynamic> body = <String, dynamic>{
      if (value != null) 'value': value,
      if (isPluralEnabled != null) 'is_plural_enabled': isPluralEnabled,
      if (zeroCase != null) 'zero_case': zeroCase,
      if (singularCase != null) 'singular_case': singularCase,
      // `singular_case` is CLDR `one` and `plural_case` is CLDR `other`; the
      // three below keep their CLDR names because there is no older alias to
      // stay compatible with. `many_case` is confirmed by the backend's own
      // validation message; `few_case` and `two_case` follow its naming.
      if (twoCase != null) 'two_case': twoCase,
      if (fewCase != null) 'few_case': fewCase,
      if (manyCase != null) 'many_case': manyCase,
      if (pluralCase != null) 'plural_case': pluralCase,
      if (pluralParam != null) 'plural_param': pluralParam,
      if (isPlaceholdersEnabled != null)
        'is_placeholders_enabled': isPlaceholdersEnabled,
      if (placeholders != null) 'placeholders': placeholders,
      if (description != null && description.isNotEmpty) 'description': description,
      if (isChecked != null) 'is_checked': isChecked,
    };
    final http.Response res =
        await _send('POST', '/api/update_translation/$translationId/', body: body);
    return _json(res);
  }

  /// Delete a single translation (one locale of a key).
  Future<void> deleteTranslation(final int translationId) async {
    await _send('DELETE', '/api/translations/$translationId/delete/');
  }

  /// Delete an entire key (all locales) by name — removes the TranslationKey itself,
  /// not just its translations.
  Future<void> deleteKey(final int projectId, final String key) async {
    await _send(
      'POST',
      '/api/projects/$projectId/translation_keys/delete/',
      body: <String, dynamic>{'key': key},
    );
  }

  /// Add a language to a flavor.
  ///
  /// With [autoTranslate] the backend AI-fills every EXISTING key for the new
  /// locale in one server-side pass, and keeps translating keys added later.
  /// That single call is what replaces walking the key list client-side, so it
  /// is the only sane way to populate a new locale.
  Future<Map<String, dynamic>> addLanguage(
    final int projectId,
    final int flavorId,
    final String languageCode, {
    final bool autoTranslate = false,
  }) async {
    final http.Response res = await _send(
      'POST',
      '/api/add-language/',
      body: <String, dynamic>{
        'project': projectId,
        'flavor': flavorId,
        'languageCode': languageCode,
        'autoTranslate': autoTranslate,
      },
    );
    return _json(res);
  }

  /// Remove a language (and its translations) from a flavor.
  Future<void> deleteLanguage(final int languageId) async {
    await _send('DELETE', '/api/delete-language/$languageId/');
  }

  /// AI-translate and persist a set of translations (uses the batch endpoint,
  /// which — unlike the single endpoint — saves).
  Future<BatchTranslateResult> aiBatchTranslate(final List<int> ids) async {
    final http.Response res = await _send(
      'POST',
      '/api/ai_batch_translate/',
      body: <String, List<int>>{'translation_ids': ids},
      // 207 (partial) is an expected, non-fatal outcome.
      acceptStatuses: const <int>{200, 207},
    );
    return BatchTranslateResult.fromJson(_json(res));
  }

  /// One String Catalog of a flavor, as the backend renders it.
  ///
  /// Returned as the raw body on purpose: the backend writes the file in
  /// Xcode's own formatting so a build does not rewrite it, and re-encoding
  /// here would undo that. [table] is `Localizable` or `InfoPlist`.
  Future<String> downloadCatalog(
    final int projectId,
    final int flavorId, {
    final String table = 'Localizable',
  }) async {
    final http.Response res = await _send(
      'GET',
      '/api/project/$projectId/export/?flavor_id=$flavorId&format=xcstrings'
      '&table=$table',
    );
    return utf8.decode(res.bodyBytes);
  }

  /// Bulk-create keys by importing a whole ARB file in ONE request (instead of
  /// N per-key adds). [arbContent] is the raw ARB JSON; [languageCode] is the
  /// locale the file represents (usually the base language). By default the keys
  /// are applied across all languages so translations can be batch-filled after.
  ///
  /// A String Catalog goes through the same endpoint with [languageCode] null:
  /// the file names its own source language and carries every locale.
  Future<Map<String, dynamic>> importArb(
    final int projectId,
    final int flavorId,
    final String? languageCode,
    final String arbContent, {
    final bool overwriteExisting = false,
    final bool applyToAllLanguages = true,
    final bool autoTranslate = false,
    final String? fileName,
  }) async {
    final Uri uri = _uri('/api/project/$projectId/import-arb/');
    const String path = '/api/project/.../import-arb/';

    int attempt = 0;
    while (true) {
      attempt++;
      http.Response res;
      try {
        final http.MultipartRequest req = http.MultipartRequest('POST', uri)
          ..headers['Authorization'] = 'Bearer $token'
          ..fields['flavor_id'] = flavorId.toString()
          ..fields['apply_to_all_languages'] = applyToAllLanguages.toString()
          ..fields['apply_to_all_flavors'] = 'false'
          ..fields['overwrite_existing'] = overwriteExisting.toString()
          // Server-side fill, so importing and translating are ONE round trip
          // and the client never has to rediscover which rows it just made.
          ..fields['auto_translate'] = autoTranslate.toString()
          ..files.add(http.MultipartFile.fromString(
            'arb_file',
            arbContent,
            filename: fileName ??
                (languageCode == null
                    ? 'Localizable.xcstrings'
                    : 'app_${arbSuffix(languageCode)}.arb'),
          ));
        if (languageCode != null) {
          req.fields['selected_language_code'] = languageCode;
        }
        final http.StreamedResponse streamed = await _http.send(req);
        res = await http.Response.fromStream(streamed);
      } catch (e) {
        if (attempt <= maxRetries) {
          await _backoff(attempt);
          continue;
        }
        throw ManagementException('Network error calling POST $path: $e');
      }

      // 200 = imported+pushed; 207 = imported but git push failed (still OK).
      if (res.statusCode == 200 || res.statusCode == 207) return _json(res);
      if ((res.statusCode == 429 || res.statusCode >= 500) &&
          attempt <= maxRetries) {
        await _backoff(attempt, retryAfter: res.headers['retry-after']);
        continue;
      }
      throw _errorFor('POST', path, res);
    }
  }

  // ------------------------------------------------------------------------- //
  // HTTP plumbing: retries + error mapping
  // ------------------------------------------------------------------------- //

  Future<http.Response> _send(
    final String method,
    final String path, {
    final Object? body,
    final Set<int> acceptStatuses = const <int>{200, 201, 204},
  }) async {
    final Uri uri = _uri(path);
    final String? encoded = body == null ? null : jsonEncode(body);

    int attempt = 0;
    while (true) {
      attempt++;
      http.Response res;
      try {
        final http.Request req = http.Request(method, uri)
          ..headers.addAll(_headers);
        if (encoded != null) req.body = encoded;
        final http.StreamedResponse streamed = await _http.send(req);
        res = await http.Response.fromStream(streamed);
      } catch (e) {
        if (attempt <= maxRetries) {
          await _backoff(attempt);
          continue;
        }
        throw ManagementException('Network error calling $method $path: $e');
      }

      if (acceptStatuses.contains(res.statusCode)) return res;

      // Retry transient failures.
      if ((res.statusCode == 429 || res.statusCode >= 500) &&
          attempt <= maxRetries) {
        await _backoff(attempt, retryAfter: res.headers['retry-after']);
        continue;
      }

      throw _errorFor(method, path, res);
    }
  }

  ApiException _errorFor(final String method, final String path, final http.Response res) {
    Map<String, dynamic>? parsed;
    String message;
    try {
      parsed = jsonDecode(res.body) as Map<String, dynamic>;
      // `error` is in the list because some endpoints use it and dropping it
      // left the caller with "POST /api/... failed" while the server had said
      // exactly what was wrong.
      message = (parsed['message'] ??
              parsed['detail'] ??
              parsed['error'] ??
              res.reasonPhrase ??
              '')
          .toString();
    } catch (_) {
      message = res.reasonPhrase ?? 'Request failed';
    }
    if (message.isEmpty) message = '$method $path failed';
    return ApiException(res.statusCode, message, body: parsed);
  }

  Map<String, dynamic> _json(final http.Response res) {
    if (res.body.isEmpty) return const <String, dynamic>{};
    final Object? decoded = jsonDecode(res.body);
    if (decoded is Map<String, dynamic>) return decoded;
    return <String, dynamic>{'data': decoded};
  }

  /// The longest we will sit on a `Retry-After` before giving up and telling
  /// the caller what is actually happening.
  ///
  /// DRF sends `Retry-After` with the *full* remaining throttle window, which
  /// for a drained daily cap can be 45+ minutes. Honouring that verbatim — as
  /// this used to — makes every command look like it hung: no output, no exit,
  /// nothing to distinguish "rate-limited for 45 minutes" from "the server
  /// stopped responding". A caller that knows it is throttled can retry later;
  /// a caller staring at a dead terminal cannot.
  static const Duration _maxRetryAfterWait = Duration(seconds: 90);

  Future<void> _backoff(final int attempt, {final String? retryAfter}) async {
    if (retryAfter != null) {
      final int? secs = int.tryParse(retryAfter);
      if (secs != null) {
        final Duration wait = Duration(seconds: secs);
        if (wait > _maxRetryAfterWait) {
          throw ManagementException(
            'Rate limited for another ${secs}s (${(secs / 60).ceil()} min) — '
            'not waiting it out.\n'
            'The daily request cap is spent. Re-run this command after that '
            'window, and prefer one bulk call (`fl import`, '
            '`fl languages add --auto-translate`) over looping single-key '
            'commands, which is what exhausts the cap.',
          );
        }
        stderr.writeln('Rate limited; retrying in ${secs}s…');
        await Future<void>.delayed(wait);
        return;
      }
    }
    // Exponential backoff: 0.4s, 0.8s, 1.6s ...
    await Future<void>.delayed(Duration(milliseconds: 200 * (1 << attempt)));
  }
}
