# Changelog

## [1.8.0] - 2026-09-26
### Changed
- **`fl pull` is a sync, not a `git pull`.** The ARB directory is generated
  output the backend owns, so there is never a local contribution to
  reconcile — but the old command ran `git pull --rebase` inside it, and that
  made every bit of local state a blocker. An edited `app_en.arb` (which is
  exactly what the documented import flow tells you to create) stopped the
  pull with *"cannot pull with rebase: You have unstaged changes"*; a stale
  local commit turned it into a 36-file rebase conflict. Both ended with a
  user hand-running git inside a directory they are told never to hand-edit.
  `fl pull` now fetches and hard-resets onto the upstream branch, so neither
  can block it, and parks anything it discards under `refs/fl/pre-sync/<stamp>`
  — printed, so "it threw away my edit" always has an answer.
- **`fl pull` falls back to the API when git cannot deliver.** The clone is
  authenticated by whatever ambient git credential is active, so the wrong
  logged-in account, no credential helper, or a repo that was never linked all
  surfaced the same way: `remote: Repository not found`, and a dead end —
  while the same ARBs sat behind the API token the CLI already holds. A
  missing git binary, a plain directory, a missing remote and an unreachable
  remote now all fail over to writing the files from the API, and say so.
  Git also runs with `GIT_TERMINAL_PROMPT=0`, so a credential prompt can never
  hang the command (or raise a GUI keychain dialog) instead of failing.
- **`fl export` writes exactly what the backend pushes.** It used to put `@key`
  metadata in the template only and omit `@@last_modified`, so the first
  fallback export rewrote all 36 locale files: a 19,575-line diff that was
  pure formatting. The two writers now agree byte for byte, and an unchanged
  locale keeps its existing timestamp, so re-running an export is a no-op in
  git. (The backend's own writer gained the trailing newline that was the last
  byte of difference.)

### Added
- **`fl sync [<file.arb>]`** — import, pull, and regenerate the Dart in one
  command. Every consuming repo was documenting the same three steps in its
  own words, which meant every repo also documented its own way of getting
  them wrong.
- **A guard against losing keys that exist only on disk.** Both refresh paths
  rewrite the template from the service, so a key staged by hand for an import
  that never ran would disappear — this is how eight onboarding keys were lost
  in one repo, and why that repo's CLAUDE.md carried a "never run `fl export`
  here" rule. `fl pull` and `fl export` now name those keys and refuse;
  `fl pull --adopt` imports them first, `--discard-local` takes the service
  copy on purpose. The rule can go.
- **MCP `pull_arbs`.** The server used to tell the agent to ask the user to run
  `fl pull` — the step most likely to be skipped, by the party that just wrote
  the strings. The tool carries the same guard, the same fallback and the same
  preview/apply split as the CLI, and the server instructions now say plainly
  that git is never to be run in the ARB directory.

## [1.7.0] - 2026-08-26
### Added
- **The loop is refused, and the refusal names the command to run instead.**
  A caller that runs a bulk-capable command one target at a time is stopped on
  the fourth such call in 15 minutes (`lib/src/call_budget.dart`), with the
  runnable bulk form printed. The ledger is on disk, not in memory: every `fl`
  run is a fresh VM, so an in-process counter sees exactly one call and never
  fires — the loop is only visible across processes. The guard sits below
  `Operations`, so the CLI and the MCP server inherit it from one place; a guard
  only the CLI enforced would be one an agent routes around by calling the MCP
  tool. A *wide* call is never refused, and clears the history — penalising the
  correct command is the one outcome worse than not guarding at all.
- **`fl languages add` takes many codes.** `fl languages add ja ko th
  --auto-translate` walks the list in a single command, orders base languages
  before their script/region variants (`zh` before `zh-Hant`, which the backend
  requires and which callers previously had to rediscover by hitting the error),
  and stops on the first throttle instead of collecting one 429 per locale. The
  MCP `add_language` tool takes `codes: []` to match; the singular `code`
  remains for a genuine one-off.

- **`fl export`** — write every locale's ARB straight from the API. `clone`/
  `pull` only work when the dashboard has a git provider linked *and* the
  repository it names exists; when it does not, a project can be fully
  translated while the app still ships one language, and nothing in the tool
  could close the gap. This is the dashboard's Export, from the terminal. The
  ARBs are still the backend's data — `@@locale` matches the file name (gen_l10n
  aborts the build when they disagree) and `@key` metadata goes in the template
  only.
