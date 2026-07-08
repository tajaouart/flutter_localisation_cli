# Changelog

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
