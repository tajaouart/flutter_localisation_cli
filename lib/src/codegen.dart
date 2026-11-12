/// The arguments and messages around `dart run flutter_localisation`, the
/// generator `fl sync` and `fl init` end with.
library;

import 'package:path/path.dart' as p;

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
  return (flavorsFolder: flavorsFolder, flavor: p.basename(dir));
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