- **`POST /api/translations/bulk-check/`** and `bulkCheckTranslations`, removing
  the last per-row loop in the pipeline — and the worst one. `--accept-unchanged`
  walked every identical-to-source row through `update_translation`, which
  regenerates and git-pushes every ARB per call: ~1,400 requests and ~1,400 ARB
  pushes for one pass, an hour of wall clock. Now one request. It also fixes a
  dead end: a row missing a plural case its locale requires could not be marked
  checked *at all*, because the single-row serializer revalidated the whole row
  and rejected an update touching nothing but the flag — so those rows were
  re-translated on every run for ever.

### Removed
- **`fl retranslate --chunk-size`.** It read as a tuning knob and behaved as a
  quota multiplier: lowering it eightfold to clear one gateway timeout turned a
  33-locale repair into ~260 requests. Chunking is now adaptive — a timeout
  halves the batch and retries, down to a 100-row floor. The machine can see the
  timeout; a human reading a help string cannot see the request count they just
  signed up for.

### Notes
- Prompted by a real incident on 26 Aug 2026: an agent localising a Flutter app
  into 36 locales ran `fl languages add <code>` 34 times and `fl retranslate
  --locale <one> --chunk-size 200` 33 times, and drained a 1000/day budget in
  under an hour. Every request was valid; only the shape was wrong. The existing
  `SingleKeyWriteThrottle` did not cover these doors. The backend now throttles
  them too (`localization/api/throttles.py`), so the wall holds even for a
  client that has not been updated.

## [1.6.0] - 2026-08-23
### Added
- **`fl native` — declare the app's locales to iOS and Android, and translate
  the iOS permission alerts.** The ARBs only cover the UI. Three things sit
  outside them and rot silently, because nothing at runtime notices when they
  are wrong: `CFBundleLocalizations` (absent, iOS reads the bundle as
  English-only and the App Store Languages row says so — a 31-language app
  advertised one), `res/xml/locales_config.xml` (absent, Android never offers a
  per-app language), and the `NS*UsageDescription` strings, which iOS draws
  itself from the bundle before the Dart isolate exists and which therefore no
  `context.tr` can ever reach. The command generates all three from the locales
  the project already ships, writes one `<code>.lproj/InfoPlist.strings` per
  language and registers it with the Xcode target — an unregistered resource is
  never copied into the bundle, which is indistinguishable from never having
  translated it. `--check` fails on drift for CI, `--dry-run` previews,
  `--init-copy` scaffolds the copy file. Offline and tokenless: a drift check
  should not need credentials.
- **`sync_native_locales` MCP tool**, the same thing for Claude, preview-by-
  default like every other mutating tool.

### Notes
- The permission sentences live in `<ios-target>/InfoPlist.copy.json`, not on
  the dashboard: they never reach Dart, so the ARB pipeline would add a
  round-trip and buy nothing. A locale with no entry is a hard failure, not a
  silent fallback to the development language — a fluent alert in the wrong
  language reads as finished and ships.
- iOS spellings are handled: `fil` beside `tl`, `zh-Hans`/`zh-Hant` instead of a
  bare `zh` that modern iOS will not match, and an exact locale always beats the
  expansion that would otherwise shadow it (Traditional Chinese was the case
  that mattered).

## [1.5.0] - 2026-08-22
### Fixed
- **Regional and script locales are handled as one identity.** Locale codes
  arrived as whatever was typed, so `fl languages add pt_br` compared `pt_br`
  against the project's `pt-BR`, found no match, and asked the API to create a
  locale that already existed. Every locale argument is now canonicalised to
  BCP-47 (`pt_br` / `PT-BR` → `pt-BR`, `zh_hant` → `zh-Hant`, `es_419`
  unchanged) before it is compared or sent. Junk is passed through untouched so
  the API's own error still names the field.
- **The ARB uploaded by `import` carries the filename gen_l10n reads.** A
  variant produced `app_pt-BR.arb`, which Flutter's generator does not pick up
  at all; it is now `app_pt_BR.arb`.
