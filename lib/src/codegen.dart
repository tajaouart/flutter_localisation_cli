/// The arguments and messages around `dart run flutter_localisation`, the
/// generator `fl sync` and `fl init` end with.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:flutter_localisation_cli/src/l10n_doctor.dart';

/// The generator's two arguments for [arbDir]: the folder holding the flavor
/// folders and the flavor folder's name.
///
/// `arb_dir` points at the flavor folder (arbs/Default). The generator reads
/// `l10n.yaml` from its working directory, so it runs from [projectRoot] and
/// gets the folder relative to it when it is inside; an absolute path there
/// would end up in the l10n.yaml it writes.
({String flavorsFolder, String flavor}) generatorTarget(
  final String arbDir,
  final String projectRoot,
) {
  final String dir =
      p.normalize(p.isAbsolute(arbDir) ? arbDir : p.join(projectRoot, arbDir));
  final String root = p.normalize(projectRoot);
  final String parent = p.dirname(dir);
  final String flavorsFolder = p.isWithin(root, parent)
      ? p.relative(parent, from: root)
      : parent == root
          ? '.'
          : parent;
  // Forward slashes on every platform: the folder ends up in the l10n.yaml the
  // generator writes, which the whole team shares.
  return (
    flavorsFolder: flavorsFolder.replaceAll(r'\', '/'),
    flavor: p.basename(dir)
  );
}

/// The last [lines] non-empty lines of [text].
String tail(final String text, {final int lines = 20}) {
  final List<String> all = text
      .split('\n')
      .map((final String l) => l.trimRight())
      .where((final String l) => l.isNotEmpty)
      .toList();
  return all.skip(all.length > lines ? all.length - lines : 0).join('\n');
}

/// True for an app set up for Flutter's own gen-l10n (it has an `l10n.yaml`)
/// that does not depend on the flutter_localisation package. Running the
/// package's generator there fails with "Could not find package", which reads
/// as a broken setup when the app is fine.
bool usesPlainGenL10n(final Directory root) =>
    File(p.join(root.path, 'l10n.yaml')).existsSync() &&
    !dependsOn(root, 'flutter_localisation');
