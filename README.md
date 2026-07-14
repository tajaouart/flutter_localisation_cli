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
fl delete greeting                       # whole key (or --locale fr for one locale)
fl pull                                  # git pull the ARB repo (arb_dir in config)
fl guard                                 # stop AI agents editing ARBs + generated Dart
```

`fl import <file.arb>` bulk-creates every key in an ARB in **one** request (instead of many
`fl add` calls) — the right tool for large migrations. `--overwrite` replaces existing values;
`-t/--translate` batch-fills the other locales afterwards; `--language <code>` sets the locale
the file represents (default: the base language). Preview with `--dry-run`.

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
translate it to all locales."* Tools: `list_projects`, `list_status`, `add_string`,
`edit_string`, `delete_string`, `translate_key` (each takes an optional `project`/`flavor`).

## How strings reach your app

```
fl add / Claude ─▶ backend creates/translates ─▶ backend pushes ARBs to your git repo
                                                            │
                                     fl pull / git pull ◀───┘ ─▶ codegen ─▶ typed strings
```

## License

MIT.
