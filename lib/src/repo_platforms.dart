/// Which of a project's platforms the repository at hand holds.
///
/// A project can ship to several platforms whose apps live in separate
/// repositories (a website in one, the iPhone app in another). Each
/// repository's `flutterlocalisation.json` may say which ones it holds in
/// `platforms`; without it, a project with one platform is taken whole and
/// one with several is narrowed to what the repository's own files show.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:flutter_localisation_cli/src/config.dart';
import 'package:flutter_localisation_cli/src/management_client.dart';
import 'package:flutter_localisation_cli/src/ngx.dart';
import 'package:flutter_localisation_cli/src/platform.dart';
import 'package:flutter_localisation_cli/src/repo_locales.dart';

/// Folders skipped while looking for Xcode files: build output and
/// dependencies carry projects that are not the app's.
const Set<String> _skipped = <String>{
  'Pods',
  'build',
  '.build',
  'DerivedData',
  'node_modules',
  '.dart_tool',
  '.git',
  'Carthage',
  'dist',
};

/// The platforms the files under [root] show, each with what showed it.
Map<AppPlatform, String> detectRepoPlatforms(final String root) {
  final Map<AppPlatform, String> found = <AppPlatform, String>{};
  final File pubspec = File(p.join(root, 'pubspec.yaml'));
  if (pubspec.existsSync() && pubspec.readAsStringSync().contains('flutter:')) {
    found[AppPlatform.flutter] = 'pubspec.yaml depends on Flutter';
  }
  final String? xcode = _firstXcodeFile(root);
  if (xcode != null) found[AppPlatform.ios] = xcode;
  if (File(p.join(root, 'angular.json')).existsSync() &&
      _dependsOn(root, '@angular/localize')) {
    found[AppPlatform.angular] = 'angular.json with @angular/localize';
  }
  if (usesNgxTranslate(root)) {
    found[AppPlatform.ngx] = 'package.json depends on ngx-translate';
  } else if (ngxDirIn(root) case final String dir) {
    found[AppPlatform.ngx] = '$dir holds <locale>.json files';
  }
  return found;
}

bool _dependsOn(final String root, final String package) {
  final File pkg = File(p.join(root, 'package.json'));
  if (!pkg.existsSync()) return false;
  try {
    final Object? doc = jsonDecode(pkg.readAsStringSync());
    if (doc is! Map<String, dynamic>) return false;
    return <String>['dependencies', 'devDependencies'].any((final String s) =>
        doc[s] is Map && (doc[s] as Map).containsKey(package));
  } on FormatException {
    return false;
  }
}

/// The first `*.xcodeproj` or `*.xcstrings` under [root], relative to it.
/// Breadth first and five folders deep at most: an app's Xcode project sits
/// at the root or one folder down (`ios/Runner.xcodeproj`).
String? _firstXcodeFile(final String root) {
  List<Directory> level = <Directory>[Directory(root)];
  for (int depth = 0; depth < 5 && level.isNotEmpty; depth++) {
    final List<Directory> next = <Directory>[];
    for (final Directory dir in level) {
      List<FileSystemEntity> entries;
      try {
        entries = dir.listSync()
          ..sort((final FileSystemEntity a, final FileSystemEntity b) =>
              a.path.compareTo(b.path));
      } on FileSystemException {
        continue;
      }
      for (final FileSystemEntity e in entries) {
        final String name = p.basename(e.path);
        if (name.endsWith('.xcodeproj') || name.endsWith('.xcstrings')) {
          return p.relative(e.path, from: root);
        }
        if (e is Directory &&
            !name.startsWith('.') &&
            !_skipped.contains(name)) {
          next.add(e);
        }
      }
    }
    level = next;
  }
  return null;
}

/// The platforms of [project] this repository holds.
///
/// [problem] is set when none could be settled on: nothing that reads or
/// writes the repository's files may run then.
class RepoPlatforms {
  RepoPlatforms(this.platforms, {this.inferred, this.problem});

  final List<AppPlatform> platforms;

  /// What each inferred platform was inferred from; null when pinned in the
  /// config or when the project has a single platform.
  final Map<AppPlatform, String>? inferred;
  final String? problem;
}

