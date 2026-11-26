# flutter_localisation_cli

Terminal **CLI** (`fl`) and **MCP server** (`fl_mcp`) for
[FlutterLocalisation](https://flutterlocalisation.com) — add, edit, delete and AI-translate
your app's localization keys from the shell or from an AI agent (Claude, GitHub Copilot), then pull the ARBs. No dashboard
round-trip.

Pure Dart — no Flutter SDK required. This is the tooling companion to the
[`flutter_localisation`](https://pub.dev/packages/flutter_localisation) runtime package (which
your app depends on to load the ARBs). Strings live in the FlutterLocalisation backend; this
package changes them and the backend regenerates + pushes the ARBs to your git repo.

## Install

```bash
dart pub global activate flutter_localisation_cli
```

This installs the `fl` and `fl_mcp` executables in `~/.pub-cache/bin` (put that on your `PATH`).

Without Dart (an Angular or any JavaScript project), the same commands come as native binaries
from npm:

```bash
npm install --save-dev @flutterlocalisation/cli   # then: npx fl init
ng add @flutterlocalisation/angular                # an Angular app: also sets up @angular/localize
```

## Auth

Create a scoped API token in the dashboard → **API Keys** (`flk_live_…`), then either:

```bash
fl login --token flk_live_xxx      # stored in ~/.config/flutterlocalisation (chmod 600)
# or: export FL_API_TOKEN=flk_live_xxx     # or pass --token on each call
```

The token is **workspace-scoped**, so you pick projects by name — no numeric ids.

## First run: `fl init`

```bash
cd my_app
fl init
```

One wizard for a fresh checkout. It asks for the token if none is stored, lists the projects
the token sees (and the flavors, when there are several), prefills the folders from the
repository (`l10n.yaml` `arb-dir` for ARBs, an existing `Localizable.xcstrings` or the iOS
target folder for catalogs), writes `flutterlocalisation.json`, pulls the strings, regenerates
the Dart for a Flutter app, then offers `fl guard` and `fl native`. Every question has a
default; `fl init -y` takes them all, and `--project`, `--flavor`, `--arb-dir`,
`--xcstrings-dir` answer the ones that have no default. `--no-pull` only writes the config.
The project itself is still created in the dashboard: the token cannot do that.

### One project, several repositories

A project can ship to several platforms whose apps live in separate repositories: a website
in Angular and an iPhone app, say. Each repository has its own `flutterlocalisation.json`, and
its `platforms` says which of the project's platforms that repository holds:

```json
{
  "project": "Studio Posting",
  "project_id": 138,
  "platforms": ["ios"],
  "xcstrings_catalogs": ["App/Resources", "Widgets", "App/Posts/Posts.xcstrings"]
}
```

`fl pull`, `fl export`, `fl diff`, `fl status`, `fl sync`, `fl doctor`, the platform `fl import`
picks for an ARB, and the MCP tools `pull_arbs`, `import_arb` and `check_l10n_setup` then touch
the files of those platforms only: the iPhone app never gets `messages.<locale>.arb`, the
website never gets a String Catalog. Without `platforms`, a project with one platform works as
it always did; with several, the CLI reads them off the repository (`pubspec.yaml` with Flutter,
an `.xcodeproj` or `.xcstrings`, `angular.json` with `@angular/localize`, ngx-translate in
`package.json`), keeps those the project ships, and says once which ones it took and the line
that pins them. A repository that shows none of them gets no file at all until `platforms` is
set. `fl init` on such a project asks (`-y` takes what the repository shows, `--platforms ios`
answers) and writes `platforms` with the folder settings of those platforms only.

## CLI

```bash
fl init                                  # first run: token, project, folders, first pull
fl projects                              # list your projects (name, flavors, locales)
fl status --project "Chat Bot"           # completion % per locale
fl add greeting --value "Hello" -t       # add key + AI-translate every other locale
fl show greeting                                 # every locale, target texts, platforms, max lengths
fl edit greeting --locale fr --value "Bonjour"   # no --locale: the base language
fl edit done_body --locale fr --value "{arg1} en {arg2} s"   # catalog key by its stem
fl import strings.arb -t                 # bulk-create MANY keys from one ARB, then translate
fl translate greeting --missing          # fill only empty locales
fl languages                             # list locales + how many keys each has filled
fl languages add id -t                   # add a locale and AI-fill EVERY existing key
fl languages remove id                   # drop a locale and its translations
fl delete greeting                       # whole key (or --locale fr for one locale)
fl repo                                  # print the ARB git repo URL (from the dashboard)
fl clone                                 # first-time: clone that repo above arb_dir
fl pull                                  # sync arb_dir with the service (git or API)
fl sync app_en.arb                       # import, pull and regenerate the Dart, in one
fl guard                                 # stop AI agents editing ARBs + generated Dart
fl native                                # tell iOS + Android about the locales, translate
                                         # the iOS permission alerts
fl doctor --fix                          # fix a gen-l10n setup current Flutter refuses
fl glossary add Dictee --keep            # never translate the app's name
fl glossary add Snippets --as de=Schnipsel --as fr=Extraits
fl style set de --formal                 # Sie, never du (de-AT, de-CH follow)
fl style set --all --instructions "Never use a dash."   # one rule, every language
fl retranslate --changed                 # redo translations of strings you reworded
fl glossary apply                        # re-translate strings that use glossary terms
fl lock support_url                      # this key keeps the base text in every locale
fl edit paywall_title --target ios --value "Go Pro"   # iOS gets its own, shorter text
fl edit paywall_title --target ios --clear            # iOS gets the full text again
fl edit paywall_title --platforms ios --max-length ios=20   # ship to iOS only, 20 chars
fl shorten --target ios                  # AI writes an iOS text for every key over the limit
fl translate paywall_title --target ios  # translate the iOS text from the base language's
```

### Platform text

A project that ships to several platforms can give a key a text of its own on one of them,
without a second key: `fl edit <key> --target ios --value "..."` writes it for that locale,
`--clear` removes it. A target is a platform (`flutter`, `ios`, `angular`, `ngx`) or an
Apple device of `ios` (`ios/iphone`, `ios/ipad`, `ios/mac`, `ios/watch`, `ios/vision`,
`ios/tv`, `ios/other`), which reach a String Catalog as device variations. A target without
a text of its own gets the full text, as before. `--platforms ios,angular` on `fl add` or
`fl edit` keeps a key out of the other platforms' files (`all` puts it back everywhere), and
`--max-length ios=40` sets the longest text a target takes. `fl status` counts the texts
over a limit and the ones to check after the full text changed; `fl shorten [--target ios]
[keys...]` writes texts that fit; `fl translate` and `fl retranslate` take `--target`.
`fl export`, `fl pull` and `fl diff` give a Flutter app its own text and only the keys it
ships. A service that does not know platform text yet refuses these flags and changes
nothing.

### Glossary and voice

The translator sees one batch of strings at a time. Without guidance it translates your
product's name like any other word, says "du" in one batch and "Sie" in the next, and calls the
same feature two different things. Three settings fix that for every later translation:

- **Glossary terms.** `--keep` keeps a term exactly as written in every locale (brand and
  product names); a translation that changes it is refused and the string stays as it was.
  `--as <locale>=<text>` pins the translation of a term; a translation that does not use it is
  saved but marked for review. A term's `--note` tells the translator what it means.
  `fl glossary suggest` proposes terms from your strings (project name, recurring names,
  acronyms), `fl glossary import glossary.csv` loads a whole list
  (`term,keep,note,de,fr,...` or the JSON `fl glossary export` writes).
- **Language style.** `fl style set <locale> --formal|--informal [--instructions "..."]`.
  A regional variant (de-AT, pt-BR) follows its language unless it has its own style.
  `fl style set --all --instructions "..."` gives one instruction to every language of the
  project, including those added later; a language's own instructions add to it, and
  `fl style clear --all` removes it. `fl style` on its own lists what is set.
- **Locked keys.** `fl lock <key>` copies the base text into every locale and never sends the
  key for translation: URLs, code samples, names. It is the same flag as Xcode's
  `"shouldTranslate": false`, and both directions round-trip (`@key.x-translate: false` in ARBs).

These apply to what is translated from then on. `fl glossary apply` re-translates the strings
that contain glossary terms (`--term` narrows it, `--all` covers every string after a style
change; preview with `--dry-run`).

Two more things happen without a setting: a string that quotes another string of your app
("Tap “Tap to speak”") gets that string's existing translation, and a regional variant (de-CH)
is written from its language's translation (de) instead of from the source on its own.

`fl import <file.arb>` bulk-creates every key in an ARB in **one** request (instead of many
`fl add` calls) — the right tool for large migrations. `--overwrite` replaces existing values;
`-t/--translate` batch-fills the other locales afterwards; `--language <code>` sets the locale
the file represents. Without it, an ARB is read as the language it names (`@@locale`, else
the file name: `app_en.arb` is `en`, `app_pt_BR.arb` is `pt-BR`), and as the base language
when it names none. A file in a language the project does not have is refused: add the
language first, or pass `--language <base>` to import it as the base text on purpose.
Preview with `--dry-run`.

The result says what the server actually wrote: keys written, keys skipped because they
already hold a different value (pass `--overwrite` to replace them), and keys already
identical. Importing one locale's translations replaces rows that still hold a copy of the
base text (what adding a locale seeds them with) without `--overwrite`; rows marked checked
are kept. Placeholder types always come from the base language, so a translated ARB without
`@key` metadata cannot turn an `int` into a `String`.

`fl status` and `fl retranslate` treat a variant of the base language (`en-GB`, `en-US` for
an `en` base) that reads the same as the base as finished, and never flag a value with no
words in it (`{count}`). `fl retranslate --include-variants` sends the variant rows anyway.

### Bulk rules — read before scripting this CLI

Work must cost **O(1) requests, not O(N)**. Two commands cover every bulk case:

| Goal | Use | Cost |
|---|---|---|
| Add / change many keys | `fl import file.arb -t` | 1 request |
| Populate **new** locales | `fl languages add <c1> <c2> <c3> -t` | 1 per locale, one command (backend back-fills every key) |
| Repair every locale | `fl retranslate` (no `--locale`) | batched |
| Accept the loanword rows | `fl retranslate --accept-unchanged` | 1 request |
| Redo translations after rewording base strings | `fl retranslate --changed` | batched |
| Add one key | `fl add` | 1 request |

**Reworded strings.** When the base text of a key changes, its translations in the other
languages are kept and marked for review: they still say what the old text said. `fl edit`
says how many, `fl status` counts them per locale, and `fl retranslate --changed` translates
them again in one pass. It is not the default because the old translation is overwritten,
reviewed or not, and a corrected typo in the base does not always call for that.

**Never loop `fl add`, `fl edit`, `fl translate`, `fl languages add` or
`fl retranslate --locale`.** Each is already the bulk form of itself. Looping one is
refused after the fourth single-target call in 15 minutes, and the refusal prints the
command you should have run. If a request times out, do **not** lower the batch size —
that multiplies request count; the client halves and retries by itself.

**Never loop `fl add`, `fl edit` or `fl translate` over a list of keys.** Each `fl add -t` is
~6 backend requests (resolve, create, batch-translate, verify). A 115-key ARB done that way is
~700 requests — enough to exhaust a whole day's quota for the account. The same job via
`fl import` is one.

This is enforced, not merely advised:

- the backend rate-limits single-key creation to **10/min** and answers with a 429 that names
  the bulk endpoint to use instead;
- the MCP server refuses `add_string` after a handful of applied calls in a session.

A 429 from either is **not** a signal to sleep and retry — backing off runs the same wrong
algorithm slower. Switch to the bulk call.

Likewise, if `fl import -t` reports that nothing was translated, that is now a **hard error**
naming the locales that were left unseeded (usually: re-run the import against the base
language so every locale gets rows). Fix the bulk call; do not fall back to per-key writes.
That silent "nothing to translate" success was the original trap.

### `fl pull` / `fl sync` — getting the ARBs into the repo

The ARB directory is **generated output the backend owns**. Nothing in it is a local
contribution, so `fl pull` does not merge or rebase: it fetches and hard-resets onto the
upstream branch. A dirty file or a stale local commit cannot block it, and whatever it
discards is parked under `refs/fl/pre-sync/<stamp>`, printed so it can be read back with
`git show`. You never need to run git in that directory yourself — that is the point.

When the git mirror cannot deliver (no repo linked, repository deleted, the wrong git
credential active on the machine, no git at all), `pull` writes the same files from the API
instead and says which path it took. The two writers are byte-identical, so failing over
does not produce a diff.

```bash
fl pull                # sync arb_dir: git mirror if usable, API otherwise
fl pull --no-git       # skip the mirror, write from the API
fl sync app_en.arb     # import that file, pull, then regenerate the Dart
fl export path/to/dir  # just the write, to any directory
```

`fl sync` and `fl init` regenerate the Dart with `dart run flutter_localisation <folder>
<flavor>` from the app root (the folder holding `flutterlocalisation.json`), whatever folder
you run them from. They warn first when `pubspec.yaml` lacks `generate: true`, and when the
generator fails they print the end of its output, adding the `flutter pub add
flutter_localisation` hint only when the pubspec really lacks it.

**Keys that exist only on disk stop a sync.** Both paths rewrite the template from the
service, so a key staged by hand for an import that never ran would vanish — it has
happened, and it took an app's build with it. `pull` and `export` name those keys and
refuse; `fl pull --adopt` imports them first, `--discard-local` takes the service copy on
purpose. `--adopt` also imports the ARB of every other language found beside the template
(`app_en.arb` next to `app_de.arb`) as that language, so translations you already have are
kept, and asks for AI translation only for a language with no file. With a token that lacks
the Translate scope the strings are still imported; the output names the locales left
holding the base text, to fill later with `fl retranslate`.

This is the dashboard's Export, from the terminal. The ARBs are the backend's data, not
hand-written: `@@locale` is written in the same underscored form as the file name (gen_l10n
compares the two and aborts the build when they disagree), and `@key` metadata goes in the
template ARB only, which is where gen_l10n reads it from.

Prefer `pull` when the repo is linked — it is the path the backend pushes to.

### In a CI pipeline

A build needs three things: `flutterlocalisation.json` committed in the app (what `fl init`
writes), a read-only API key in a secret named `FL_API_TOKEN`, and one command.

```yaml
# Azure Pipelines
steps:
  - script: |
      dart pub global activate flutter_localisation_cli
      dart pub global run flutter_localisation_cli:fl pull
    displayName: Pull translations
    env:
      FL_API_TOKEN: $(FL_API_TOKEN)   # secret variables are not passed unless mapped
```

```yaml
# GitHub Actions
- name: Pull translations
  run: |
    dart pub global activate flutter_localisation_cli
    dart pub global run flutter_localisation_cli:fl pull
  env:
    FL_API_TOKEN: ${{ secrets.FL_API_TOKEN }}
```

```yaml
# GitLab CI (FL_API_TOKEN is a masked CI/CD variable)
pull_translations:
  script:
    - dart pub global activate flutter_localisation_cli
    - dart pub global run flutter_localisation_cli:fl pull
```

Run it after the Flutter or Dart SDK is installed and before the build. `flutter build`
regenerates the Dart from the ARBs when `pubspec.yaml` has `generate: true`; an app on the
`flutter_localisation` generator runs `dart run flutter_localisation <arb folder> <flavor>`.

What to expect on an agent:

- **It never asks anything.** No terminal, no prompt, and git is never left waiting for a
  credential.
- **Exit codes:** `0` done, `1` failed (the reason is on stderr), `64` wrong arguments. With
  `--json`, stdout is one JSON object and nothing else.
- **Your checkout is left alone.** When `arb_dir` sits inside the app's own repository, or the
  project has no repository linked, the files are written from the API and no git command
  touches the branch or commit the agent checked out.
- **A key that exists only in the committed ARB fails the build**, with the key named. Import
  it (`fl import`), or pass `--discard-local` to let the service win.
- **Network:** 5xx answers, a short rate limit and a refused connection are retried. A request
  with no answer after 150 seconds fails the step (`FL_HTTP_TIMEOUT=<seconds>` changes that).
  `HTTPS_PROXY`, `HTTP_PROXY` and `NO_PROXY` are honoured.

**Which version runs in the pipeline?** The steps above install the latest release on each
run, which is what we recommend: fixes reach the build without anyone editing the pipeline. To
pin one, name it (`dart pub global activate flutter_localisation_cli 1.19.0`), and update the
line when the log ends with `fl x.y.z is available`. That line is printed on stderr and never
fails a build. Only a version withdrawn for doing harm is refused, with exit code 1 and the
command to run; the dashboard shows which version each API key was last used by, so you can
see it coming.

**Do you need the CLI in the pipeline at all?** Not when the project is linked to a GitHub,
GitLab or Bitbucket repository: the service pushes every change there, so the pipeline can
check that repository out like any other (a second checkout step, or a submodule). `fl pull`
is for the other cases: no repository linked, a provider the dashboard does not link to
(Azure Repos), or a pipeline that should not hold a second git credential.

### Native iOS (String Catalogs)

A project can ship a Flutter app, a native iOS app, or both. Set its platforms in the
dashboard (project settings). With `ios` on, the backend renders every locale into one Xcode
String Catalog, `Localizable.xcstrings` (plus `InfoPlist.xcstrings` when the project holds
Info.plist keys such as `NSCameraUsageDescription`), and the git mirror pushes it like the
ARBs. Xcode 15 or later compiles the catalog for any deployment target. Product page:
https://flutterlocalisation.com/ios (free `.xcstrings` viewer and ARB converter there too).

```bash
fl import Gush/Resources/Localizable.xcstrings   # seed a project from the catalog Xcode made
fl pull                                          # write Localizable.xcstrings into xcstrings_dir
fl export Gush/Resources                         # same, straight from the API, to a directory
```

`fl pull` writes the catalog bytes exactly as the backend serves them, in Xcode's own
formatting, so a build does not rewrite the file and the mirror never sees a diff. The
local-only guard applies to the catalog too: a key added in Xcode and never imported stops a
pull; `--adopt` imports it first. An iOS-only project has no ARBs and `fl sync` skips the
Dart codegen for it. App Shortcut phrases (keys with `${applicationName}`) go to
`AppShortcuts.xcstrings`, the only catalog Xcode reads them from.

**An app with several catalogs** (the app, a widget, an extension, each with its own
`Localizable.xcstrings`, and named tables such as `Posts.xcstrings` that Swift reads with
`tableName: "Posts"`) lists them all. Xcode decides which string goes where when it extracts
them from the code; the project still holds one flat set of keys. A folder stands for its
`Localizable.xcstrings`, a table is named by its file:

```json
{
  "project": "Reelfree",
  "xcstrings_catalogs": [
    "App",
    "App/Posts/Posts.xcstrings",
    "App/Settings/Settings.xcstrings",
    "Extensions/Widgets"
  ]
}
```

`fl init` writes this list itself when it finds two or more catalogs. `fl pull` then writes
into each catalog the keys that catalog declares, every language filled in, in Xcode's
formatting. A string declared in two catalogs with the same text is one key on the service and
lands in both files. With two different texts (in any language) it cannot be one key: `pull`,
`pull --adopt`, `export`, `import` and `diff` stop before sending or writing anything and name
the key and its files. Rename the key in one table, in the catalog and in the Swift that reads
it. Keys on the service that no catalog declares are counted and named, not written.

`fl diff` with no file compares every listed catalog with the service, file by file, and
`fl status` lists each catalog with the keys the service does not have yet. The whole round
after adding strings in the code:

```bash
xcodebuild -exportLocalizations -project App.xcodeproj -localizationPath build/loc -exportLanguage en
fl pull --adopt    # new keys up in one import, translated, then every catalog back
```

The first line is Xcode's own extraction: it writes the new strings into each target's
catalog (a build in Xcode does the same). `InfoPlist.xcstrings` and `AppShortcuts.xcstrings`
go to the first folder of the list (a table is never that folder), and are not listed. A target with an Info.plist of its own (a Mac app beside the iPhone
one) keeps its permission sentences under a prefix:
`{"dir": "Mac", "infoplist_prefix": "mac."}` writes the key
`mac.NSMicrophoneUsageDescription` to `Mac/InfoPlist.xcstrings` as
`NSMicrophoneUsageDescription`. With `xcstrings_catalogs` the files are written from the API,
since the git mirror holds the one catalog the service renders.

Placeholders map by type: `{name}` becomes `%@`, an `int` becomes `%lld`, a `double` `%lf`;
with more than one argument they are numbered (`%1$@`, `%2$lld`). ICU plurals become plural
variations. Not supported in a catalog: ICU `select`, substitutions (several plural arguments
in one string) and device variations; the export names the offending keys and refuses.

### Angular (`@angular/localize`)

An Angular project uses Angular's own i18n, nothing else: `@angular/localize`, an `@@id` on
every message, `ng extract-i18n --format=arb`, and one build per locale
(`ng build --localize`). The service converts Angular's placeholders (`{$INTERPOLATION}`,
`{$START_LINK}…{$CLOSE_LINK}`) for the editor and the AI and writes them back unchanged.

