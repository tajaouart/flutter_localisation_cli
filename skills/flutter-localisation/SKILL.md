---
name: flutter-localisation
description: Manage the translations of a Flutter or native iOS app that uses FlutterLocalisation (flutterlocalisation.com, the `flutter_localisation` package, the `fl` CLI or the `fl_mcp` MCP server). Use when adding, editing, translating or deleting strings, adding a language, pulling ARBs, wiring live (over-the-air) translation updates, or when gen-l10n breaks after a Flutter upgrade (`package:flutter_gen` not found, `synthetic-package`, a missing generate flag, Material widgets showing English on `material_ui`).
---
# FlutterLocalisation

## Contents
- [How the pieces fit](#how-the-pieces-fit)
- [Rules](#rules)
- [Workflow: First setup](#workflow-first-setup)
- [Workflow: Add or change strings](#workflow-add-or-change-strings)
- [Workflow: Add a language](#workflow-add-a-language)
- [Workflow: Fix the setup after a Flutter upgrade](#workflow-fix-the-setup-after-a-flutter-upgrade)
- [Workflow: Live updates](#workflow-live-updates)
- [Workflow: Native declarations and iOS permission alerts](#workflow-native-declarations-and-ios-permission-alerts)

## How the pieces fit

Strings live in the FlutterLocalisation backend. The backend generates the ARB files (and iOS String Catalogs) and pushes them to a git repository linked to the project. The app reads them through gen-l10n and the `flutter_localisation` package.

```
fl / fl_mcp -> backend stores and AI-translates -> backend pushes ARBs to git
                                                        |
                         fl pull / fl sync  <-----------+ -> codegen -> context.tr.key
```

- `fl` is the CLI and `fl_mcp` the MCP server, both from `dart pub global activate flutter_localisation_cli`. They need a workspace token (`flk_live_...`) from the dashboard: `fl login --token ...` or `FL_API_TOKEN`.
- `flutter_localisation` is the runtime package the app depends on. It generates `lib/generated_translation_methods.dart` and, on paid plans, applies live updates at runtime.
- `flutterlocalisation.json` at the app root holds `project`, `flavor`, `arb_dir` (and optionally `xcstrings_dir`), so commands need no `--project`.

When the `fl_mcp` tools are available, prefer them to shelling out. Mutating tools only preview until called with `apply: true`.

When Dart's own MCP server (`dart mcp-server`) is also connected, use it to check the result: `analyze_files` after regenerating the Dart, `run_tests` before calling the work done. `fl_mcp` changes strings, the Dart server checks code; their tool names do not overlap.

## Rules

- **Never edit ARB files or generated Dart by hand.** The backend owns the ARB directory, `l10n.yaml`'s `output-dir` and `lib/generated_translation_methods.dart`. A direct edit is overwritten on the next sync. Change strings through `fl` or `fl_mcp`, then `fl pull` or `fl sync`. `fl guard` makes Claude Code and GitHub Copilot refuse those edits; run it once per project.
- **Bulk work costs one request, not one per key.** For more than a few keys write them into one ARB and run `fl import file.arb -t` (MCP: `import_arb`). Add several languages in one `fl languages add de fr it -t`. Never loop `fl add`, `fl edit`, `fl translate` or `fl languages add`: the backend rate-limits single-key writes and the CLI refuses the fourth single-key call within 15 minutes. A 429 means switch to the bulk command, not sleep and retry.
- **Never set `synthetic-package` in `l10n.yaml`** and never import `package:flutter_gen/gen_l10n/...`. Current Flutter rejects both. Import the generated file by its path in the app: `package:<app_name>/<output-dir minus lib/>/app_localizations.dart`.
- **Never commit a live update key** (`sk_live_...`). Pass it with `--dart-define`.
- Brand and product names belong in the glossary (`fl glossary add <Name> --keep`), URLs and code in locked keys (`fl lock <key>`), so the translator leaves them alone.

## Workflow: First setup

The project itself is created in the dashboard. Everything after that is the CLI.

- [ ] `dart pub global activate flutter_localisation_cli`
- [ ] `fl login --token flk_live_...` (or export `FL_API_TOKEN`).
- [ ] In the app root, run `fl init`. It picks the project and flavor, writes `flutterlocalisation.json`, pulls the ARBs and regenerates the Dart. Use `fl init -y --project "<name>"` when no human is answering prompts.
- [ ] Make sure `pubspec.yaml` has `flutter_localisation`, `flutter_localizations` (sdk), `intl` and `flutter: generate: true`.
- [ ] Run `fl doctor`. Fix anything it reports (see below).
- [ ] Run `fl guard`.
- [ ] Wire the app:

```dart
final service = TranslationService(config: TranslationConfig.freeUser());

MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Builder(
    builder: (context) => TranslationProvider(
      service: service,
      generatedLocalizations: AppLocalizations.of(context),
      child: const HomePage(),
    ),
  ),
);
```

Read strings with `context.tr.someKey`. `TranslationProvider` must sit below `MaterialApp` (it needs the generated localizations from the context).

## Workflow: Add or change strings

- [ ] One key: `fl add checkout_button --value "Buy now" -t` (MCP: `add_string` with `translate: true`). The `-t` AI-translates every other locale.
- [ ] Many keys: write them to one ARB in the base language, with `@key` metadata for placeholders, then `fl import new_keys.arb -t`. Preview with `--dry-run`.
- [ ] Fix one translation: `fl edit greeting --locale fr --value "Bonjour"`.
- [ ] Fill missing translations: `fl translate <key> --missing`, or `fl retranslate` for every locale.
- [ ] Bring the files in: `fl pull`, then regenerate, or `fl sync` to do both. `fl sync app_en.arb` imports, pulls and regenerates in one go.
- [ ] Use the key in code: `context.tr.checkoutButton`.
- [ ] Check: `fl status` shows completion per locale.

A pull refuses when a key exists only on disk. `fl pull --adopt` imports it first, along with the ARBs of the other languages beside the template; `--discard-local` drops it. `fl import app_en.arb` without `--language` imports as the language the file names (`@@locale`, else the file name), not as the base.

## Workflow: Add a language

- [ ] `fl languages add pt-BR -t` (several codes in one command). The backend fills every existing key.
- [ ] `fl sync` (or `fl pull` and regenerate).
- [ ] `fl native` so iOS and Android advertise the new language (see below).

## Workflow: Fix the setup after a Flutter upgrade

Symptoms: "AppLocalizations not found", `Target of URI doesn't exist: package:flutter_gen/...`, an error about `synthetic-package`, gen-l10n refusing to run, or Material widgets (date pickers, dialogs) in English on a `material_ui` app.

- [ ] `fl doctor` (MCP: `check_l10n_setup`). Offline, no token.
- [ ] `fl doctor --fix` removes `synthetic-package`, adds `generate: true`, and rewrites `package:flutter_gen` imports to the app's own path.
- [ ] It does not fix missing dependencies: add `flutter_localizations` (sdk) and `intl` yourself.
- [ ] On `material_ui`, gen-l10n's `AppLocalizations.localizationsDelegates` registers the old `flutter_localizations` delegates, and Material widgets get no localized strings. Replace it with the delegates from `material_ui`, and drop the `flutter_localizations` import (both export `GlobalMaterialLocalizations`):

```dart
import 'package:material_ui/material_ui.dart';

localizationsDelegates: [
  AppLocalizations.delegate,
  ...GlobalMaterialLocalizations.delegates,
],
```

- [ ] Run `fl doctor` again until it reports nothing, then `flutter analyze`.

An app still on `intl_utils` (a `flutter_intl:` section in `pubspec.yaml`, class `S`) has to move to gen-l10n first: follow https://flutterlocalisation.com/blog/migrate-intl-utils-flutter-intl-to-gen-l10n. Keep `output-class: S` so `S.of(context)` keeps working, replace `S.current`, and set `Intl.defaultLocale` in `MaterialApp.builder` or dates silently fall back to the system locale.

## Workflow: Live updates

Paid plans only. The app fetches changed strings at runtime, so a wording fix ships without a store release.

- [ ] Get the workspace's live update key (`sk_live_...`) and the numeric project id from the dashboard.
- [ ] Read them from the build, never from source:

```dart
const secretKey = String.fromEnvironment('FL_SECRET_KEY');
const projectId = int.fromEnvironment('FL_PROJECT_ID');

final service = TranslationService(
  config: TranslationConfig(
    secretKey: secretKey.isEmpty ? null : secretKey,
    projectId: projectId == 0 ? null : projectId,
    flavorName: 'Default',
    supportedLocales: const ['en', 'fr'],
  ),
);
await service.initialize();
```

- [ ] Build with `flutter run --dart-define=FL_SECRET_KEY=sk_live_... --dart-define=FL_PROJECT_ID=123`.
- [ ] An update rebuilds the widgets that read `context.tr`. `context.translations?.fetchAndApplyUpdates()` checks again on demand; `clearCache()` drops the overrides.

## Workflow: Native declarations and iOS permission alerts

The ARBs do not reach `CFBundleLocalizations` (the App Store "Languages" row), Android's `locales_config.xml` (the per-app language picker) or the iOS permission alerts (`NSCameraUsageDescription` and friends).

- [ ] `fl native --init-copy` once, to create `ios/Runner/InfoPlist.copy.json` from the current `Info.plist`. Translate the sentences in it per locale and commit it.
- [ ] `fl native` writes the declarations and `InfoPlist.strings` per language (MCP: `sync_native_locales`).
- [ ] Add `fl native --check` to CI. It exits 1 when anything is stale.