- **`add --auto-translate` no longer reports a success as a failure.** The
  server-side fill of a large project can outlive the socket, and the retry then
  reached a locale the first attempt had already created. That 400 is now
  followed by the same verify-and-report read as the happy path.
- **A rejected request shows the server's own reason.** Errors carrying `error`
  rather than `message`/`detail` printed "POST /api/... failed" while the
  server had said exactly what was wrong.

## [1.4.0] - 2026-08-20
### Changed
- **A value that comes back identical to its source is no longer reported as a
  failure.** It is almost always the correct answer — "OK", "Premium", "Normal",
  "Start", French *Nature*, German *Name* — and calling it a failure cost more
  than tidiness. It trained readers to skip the number; it hid the genuine
  errors sitting in the same count; and because identical-to-source is
  `retranslate`'s *selection* criterion, it left those rows queued to be
  re-translated and re-reported on every run for ever. `translate`, `add`,
  `import` and `retranslate` now report `translated` / `failed` / `unchanged`
  separately, and only a real error affects the exit code.
- **The backend's own per-row reasons are printed instead of summed.** A count
  of failures cannot distinguish a malformed plural row from a dead service;
  the reason string can, and it was already being parsed and then discarded.
  This applies to the whole-batch rejection path too, where the detail lives in
  `results.failed` behind a top-level "All translations failed."

### Added
- **`fl retranslate --accept-unchanged`** (`accept_unchanged` on MCP) marks every
  value that came back identical to its source as checked, which `status` and
  `retranslate` already honour. This is what makes the queue closable: nothing
  in the pipeline previously *set* checked, so a deliberately-identical row
  could never leave the work list. Reviewers can flip any of them back with
  `fl edit --no-checked`.
- **`fl edit` gained the plural fields**: `--singular-case`, `--plural-case`,
  `--zero-case`, `--two-case`, `--few-case`, `--many-case`, `--plural-param`,
  `--plural`. The backend stores plural cases separately and rejects a
  `--value` carrying the placeholder, so a bad plural translation previously
  could not be repaired from the terminal at all.
- **The client models every CLDR plural category.** It had `zero`, `one`
  (`singular_case`) and `other` (`plural_case`) only — no `two`, `few` or
  `many`. French, Spanish, Italian, Portuguese, Polish and Czech all require
  `many`; Polish and Czech also require `few`; Arabic requires `two`. Because
  the backend re-validates the *whole* row on any write, a row missing a
  category its locale requires could not be saved at all — not even an update
  touching nothing but `is_checked`. Those rows were unfixable through the CLI
  and unexplainable from its output, since the reason was being discarded.

### Fixed
- **`import --translate` no longer reports a successful import as a total
  failure.** The import is written before the translate phase runs, so a
  timeout there — the likeliest outcome for a large import, and the one that
  actually happened with 837 keys — surfaced as a bare `Error: Gateway
  Time-out` from a run whose keys were all safely created. Nothing said the
  keys were in, and nothing named the one-command remedy. It now reports what
  was imported, what failed, and points at `fl retranslate`, which chunks and
  therefore survives what one large request does not.
- **A whole-batch 400 whose rows are all identical-to-source no longer aborts
  the run.** "Every row in the chunk failed" is a 400 rather than a 207, and it
  is the *normal* outcome once the only gap left is loanwords — so a project in
  exactly that state could never complete a run, and therefore could never
  reach `--accept-unchanged` to get out of it. A rejection carrying no per-row
  detail is still fatal, so a genuine outage is not absorbed.

## [1.3.0] - 2026-07-31
### Added
- **`fl guard` now teaches, not just blocks.** Alongside the `.claude/settings.json`
  deny rules, it writes an AI-guidance block into `AGENTS.md` and `CLAUDE.md` in the
  consuming repo, stating that the FlutterLocalisation SaaS is the source of truth
  and showing the correct `fl add` / `fl edit` / `fl pull` workflow. A bare write
  refusal made agents route *around* the guard (writing the string elsewhere); the
  docs turn the block into an instruction. The block is delimited by
  `<!-- fl:guard:start/end -->` markers and refreshed idempotently, so a project's
  own notes in those files are preserved.
- **MCP server advertises `instructions` on `initialize`.** Any AI client connecting
  to `fl_mcp` now receives top-level guidance (SaaS is authoritative, never hand-edit
  ARBs, mutate via tools then `fl pull`, preview-before-apply) before it calls a tool.