```bash
ng extract-i18n --format=arb --output-path src/locale   # writes src/locale/messages.arb
fl import src/locale/messages.arb --translate          # the source up, every language filled
fl pull                                                # messages.<locale>.arb back, angular.json listed
ng build --localize
```

`fl pull` writes the translated files from the API (an Angular repo is the app itself, not a
translations mirror) and adds each locale under `i18n.locales` in `angular.json`; a locale
already listed keeps what it says. It never writes `messages.arb`: new strings there are
named, and `fl pull --adopt` imports them. Two Angular shapes have no stable name and are
left out of an import, with the fix: a message without an `@@id` (Angular names it by a hash
of its text) and a plural or select inside a sentence (Angular splits it into a second
message with a hash id; make the plural the whole message, the sentence inside each case).
`fl doctor` lists both before an upload. Angular apps get their strings with the build, so
live updates are for Flutter and iOS only.

### `fl doctor` — after a Flutter upgrade

Flutter no longer generates `package:flutter_gen`: since 3.47, `synthetic-package: true` fails
the build, gen-l10n refuses to run without `generate: true`, and every
`import 'package:flutter_gen/gen_l10n/...'` breaks. `fl doctor` finds all three, plus a missing
`flutter_localizations` or `intl` dependency, a project still on the discontinued `intl_utils` (with a link to the migration guide),
and an app on `material_ui` that still passes
`AppLocalizations.localizationsDelegates` (Material widgets then get no localized strings); `fl doctor --fix` rewrites `l10n.yaml`,
`pubspec.yaml` and the imports (to `package:<your_app>/<output-dir>/...`). Offline, no token.

