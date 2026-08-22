/// Locale identity for the CLI: the same canonical BCP-47 rules the backend
/// applies in `localization/locales.py`.
///
/// Both ends have to agree on the spelling or the client and the server end up
/// holding different rows for one locale. The CLI's own failure was narrower
/// but just as real: locale codes arrived here as whatever the user typed, so
/// `fl languages add pt_br` compared `pt_br` against the project's `pt-BR`,
/// found no match, and asked the API to create a locale that already existed.
library;

/// language[-Script][-REGION] — `pt`, `pt-BR`, `zh-Hant`, `es-419`.
final RegExp _codePattern = RegExp(
  r'^([A-Za-z]{2,3})(?:[-_]([A-Za-z]{4}))?(?:[-_]([A-Za-z]{2}|\d{3}))?$',
);

/// Thrown when a string cannot be read as a locale code.
class InvalidLocaleCode implements Exception {
  InvalidLocaleCode(this.code);

  final String code;

  @override
  String toString() =>
      'InvalidLocaleCode: "$code" is not a locale code. '
      "Expected forms: 'fr', 'pt-BR', 'zh-Hant', 'es-419'.";
}

/// Normalise any accepted spelling to canonical BCP-47.
///
/// `pt_br` / `PT-BR` / `pt-br` -> `pt-BR`, `zh_hant` -> `zh-Hant`.
String canonicalize(final String code) {
  final RegExpMatch? match = _codePattern.firstMatch(code.trim());
  if (match == null) throw InvalidLocaleCode(code);

  final StringBuffer out = StringBuffer(match.group(1)!.toLowerCase());
  final String? script = match.group(2);
  if (script != null) {
    out
      ..write('-')
      ..write(script[0].toUpperCase())
      ..write(script.substring(1).toLowerCase());
  }
  final String? region = match.group(3);
  if (region != null) {
    out
      ..write('-')
      ..write(int.tryParse(region) != null ? region : region.toUpperCase());
  }
  return out.toString();
}

/// Canonical form, or the input untouched when it is not a locale code.
///
/// Used on paths that must not fail on junk: rejecting it is the API's job,
/// and its error message names the field, which a client-side throw would not.
String canonicalizeOrKeep(final String code) {
  try {
    return canonicalize(code);
  } on InvalidLocaleCode {
    return code;
  }
}

/// Filename suffix `gen_l10n` expects: `pt-BR` -> `pt_BR`, for `app_pt_BR.arb`.
///
/// Hyphens are what BCP-47 uses and underscores are what the Dart tooling
/// reads; a file named `app_pt-BR.arb` is not picked up by `gen_l10n` at all.
String arbSuffix(final String code) => canonicalizeOrKeep(code).replaceAll('-', '_');
