/// The version of this package, and what the service says about it.
///
/// Every request names the client (`X-FL-Client: fl/1.19.0`). The service
/// answers with the latest published version, so the CLI can say an update
/// exists without asking pub.dev, and refuses a version it has withdrawn.
library;

import 'dart:convert';
import 'dart:io';

/// Kept equal to `version:` in pubspec.yaml by a test.
const String kCliVersion = '1.25.3';

/// Set to any value to keep the "update available" line out of the output.
const String kNoUpdateNoticeEnvVar = 'FL_NO_UPDATE_NOTICE';

const String kUpgradeCommand =
    'dart pub global activate flutter_localisation_cli';

/// Set by the npm launcher of `@flutterlocalisation/cli` to `npm`, so the
/// upgrade advice names the tool that installed this copy.
const String kInstalledByEnvVar = 'FL_INSTALLED_BY';
const String kNpmUpgradeCommand =
    'npm install --save-dev @flutterlocalisation/cli@latest';

bool installedByNpm([final Map<String, String>? env]) =>
    (env ?? Platform.environment)[kInstalledByEnvVar] == 'npm';

/// The command that updates this copy, wherever it came from.
String upgradeCommandFor([final Map<String, String>? env]) =>
    installedByNpm(env) ? kNpmUpgradeCommand : kUpgradeCommand;

/// A newer version the service told this process about.
class UpdateNotice {
  UpdateNotice({required this.latest, this.reason, this.command});

  final String latest;

  /// Why this update matters, when the service says.
  final String? reason;
  final String? command;

  /// The newest notice any request of this process received.
  static UpdateNotice? current;

  /// Reads the version headers of a response; older services send none.
  static void read(final Map<String, String> headers) {
    final String? latest = headers['x-fl-latest-version'];
    if (latest == null || !isOlder(kCliVersion, latest)) return;
    current = UpdateNotice(
      latest: latest,
      reason: headers['x-fl-notice'],
      command: headers['x-fl-upgrade-command'],
    );
  }

  /// Whether `fl` should print the notice after this command.
  ///
  /// A build log gets it on every run, and so does a notice that says why the
  /// update matters. Otherwise once a day per version is enough: printed after
  /// every command it buried the output of each one.
  bool isDue(
    final Map<String, String> env, {
    final File? stamp,
    final DateTime Function() now = DateTime.now,
  }) {
    if (env.containsKey(kNoUpdateNoticeEnvVar)) return false;
    if (reason != null && reason!.isNotEmpty) return true;
    if (_isSet(env['CI']) || _isSet(env['TF_BUILD'])) return true;
    final File file = stamp ?? _stampFile(env);
    final int at = now().millisecondsSinceEpoch;
    try {
      final Object? seen = jsonDecode(file.readAsStringSync());
      if (seen is Map &&
          seen['latest'] == latest &&
          seen['at'] is int &&
          at >= (seen['at'] as int) &&
          at - (seen['at'] as int) < const Duration(days: 1).inMilliseconds) {
        return false;
      }
    } on Object {
      // No stamp yet, or one that cannot be read: say it.
    }
    try {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
          jsonEncode(<String, Object>{'latest': latest, 'at': at}));
    } on Object {
      // A home that cannot be written to hears it every time.
    }
    return true;
  }

  static bool _isSet(final String? value) =>
      value != null &&
      value.isNotEmpty &&
      value != '0' &&
      value.toLowerCase() != 'false';

  static File _stampFile(final Map<String, String> env) {
    final String home = env['HOME'] ?? env['USERPROFILE'] ?? '.';
    return File('$home/.config/flutterlocalisation/update_notice.json');
  }

  /// The lines to print, for [name] (`fl` or `fl_mcp`).
  String describe(final String name) =>
      '$name $latest is available (this is $kCliVersion).'
      '${reason == null || reason!.isEmpty ? '' : ' $reason'}\n'
      'Update with: ${installedByNpm() ? kNpmUpgradeCommand : command ?? kUpgradeCommand}';
}

/// Whether [version] is below [than], comparing numbers and not text
/// (1.9.0 is older than 1.10.0). False when either is unreadable.
bool isOlder(final String version, final String than) {
  final List<int>? a = _parse(version);
  final List<int>? b = _parse(than);
  if (a == null || b == null) return false;
  for (int i = 0; i < 3; i++) {
    if (a[i] != b[i]) return a[i] < b[i];
  }
  return false;
}

List<int>? _parse(final String version) {
  final RegExpMatch? m =
      RegExp(r'^(\d+)(?:\.(\d+))?(?:\.(\d+))?').firstMatch(version.trim());
  if (m == null) return null;
  return <int>[
    for (int i = 1; i <= 3; i++) int.parse(m.group(i) ?? '0'),
  ];
}