### `fl native` — the half of localisation that is not the ARBs

Translating an app is three jobs, and the ARBs are only the first.

**The UI** comes from the ARBs. **The declarations** do not: `CFBundleLocalizations`
in `Info.plist` and `res/xml/locales_config.xml` on Android. Neither translates
anything — they are what puts every language in the App Store product page's
*Languages* row and the per-app language picker in Settings. With the iOS key
absent the bundle reads as English-only, so an app translated into 31 languages
advertises one in every storefront. **The permission alerts** do not either:
`NSCameraUsageDescription` and its siblings are drawn by iOS itself, from the
bundle, before the Dart isolate exists. No runtime lookup can reach them. The
only way to translate them is one `<code>.lproj/InfoPlist.strings` per language,
registered with the Xcode target — an unregistered file is never copied into the
bundle, which looks exactly like never having translated it.

All three rot silently. Nothing fails; the app just stops being translated where
nobody looks. So `fl native` generates them from the locales the project already
ships (read from the generated Dart, so it needs no ARB checkout, no token and
no network):

```bash
fl native                # write everything
fl native --check        # exit 1 if anything is stale — for CI
fl native --dry-run      # list what would change
fl native --init-copy    # scaffold the permission-copy file
```

The permission sentences live in `ios/Runner/InfoPlist.copy.json`, keyed by
locale:

