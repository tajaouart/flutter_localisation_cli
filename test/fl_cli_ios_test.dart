/// The `fl` binary on an iOS project, end to end: config file, flags, exit
/// codes, what lands on disk and what reaches the backend.
///
/// `pull`, `export` and `import` each have a platform branch in `bin/fl.dart`
/// that no `Operations` test can reach; these run the real command against a
/// backend on a local port.
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fake_backend.dart';

class Run {
  Run(this.code, this.out, this.err);

  final int code;
  final String out;
  final String err;

  Map<String, dynamic> get json {
    final int start = out.indexOf('{');
    return jsonDecode(out.substring(start)) as Map<String, dynamic>;
  }
}

void main() {
  late FakeBackend backend;
  late Directory tmp;

  Future<Run> fl(final List<String> args) async {
    final ProcessResult r = await Process.run(
      'dart',
      <String>['run', p.join(packageRoot(), 'bin', 'fl.dart'), ...args],
      workingDirectory: tmp.path,
      environment: <String, String>{
        'FL_API_TOKEN': 'flk_live_test',
        'HOME': tmp.path,
      },
    );
    return Run(r.exitCode, r.stdout as String, r.stderr as String);
  }

  setUpAll(() async => backend = await FakeBackend.start());
  tearDownAll(() => backend.close());

  setUp(() {
    backend.platforms = <String>['ios'];
    backend.imports.clear();
    tmp = Directory(Directory.systemTemp.createTempSync('fl_cli_ios_test').resolveSymbolicLinksSync());
    File(p.join(tmp.path, 'flutterlocalisation.json')).writeAsStringSync(jsonEncode(<String, String>{
      'base_url': backend.url,
      'project': 'Gush',
      'arb_dir': 'lib/l10n',
      'xcstrings_dir': 'Resources',
    }));
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  File catalog() => File(p.join(tmp.path, 'Resources', 'Localizable.xcstrings'));
  Iterable<String> arbsOnDisk() => tmp
      .listSync(recursive: true)
      .map((final FileSystemEntity e) => e.path)
      .where((final String path) => path.endsWith('.arb'));

  test('pull writes the catalog as served and no ARB for an iOS project', () async {
    final Run r = await fl(<String>['pull', '--no-git']);
    expect(r.code, 0, reason: r.err);
    expect(r.out, contains('String Catalog'));
    expect(catalog().readAsStringSync(), kServedCatalog);
    expect(File(p.join(tmp.path, 'Resources', 'InfoPlist.xcstrings')).existsSync(), isFalse);
    expect(arbsOnDisk(), isEmpty);
    expect(r.out, isNot(contains('regenerate the Dart')), reason: 'no gen_l10n step for iOS');
  });

  test('pull --dry-run touches nothing', () async {
    final Run r = await fl(<String>['--dry-run', 'pull']);
    expect(r.code, 0, reason: r.err);
    expect(r.out, contains('DRY RUN'));
    expect(catalog().existsSync(), isFalse);
  });

  test('pull stops when the catalog holds a key the service lacks, and --adopt imports it', () async {
    catalog()
      ..createSync(recursive: true)
      ..writeAsStringSync(kCatalogWithLocalKey);

    final Run refused = await fl(<String>['pull', '--no-git']);
    expect(refused.code, 1);
    expect(refused.err, contains('Localizable.xcstrings has 1 key(s)'));
    expect(refused.err, contains('local only'));
    expect(refused.err, contains('fl pull --adopt'));
    expect(backend.imports, isEmpty);
    expect(catalog().readAsStringSync(), kCatalogWithLocalKey);

    final Run adopted = await fl(<String>['pull', '--no-git', '--adopt', '--json']);
    expect(adopted.code, 0, reason: adopted.err);
    expect(backend.imports, hasLength(1));
    expect(backend.imports.single.hasLanguage, isFalse);
    expect(backend.imports.single.fileName, 'Localizable.xcstrings');
    expect(adopted.json['adopted'], <String>['local only']);
    expect(adopted.json['method'], 'api');
    expect(adopted.json['catalog_dir'], p.join(tmp.path, 'Resources'));
    expect(adopted.json.containsKey('template'), isFalse);
    expect(catalog().readAsStringSync(), kServedCatalog);
  });

  test('pull --discard-local takes the service copy over the Xcode edit', () async {
    catalog()
      ..createSync(recursive: true)
      ..writeAsStringSync(kCatalogWithLocalKey);
    final Run r = await fl(<String>['pull', '--no-git', '--discard-local']);
    expect(r.code, 0, reason: r.err);
    expect(backend.imports, isEmpty);
    expect(catalog().readAsStringSync(), kServedCatalog);
  });

  test('pull on a mixed project writes the ARBs and the catalog in their own folders', () async {
    backend.platforms = <String>['flutter', 'ios'];
    final Run r = await fl(<String>['pull', '--no-git', '--json']);
    expect(r.code, 0, reason: r.err);
    expect(File(p.join(tmp.path, 'lib', 'l10n', 'app_en.arb')).existsSync(), isTrue);
    expect(catalog().readAsStringSync(), kServedCatalog);
    expect(r.json['template'], 'app_en.arb');
    expect(r.json['dir'], p.join(tmp.path, 'lib', 'l10n'));
    expect(r.json['catalog_dir'], p.join(tmp.path, 'Resources'));
    final List<dynamic> files = r.json['files'] as List<dynamic>;
    expect(files.map((final dynamic f) => (f as Map<String, dynamic>)['file']),
        containsAll(<String>['app_en.arb', 'Localizable.xcstrings']));
  });

  test('export writes the catalog into the given folder and reports it', () async {
    final Run r = await fl(<String>['export', 'out', '--json']);
    expect(r.code, 0, reason: r.err);
    expect(File(p.join(tmp.path, 'out', 'Localizable.xcstrings')).readAsStringSync(), kServedCatalog);
    expect(r.json['catalog_dir'], 'out');
    expect(r.json.containsKey('template'), isFalse);
    expect(arbsOnDisk(), isEmpty);
  });

  test('export refuses to drop a key staged in the catalog', () async {
    catalog()
      ..createSync(recursive: true)
      ..writeAsStringSync(kCatalogWithLocalKey);
    final Run r = await fl(<String>['export']);
    expect(r.code, 1);
    expect(r.err, contains('local only'));
    expect(r.err, contains('--discard-local'));
    expect(catalog().readAsStringSync(), kCatalogWithLocalKey);
  });

  test('import sends a catalog without a language and reports its locales', () async {
    final File staged = File(p.join(tmp.path, 'Staged.xcstrings'))..writeAsStringSync(kCatalogWithLocalKey);
    final Run r = await fl(<String>['import', staged.path, '--json']);
    expect(r.code, 0, reason: r.err);
    expect(backend.imports, hasLength(1));
    expect(backend.imports.single.hasLanguage, isFalse);
    expect(backend.imports.single.fileName, 'Staged.xcstrings');
    expect(r.json['ok'], isTrue);
    expect(r.json['locales'], <String>['en']);
  });

  test('import --dry-run counts catalog keys and posts nothing', () async {
    final File staged = File(p.join(tmp.path, 'Staged.xcstrings'))..writeAsStringSync(kCatalogWithLocalKey);
    final Run r = await fl(<String>['--dry-run', 'import', staged.path, '--json']);
    expect(r.code, 0, reason: r.err);
    expect(r.json['keys'], 2);
    expect(r.json['format'], 'xcstrings');
    expect(backend.imports, isEmpty);
  });

  test('projects lists what each project ships', () async {
    final Run r = await fl(<String>['projects', '--json']);
    expect(r.code, 0, reason: r.err);
    expect(r.out, contains('"ios"'));
  });
}
