/// The version of this package, and what the service says about it.
///
/// Every request names the client (`X-FL-Client: fl/1.19.0`). The service
/// answers with the latest published version, so the CLI can say an update
/// exists without asking pub.dev, and refuses a version it has withdrawn.
library;

/// Kept equal to `version:` in pubspec.yaml by a test.
const String kCliVersion = '1.19.1';

/// Set to any value to keep the "update available" line out of the output.
const String kNoUpdateNoticeEnvVar = 'FL_NO_UPDATE_NOTICE';

const String kUpgradeCommand =
    'dart pub global activate flutter_localisation_cli';

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

  /// The lines to print, for [name] (`fl` or `fl_mcp`).
  String describe(final String name) =>
      '$name $latest is available (this is $kCliVersion).'
      '${reason == null || reason!.isEmpty ? '' : ' $reason'}\n'
      'Update with: ${command ?? kUpgradeCommand}';
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