```json
{
  "en": { "NSCameraUsageDescription": "Trace over what your camera sees." },
  "fr": { "NSCameraUsageDescription": "Décalquez ce que voit votre appareil photo." }
}
```

A locale in the app with no entry here is a hard failure rather than a silent
fallback to English — a fluent-looking alert in the wrong language is the bug
this command exists to prevent. `--init-copy` writes a starter from whatever
your `Info.plist` says today.

**Or keep the sentences in the project, as ordinary keys.** Thirty languages of
a hand-kept JSON file is a second translation job. Add the sentences as
translation keys (`iosCameraUsage`, ...), and name them in
`flutterlocalisation.json`:

```json
{
  "project": "My App",
  "arb_dir": "arbs/Default",
  "ios_permission_keys": {
    "NSCameraUsageDescription": "iosCameraUsage",
    "NSMicrophoneUsageDescription": "iosMicrophoneUsage"
  }
}
```

`fl native` then reads them from the ARBs, the copy file is not needed, and
`fl sync` ends with `fl native`: one command takes a change of wording from the
service to the Dart and to the permission alerts. A locale whose key has no
text stops the command and is named.

`fl native` also writes `locales_config.xml` if the project has none and points
`<application android:localeConfig>` at it, since a file nothing references is
the same as no file.

