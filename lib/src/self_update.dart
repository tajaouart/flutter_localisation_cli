/// A copy installed with `dart pub global activate` brings itself up to date
/// when it starts: an MCP server or a CLI opened again after a release runs the
/// release, without anyone typing `fl upgrade`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;

import 'version.dart';

/// Set to any value to keep a copy on the version it is.
const String kNoAutoUpdateEnvVar = 'FL_NO_AUTO_UPDATE';

const String _package = 'flutter_localisation_cli';

/// Whether [script] is the snapshot `dart pub global activate` installed, the
/// only kind of copy that can replace itself. A checkout run with `dart run`,
/// a compiled binary and the npm package are left alone.
bool isPubGlobalSnapshot(final String script) {
  final String s = script.replaceAll(r'\', '/');
  return s.contains('/global_packages/$_package/') && s.endsWith('.snapshot');
}

bool _set(final String? v) =>
    v != null && v.isNotEmpty && v != '0' && v.toLowerCase() != 'false';

/// Whether this process may look for a newer version and install it.
bool autoUpdateAllowed(final Map<String, String> env, final String script) =>
    !env.containsKey(kNoAutoUpdateEnvVar) &&
    !installedByNpm(env) &&
    !_set(env['CI']) &&
    !_set(env['TF_BUILD']) &&
    isPubGlobalSnapshot(script);

/// When the last look found nothing newer, the next one waits this long, so
/// starting many times in a row asks pub.dev once.
const Duration kRecheckAfter = Duration(minutes: 10);

File _stamp(final Map<String, String> env) {
  final String home = env['HOME'] ?? env['USERPROFILE'] ?? '.';
  return File('$home/.config/flutterlocalisation/auto_update.json');
}

bool _recentlyCurrent(final File stamp, final DateTime now) {
  try {
    final Object? seen = jsonDecode(stamp.readAsStringSync());
    if (seen is Map && seen['version'] == kCliVersion && seen['at'] is int) {
      final int age = now.millisecondsSinceEpoch - (seen['at'] as int);
      return age >= 0 && age < kRecheckAfter.inMilliseconds;
    }
  } on Object {
    // No stamp yet.
  }
  return false;
}

void _markCurrent(final File stamp, final DateTime now) {
  try {
    stamp.parent.createSync(recursive: true);
    stamp.writeAsStringSync(jsonEncode(<String, Object>{
      'version': kCliVersion,
      'at': now.millisecondsSinceEpoch,
    }));
  } on Object {
    // A home that cannot be written to looks every time.
  }
}

/// The latest version on pub.dev, or null when it cannot be had quickly.
Future<String?> latestPublished({final http.Client? client}) async {
  final http.Client c = client ?? http.Client();
  try {
    final http.Response r = await c
        .get(Uri.parse('https://pub.dev/api/packages/$_package'))
        .timeout(const Duration(seconds: 3));
    if (r.statusCode != 200) return null;
    final Object? body = jsonDecode(r.body);
    if (body is Map && body['latest'] is Map) {
      return (body['latest'] as Map)['version'] as String?;
    }
  } on Object {
    // Offline or slow: start on this version.
  } finally {
    if (client == null) c.close();
  }
  return null;
}

/// The `dart` that runs this snapshot. The VM can name itself `dartvm`, which
/// takes no `pub` command; the `dart` beside it does.
String _dart() {
  final String self = Platform.resolvedExecutable;
  if (path.basenameWithoutExtension(self) == 'dart') return self;
  final String sibling =
      path.join(path.dirname(self), Platform.isWindows ? 'dart.exe' : 'dart');
  return File(sibling).existsSync() ? sibling : 'dart';
}

/// Installs a newer version if there is one and runs it in place of this
/// process, on the same stdin and stdout. Returns the exit code of the newer
/// copy, or null when this copy should go on (nothing newer, not allowed, or
/// the install failed). Writes nothing to stdout: for `fl_mcp` it is the
/// protocol channel.
Future<int?> runNewerIfAny(
  final List<String> args, {
  final Map<String, String>? environment,
  final String? script,
  final Future<String?> Function()? latest,
  final DateTime Function() now = DateTime.now,
}) async {
  final Map<String, String> env = environment ?? Platform.environment;
  final String self = script ?? Platform.script.toFilePath();
  if (!autoUpdateAllowed(env, self)) return null;
  final File stamp = _stamp(env);
  if (_recentlyCurrent(stamp, now())) return null;
  final String? newest = await (latest ?? latestPublished)();
  if (newest == null) return null;
  if (!isOlder(kCliVersion, newest)) {
    _markCurrent(stamp, now());
    return null;
  }
  final String dart = _dart();
  final ProcessResult install = await Process.run(
    dart,
    <String>['pub', 'global', 'activate', _package, newest],
  ).timeout(const Duration(minutes: 2),
      onTimeout: () => ProcessResult(0, 1, '', 'timed out'));
  if (install.exitCode != 0) {
    stderr.writeln('Could not update to $newest, going on with '
            '$kCliVersion: ${install.stderr}'
        .trim());
    return null;
  }
  stderr.writeln('Updated from $kCliVersion to $newest.');
  // The activate wrote the new snapshot at the same path.
  final Process next = await Process.start(
    dart,
    <String>[self, ...args],
    environment: <String, String>{kNoAutoUpdateEnvVar: '1'},
    mode: ProcessStartMode.inheritStdio,
  );
  return next.exitCode;
}
