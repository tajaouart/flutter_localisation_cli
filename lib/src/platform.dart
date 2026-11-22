/// The apps a project ships its strings to, as the service names them.
///
/// Every platform-dependent choice switches over [AppPlatform], so adding one
/// is a compile error everywhere a case is missing instead of a silent
/// fall-through to Flutter.
enum AppPlatform {
  flutter('flutter', 'Flutter', liveUpdates: true),
  ios('ios', 'iOS', liveUpdates: true),
  angular('angular', 'Angular', liveUpdates: false),
  ngx('ngx', 'ngx-translate', liveUpdates: false);

  const AppPlatform(this.wire, this.label, {required this.liveUpdates});

  /// The name in the API (`platforms: ["flutter", "angular"]`).
  final String wire;
  final String label;

  /// A published app can fetch changed strings without a new release.
  final bool liveUpdates;

  /// What the project writes to disk for this platform.
  String get files => switch (this) {
        AppPlatform.flutter => 'app_<locale>.arb',
        AppPlatform.ios => 'Localizable.xcstrings',
        AppPlatform.angular => 'messages.<locale>.arb',
        AppPlatform.ngx => '<locale>.json',
      };

  static AppPlatform? fromWire(final Object? value) {
    for (final AppPlatform p in AppPlatform.values) {
      if (p.wire == value) return p;
    }
    return null;
  }
}

/// The platforms of a project in the service's order. Nothing known means
/// Flutter, which is what every project created before platforms existed is.
List<AppPlatform> platformsFromJson(final Object? raw) {
  final Set<AppPlatform> found = <AppPlatform>{
    if (raw is List)
      for (final Object? v in raw)
        if (AppPlatform.fromWire(v) case final AppPlatform p) p,
  };
  if (found.isEmpty) return const <AppPlatform>[AppPlatform.flutter];
  return <AppPlatform>[
    for (final AppPlatform p in AppPlatform.values)
      if (found.contains(p)) p,
  ];
}

String platformLabels(final List<AppPlatform> platforms,
        {final String separator = ' + '}) =>
    platforms.map((final AppPlatform p) => p.label).join(separator);

List<String> platformWires(final List<AppPlatform> platforms) =>
    <String>[for (final AppPlatform p in platforms) p.wire];