### First-time setup on a new machine or project

The backend pushes generated ARBs to a git repo you link in the dashboard (**Project → Git**).
`fl pull` only updates a repo that is *already* on disk, so bootstrap with `clone`:

```bash
fl repo --project "V-Shape"      # → https://github.com/you/shape_arbs  (github)
fl clone --project "V-Shape"     # arb_dir arbs/Default: clones it as ./arbs
echo '/arbs/' >> .gitignore      # the backend owns that repo; don't vendor it
```

Then point `l10n.yaml` at the clone and run codegen:

```yaml
arb-dir: arbs/Default
output-dir: lib/localization/generated
output-localization-file: app_localizations.dart
nullable-getter: false
```

`fl repo` reads the linked provider off the project detail endpoint (`github`, `gitlab`,
`bitbucket`, `bitbucket_server` or `azure_devops`) and warns when the git token needs reconnecting. `--json`
gives `{project, repository: {provider, url, needs_reauth}}`; it exits non-zero when no
provider is linked. The repo holds one folder per flavor at its root, so when the last folder
of `arb_dir` is a flavor name, `fl clone` clones into the folder above it (`arbs/` for
`arbs/Default`); `fl clone <dir>` clones exactly where you say. It refuses to clobber a
non-empty directory: use `fl pull` to update an existing clone. When git is refused the https
URL of a private repo on github.com, gitlab.com or bitbucket.org, `fl clone` retries the SSH
form (`git@host:owner/repo.git`) and says which one worked. Preview either with `--dry-run`.
If the clone never happens, or the machine's git credential cannot see the repo, `fl pull`
still works: it writes the ARBs from the API.