/// Settle the platforms of this repository for a project shipping
/// [projectPlatforms]: [pinned] (`platforms` in the config) when given,
/// the whole project when it has one platform, else what [root] shows.
RepoPlatforms resolveRepoPlatforms({
  required final List<AppPlatform> projectPlatforms,
  required final List<AppPlatform>? pinned,
  required final String root,
  final String configName = 'flutterlocalisation.json',
}) {
  List<AppPlatform> inProject(final Iterable<AppPlatform> wanted) =>
      <AppPlatform>[
        for (final AppPlatform pl in projectPlatforms)
          if (wanted.contains(pl)) pl,
      ];
  final String ships = platformLabels(projectPlatforms, separator: ', ');
  if (pinned != null) {
    final List<AppPlatform> held = inProject(pinned);
    return RepoPlatforms(held,
        problem: held.isEmpty
            ? '"platforms" in $configName says this repository holds '
                '${platformLabels(pinned, separator: ', ')}, and the project '
                'ships $ships only. Nothing was read or written; fix '
                '"platforms" or the project.'
            : null);
  }
  if (projectPlatforms.length < 2) return RepoPlatforms(projectPlatforms);
  final Map<AppPlatform, String> seen = detectRepoPlatforms(root);
  final List<AppPlatform> held = inProject(seen.keys);
  if (held.isEmpty) {
    return RepoPlatforms(const <AppPlatform>[],
        inferred: const <AppPlatform, String>{},
        problem: 'The project ships $ships and nothing here shows which of '
            'them this repository holds. Nothing was read or written. Add '
            '"platforms": ${jsonEncode(platformWires(projectPlatforms))} to '
            '$configName, keeping only the ones this repository holds.');
  }
  return RepoPlatforms(held, inferred: <AppPlatform, String>{
    for (final AppPlatform pl in held) pl: seen[pl]!,
  });
}

/// The line telling which platforms were inferred and how to pin them.
String inferredNotice(final RepoPlatforms r, final List<AppPlatform> project,
    {final String configName = 'flutterlocalisation.json'}) {
  final List<AppPlatform> others = <AppPlatform>[
    for (final AppPlatform pl in project)
      if (!r.platforms.contains(pl)) pl,
  ];
  return 'This repository holds '
      '${r.platforms.map((final AppPlatform pl) => '${pl.label} (${r.inferred![pl]})').join(', ')}'
      '${others.isEmpty ? '' : '; ${platformLabels(others, separator: ', ')} '
          'files are left to their own repository'}. Pin it with '
      '"platforms": ${jsonEncode(platformWires(r.platforms))} in $configName.';
}

final Set<String> _told = <String>{};

/// Narrow every project [client] fetches to the platforms of the repository
/// [cfg] belongs to, telling [say] once which ones were inferred.
void narrowToRepo(final ManagementClient client, final ProjectConfig cfg,
    final void Function(String line) say) {
  client.repoPlatforms = (final List<AppPlatform> project) {
    final RepoPlatforms r = resolveRepoPlatforms(
        projectPlatforms: project,
        pinned: cfg.platforms,
        root: cfg.root ?? Directory.current.path);
    if (r.inferred != null && r.problem == null) {
      final String line = inferredNotice(r, project);
      if (_told.add(line)) say(line);
    }
    return (platforms: r.platforms, problem: r.problem);
  };
  client.repoLocales = (final ProjectData project, final FlavorData flavor) {
    if (project.repoProblem != null) return null;
    final RepoLocales r = resolveRepoLocales(cfg, project, flavor);
    if (r.left.isNotEmpty) {
      final String line = leftOutNotice(r, project);
      if (_told.add(line)) say(line);
    }
    return r.held;
  };
}

/// `platforms` of the config at [root], or null when there is no config or
/// it pins none: the checks that read the repository's files then run for
/// every platform, as they always did.
List<AppPlatform>? pinnedPlatformsAt(final String root) {
  try {
    final File f = File(p.join(root, kProjectConfigName));
    if (!f.existsSync()) return null;
    return ProjectConfig.load(path: f.path).platforms;
  } on Object {
    return null;
  }
}

bool holdsPlatform(
        final List<AppPlatform>? pinned, final AppPlatform platform) =>
    pinned == null || pinned.contains(platform);
