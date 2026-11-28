/// Which of a project's languages the repository at hand ships.
///
/// A project shared by several apps has the languages of all of them: an
/// iPhone app in nine beside a website in two. `locales` in the website's
/// `flutterlocalisation.json` names its own; without it, a repository of
/// such a project that already has translated files keeps to those
/// languages, so a pull never adds seven files of untranslated text and a
/// retranslation never pays for them.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:flutter_localisation_cli/src/angular.dart';
import 'package:flutter_localisation_cli/src/config.dart';
import 'package:flutter_localisation_cli/src/locales.dart';
import 'package:flutter_localisation_cli/src/management_client.dart';
import 'package:flutter_localisation_cli/src/ngx.dart';
import 'package:flutter_localisation_cli/src/platform.dart';

class RepoLocales {
  RepoLocales(this.held, {this.left = const <String>[]});

  /// The codes shipped here beside the base; null is every language.
  final Set<String>? held;

  /// Languages left out because no file here has them; empty when pinned.
  final List<String> left;
}

/// The target languages among [codes] with a translated file in [cfg]'s
/// folders, or null when [platforms] include one whose files do not tell
/// (a String Catalog holds every language in one file).
Set<String>? localesWithFiles(final ProjectConfig cfg,
    final List<AppPlatform> platforms, final List<String> codes) {
  final Set<String> found = <String>{};
  for (final AppPlatform platform in platforms) {
    switch (platform) {
      case AppPlatform.ios:
        return null;
      case AppPlatform.angular:
        for (final String code in codes) {
          if (File(p.join(cfg.angularLocaleDir, angularTargetName(code)))
              .existsSync()) {
            found.add(code);
          }
        }
      case AppPlatform.ngx:
        for (final String code in codes) {
          if (File(p.join(cfg.ngxLocaleDir, ngxFileName(code))).existsSync()) {
            found.add(code);
          }
        }
      case AppPlatform.flutter:
        final Directory dir = Directory(cfg.arbDir ?? 'arbs/Default');
        if (!dir.existsSync()) break;
        final List<String> names = <String>[
          for (final FileSystemEntity e in dir.listSync())
            if (e is File) p.basename(e.path),
        ];
        for (final String code in codes) {
          final String suffix = '_${arbSuffix(code)}.arb';
          if (names.any((final String n) => n.endsWith(suffix))) {
            found.add(code);
          }
        }
    }
  }
  return found;
}

/// Settle the languages this repository ships among [project]'s [flavor]:
/// `locales` of the config when given, every language of a project with one
/// platform, else the ones the repository already has files for.
RepoLocales resolveRepoLocales(final ProjectConfig cfg,
    final ProjectData project, final FlavorData flavor) {
  final List<String> codes = <String>[
    for (final LanguageData l in flavor.languages)
      if (!l.isBase) l.code,
  ];
  final List<String>? pinned = cfg.locales;
  if (pinned != null) {
    return RepoLocales(<String>{
      for (final String code in codes)
        if (pinned.contains(canonicalizeOrKeep(code))) code,
    });
  }
  if (project.platforms.length < 2 || cfg.root == null) {
    return RepoLocales(null);
  }
  final Set<String>? found =
      localesWithFiles(cfg, project.localPlatforms, codes);
  if (found == null || found.isEmpty || found.length == codes.length) {
    return RepoLocales(null);
  }
  return RepoLocales(found, left: <String>[
    for (final String code in codes)
      if (!found.contains(code)) code,
  ]);
}

/// The line telling which languages were left out and how to take them.
String leftOutNotice(final RepoLocales r, final ProjectData project,
    {final String configName = 'flutterlocalisation.json'}) {
  final List<String> held = r.held!.toList();
  final List<AppPlatform> others = <AppPlatform>[
    for (final AppPlatform pl in project.platforms)
      if (!project.localPlatforms.contains(pl)) pl,
  ];
  return 'This repository ships ${held.join(', ')}; ${r.left.join(', ')} '
      '${r.left.length == 1 ? 'has' : 'have'} no file here and '
      '${r.left.length == 1 ? 'is' : 'are'} left to '
      '${others.isEmpty ? 'the project\'s other apps' : platformLabels(others, separator: ', ')}. '
      'Pin it with "locales": [${held.map((final String c) => '"$c"').join(', ')}] '
      'in $configName, adding any language this repository should ship too.';
}