When the project is relinked to another repo in the dashboard, `fl pull` stops instead of
syncing the old clone: it prints the clone's origin and the new repo, and the
`git -C arbs remote set-url origin <new>` that fixes it (or delete the clone and run
`fl clone` again). `--json` reports it as `{"ok": false, "error": "repo_mismatch", ...}`.
https, SSH and `.git` spellings of one repo count as the same repo.

`fl guard` stops AI agents from editing the backend-managed files: the ARB directory (`arb_dir`
+ `l10n.yaml` `arb-dir`/`output-dir`) and `lib/generated_translation_methods.dart`. Those may
only change via `fl` / `flutter_localisation` + `fl pull`; a direct AI edit is silently
overwritten on the next sync (or lost, for the gitignored ARB repo). Run it once per project
(`--dry-run` to preview) and commit what it writes:

| Agent | What refuses the edit | What explains the workflow |
| --- | --- | --- |
| Claude Code | `permissions.deny` rules in `.claude/settings.json` | `CLAUDE.md`, `AGENTS.md` |
| GitHub Copilot (CLI, cloud agent) | a `preToolUse` hook, `.github/hooks/fl-guard.json` with its sh and PowerShell script | `.github/copilot-instructions.md`, `AGENTS.md` |
| Other agents | | `AGENTS.md` |

