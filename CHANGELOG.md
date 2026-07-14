# Changelog

## [1.1.0] - 2026-07-14
### Added
- **`import_arb` MCP tool — bulk-create keys from one ARB file.** Instead of many
  per-key `add_string` calls, put all strings in an ARB JSON and import it in a single
  request (`path` to a file, or inline `content`). `translate=true` then batch-translates
  the other locales in one pass. Preview by default; `apply=true` writes. Backed by a new
  `ManagementClient.importArb()` (multipart to `/api/project/{id}/import-arb/`) and
  `Operations.importArb()`. Requires a `strings:write` token.

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
