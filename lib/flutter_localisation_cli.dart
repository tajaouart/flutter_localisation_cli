/// Programmatic access to FlutterLocalisation — the shared core behind the `fl` CLI
/// and the `fl_mcp` MCP server. Pure Dart (no Flutter), so it runs anywhere Dart does.
///
/// Most users interact via the `fl` / `fl_mcp` executables, but the core is exported here
/// so it can be embedded in other Dart tools.
library;

export 'src/config.dart';
export 'src/exceptions.dart';
export 'src/management_client.dart';
export 'src/operations.dart';
export 'src/project_resolver.dart';