The Copilot CLI loads a repository's hooks once the folder is trusted. The hook needs nothing
installed, so it also runs in the cloud agent's sandbox. Run `fl guard` again after changing
`arb_dir`.

A project-local `flutterlocalisation.json` is **optional** — set it to avoid `--project` each
time:

```json
{ "project": "Chat Bot", "flavor": "Default", "arb_dir": "widget_chat_arbs" }
```

The flavor comes from `--flavor`, then `flavor` here (`fl init` writes it), then the last
folder of `arb_dir` when it names a flavor (`arbs/Default`), then the project's only flavor.

`xcstrings_dir` (optional) is where `fl pull` writes the iOS String Catalogs, relative to the
config file like `arb_dir`; an iOS-only app points it at its Xcode resources folder. Without
it the catalogs go beside the ARBs.

Global flags: `--project <name|id>`, `--flavor`, `--config`, `--dry-run`, `--json`.

## Staying up to date

```bash
fl --version     # the version in use
fl upgrade       # install the latest one (dart pub global activate flutter_localisation_cli)
```

`fl` and `fl_mcp` tell the service which version they are, and the service tells them when a
newer one is published. `fl` prints one line after the command: once a day at a desk, on every
run in a build (`CI` or `TF_BUILD` set), and every time when the service says why the update
matters. `fl_mcp` hands it to the agent once per session. Set `FL_NO_UPDATE_NOTICE=1` to
silence it.

Installed with `dart pub global activate`, `fl` and `fl_mcp` also update themselves: when one
starts and pub.dev has a newer version, it installs it and runs it instead, so an MCP server
opened after a release is the release. Not in CI, not for a checkout, a binary or the npm
package. Set `FL_NO_AUTO_UPDATE=1` to stay on the installed version.