## [1.2.1] - 2026-07-21
### Fixed
- **`import --language <code>` now writes ONLY that locale.** It was sending
  `apply_to_all_languages=true` regardless, so a targeted per-locale import
  clobbered every other language with the file's values. A base-language import
  (no `--language`) still seeds all locales so fresh keys stay translatable.

## [1.2.0] - 2026-07-21
### Added
- **ARB `@key` metadata now round-trips through the API.** `add` / `fl add` and
  `add_string` (MCP) gained `--placeholder name:type[:format]` (repeatable) and
  `--description`, so a key can be created with typed placeholders (e.g.
  `count:int:decimalPattern`) and an ICU `@key.description`. `edit` / `fl edit`
  and `edit_string` (MCP) gained `--description`. `TranslationEntry` now reads
  `description` + `placeholders` back from the backend.

### Fixed
- **`edit_string` (MCP) no longer drops placeholders.** The edit dispatch
  previously omitted placeholder metadata entirely; it now forwards
  `placeholders` + `is_placeholders_enabled` alongside the new `description`.

## [1.1.0] - 2026-07-14
### Fixed
- **`--translate` no longer over-reports success.** `add` / `translate` /
  `import --translate` trusted the backend's `success_count`, which counts
  `source == output` as translated (a silent false success). The CLI now
  re-fetches after translating and flags any locale whose value still equals its
  key's non-empty base text as **failed**, so `translated N/N` never lies.
  `import --translate`'s `failed` field is now a list (matching `add`/`translate`).

### Added
- **Bulk ARB import — `import_arb` MCP tool + `fl import` CLI command.** Instead of many
  per-key `add_string` / `fl add` calls, put all strings in an ARB JSON and import it in a
  single request (`path` to a file or inline `content` for the MCP tool; `fl import <file.arb>`
  for the CLI). `translate=true` / `-t` then batch-translates the other locales in one pass;
  `overwrite`/`--overwrite` replaces existing values; `--language <code>` sets the file's
  locale (default: base). Preview by default (`apply=true` / no `--dry-run` to write). Backed
  by `ManagementClient.importArb()` (multipart to `/api/project/{id}/import-arb/`) and
  `Operations.importArb()`. Requires a `strings:write` token.
- **`fl guard` command — lock the backend-managed files against AI edits.** Writes
  `permissions.deny` rules into the project's `.claude/settings.json` so Claude Code
  refuses to `Edit`/`Write` the ARB directory (`arb_dir` + `l10n.yaml` `arb-dir`/`output-dir`)
  and `lib/generated_translation_methods.dart` — files that only ever change via the SaaS
  tooling + `git pull`, and whose hand-edits are otherwise silently overwritten on the next
  sync. Idempotent; merges into existing settings; `--dry-run` previews.

## [1.0.1] - 2026-07-14
### Fixed
- **`fl_mcp` now finds the token from `fl login`.** It previously read only
  `$FL_API_TOKEN` and ignored `~/.config/flutterlocalisation/credentials.json`,
  forcing users to duplicate the token into their MCP client config. It now uses
  the same resolution as the `fl` CLI (explicit → `$FL_API_TOKEN` → credentials
  file). `Credentials.resolve` gained an injectable `credentialsFile` for tests.

## [1.0.0] - 2026-07-07
### Added
- Initial release. The `fl` CLI and `fl_mcp` MCP server, extracted from the
  `flutter_localisation` package into a standalone **pure-Dart** package so they can be
  installed and run without the Flutter SDK (`dart pub global run` now works, and the runtime
  library no longer carries CLI dependencies).
- `fl` commands: `login`, `projects`, `add` (`--translate`), `edit`, `delete`, `translate`,
  `status`, `pull`; global `--project`, `--flavor`, `--config`, `--dry-run`, `--json`.
- `fl_mcp`: stdio MCP server exposing `list_projects`, `list_status`, `add_string`,
  `edit_string`, `delete_string`, `translate_key` — preview-by-default (only writes with
  `apply: true`), project selection by name.
- Auth via a scoped `flk_live_` API token; project config file is optional (workspace-level
  commands and `--project <name>` work token-only).
