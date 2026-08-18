# flutter_localisation_cli

Terminal **CLI** (`fl`) and **MCP server** (`fl_mcp`) for
[FlutterLocalisation](https://flutterlocalisation.com) — add, edit, delete and AI-translate
your app's localization keys from the shell or from Claude, then pull the ARBs. No dashboard
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

## Auth

Create a scoped API token in the dashboard → **API Keys** (`flk_live_…`), then either:

```bash
fl login --token flk_live_xxx      # stored in ~/.config/flutterlocalisation (chmod 600)
# or: export FL_API_TOKEN=flk_live_xxx     # or pass --token on each call
```

The token is **workspace-scoped**, so you pick projects by name — no numeric ids.

## CLI

```bash
fl projects                              # list your projects (name, flavors, locales)
fl status --project "Chat Bot"           # completion % per locale
fl add greeting --value "Hello" -t       # add key + AI-translate every other locale
fl edit greeting --locale fr --value "Bonjour"
fl import strings.arb -t                 # bulk-create MANY keys from one ARB, then translate
fl translate greeting --missing          # fill only empty locales
fl languages                             # list locales + how many keys each has filled
fl languages add id -t                   # add a locale and AI-fill EVERY existing key
fl languages remove id                   # drop a locale and its translations
fl delete greeting                       # whole key (or --locale fr for one locale)
fl repo                                  # print the ARB git repo URL (from the dashboard)
fl clone                                 # first-time: clone that repo into arb_dir
fl pull                                  # git pull the ARB repo (arb_dir in config)
fl guard                                 # stop AI agents editing ARBs + generated Dart
```

`fl import <file.arb>` bulk-creates every key in an ARB in **one** request (instead of many
`fl add` calls) — the right tool for large migrations. `--overwrite` replaces existing values;
`-t/--translate` batch-fills the other locales afterwards; `--language <code>` sets the locale
the file represents (default: the base language). Preview with `--dry-run`.

### Bulk rules — read before scripting this CLI

Work must cost **O(1) requests, not O(N)**. Two commands cover every bulk case:

| Goal | Use | Cost |
|---|---|---|
| Add / change many keys | `fl import file.arb -t` | 1 request |
| Populate a **new** locale | `fl languages add <code> -t` | 1 request (backend back-fills every key) |
| Add one key | `fl add` | 1 request |

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

### First-time setup on a new machine or project

The backend pushes generated ARBs to a git repo you link in the dashboard (**Project → Git**).
`fl pull` only updates a repo that is *already* on disk, so bootstrap with `clone`:

```bash
fl repo --project "V-Shape"      # → https://github.com/you/shape_arbs  (github)
fl clone --project "V-Shape"     # clones it into arb_dir (default: ./arbs)
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
`bitbucket` or `bitbucket_server`) and warns when the git token needs reconnecting. `--json`
gives `{project, repository: {provider, url, needs_reauth}}`; it exits non-zero when no
provider is linked. `fl clone [<dir>]` refuses to clobber a non-empty directory — use
`fl pull` to update an existing clone. Preview either with `--dry-run`.

`fl guard` writes `permissions.deny` rules into `.claude/settings.json` so Claude Code refuses
to `Edit`/`Write` the backend-managed files — the ARB directory (`arb_dir` + `l10n.yaml`
`arb-dir`/`output-dir`) and `lib/generated_translation_methods.dart`. Those may only change via
`fl` / `flutter_localisation` + `git pull`; a direct AI edit is silently overwritten on the next
sync (or lost, for the gitignored ARB repo). Run it once per project (`--dry-run` to preview).

A project-local `flutterlocalisation.json` is **optional** — set it to avoid `--project` each
time:

```json
{ "project": "Chat Bot", "flavor": "Default", "arb_dir": "widget_chat_arbs" }
```

Global flags: `--project <name|id>`, `--flavor`, `--config`, `--dry-run`, `--json`.

## MCP server (Claude)

`fl_mcp` lets Claude manage your translations. Mutating tools are **preview-by-default** — they
only write when Claude passes `apply: true`.

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

Then ask: *"list my projects"*, then *"in Chat Bot, add `checkout_button` = 'Buy now' and
translate it to all locales."* Tools: `list_projects`, `list_status`, `project_repo`, `add_string`,
`edit_string`, `delete_string`, `translate_key`, `import_arb` (each takes an optional
`project`/`flavor`). `project_repo` returns the linked ARB git repo so Claude can clone it
before codegen.

## How strings reach your app

```
fl add / Claude ─▶ backend creates/translates ─▶ backend pushes ARBs to your git repo
                                                            │
                                     fl pull / git pull ◀───┘ ─▶ codegen ─▶ typed strings
```

## License

MIT.