## MCP server (Claude, GitHub Copilot)

`fl_mcp` lets an AI agent manage your translations. Mutating tools are **preview-by-default**:
they only write when the agent passes `apply: true`. The token is optional once you have run
`fl login`.

**Claude Code:**

```bash
claude mcp add flutter-localisation --env FL_API_TOKEN=flk_live_xxx -- fl_mcp
```

**Claude Desktop** (use the absolute path — Desktop's PATH often omits `~/.pub-cache/bin`):

```json
{
  "mcpServers": {
    "flutter-localisation": {
      "command": "/Users/you/.pub-cache/bin/fl_mcp",
      "env": { "FL_API_TOKEN": "flk_live_xxx" }
    }
  }
}
```

**GitHub Copilot CLI:**

```bash
copilot mcp add flutter-localisation --env FL_API_TOKEN=flk_live_xxx -- fl_mcp
```

**GitHub Copilot, for the whole team:** commit a `.mcp.json` at the root of the app. Each
developer runs `fl login` once, or exports `FL_API_TOKEN`, so no token is committed:

```json
{
  "mcpServers": {
    "flutter-localisation": { "type": "stdio", "command": "fl_mcp" }
  }
}
```

Then ask: *"list my projects"*, then *"in Chat Bot, add `checkout_button` = 'Buy now' and
translate it to all locales."* Tools: `list_projects`, `list_status`, `list_languages`,
`add_language`, `project_repo`, `add_string`, `show_string`, `edit_string`, `delete_string`, `translate_key`,
`retranslate`, `shorten`, `import_arb`, `pull_arbs`, `glossary`, `language_style`,
`lock_keys` (each
takes an optional `project`/`flavor`), and
`sync_native_locales` — the MCP face of `fl native`, and `check_l10n_setup` — the MCP face of
`fl doctor`, both needing no token and taking an optional `project_root`. `project_repo` returns the linked ARB git repo so the agent can clone it before
codegen; `pull_arbs` writes the ARBs into `arb_dir` (and the String Catalogs into
`xcstrings_dir`) the same way `fl pull` does. `import_arb` takes an `.xcstrings` too.
`edit_string` and `add_string` take `target`, `platforms` and `max_length`, `translate_key`
and `retranslate` take `target`, as the CLI flags do. `fl_mcp` reads `base_url` from
`flutterlocalisation.json` when `FL_BASE_URL` is not set.

### With the Dart and Flutter MCP server

`dart mcp-server` (Dart 3.12+) gives the agent the analyzer, tests, `dart fix`, hot reload and
the widget inspector; `fl_mcp` changes the strings. Run both, no tool names overlap:

```bash
claude mcp add dart -- dart mcp-server
claude mcp add flutter-localisation --env FL_API_TOKEN=flk_live_xxx -- fl_mcp
```

A string change then goes `add_string` or `import_arb` → `pull_arbs` → regenerate the Dart
(`fl sync`, or `dart run flutter_localisation <arb_root> <flavor>`) → `analyze_files`. After a Flutter upgrade: `check_l10n_setup` with `apply: true`, `flutter gen-l10n`,
then `analyze_files`.

## VS Code extension

[Flutter Localization (ARB, gen-l10n)](https://marketplace.visualstudio.com/items?itemName=flutterlocalisation.flutter-l10n)
reports hardcoded strings, extracts them to the template ARB with one quick fix, regenerates on save and shows
every translation on hover. Its **Translate and Sync** command runs `fl sync`. Also on Open VSX for Cursor and
other VS Code forks.

## Agent skill

`skills/flutter-localisation` teaches a coding agent the workflows above: setup, adding strings
and languages in bulk, `fl doctor` after a Flutter upgrade, live updates and `fl native`, and
never editing the generated files by hand. Install it into an app with:

```bash
npx skills add tajaouart/flutter_localisation_cli --skill flutter-localisation
```

It asks which agents to install for; `-a github-copilot` or `-a claude-code` answers it.

## How strings reach your app

```
fl add / AI agent ─▶ backend creates/translates ─▶ backend pushes ARBs to your git repo
                                                            │
                                     fl pull / fl sync  ◀───┘ ─▶ codegen ─▶ typed strings
```

## License

MIT.
