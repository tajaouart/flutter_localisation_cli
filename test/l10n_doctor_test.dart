import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:flutter_localisation_cli/src/l10n_doctor.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('l10n_doctor'));
  tearDown(() => tmp.deleteSync(recursive: true));

  void write(final String rel, final String body) => File(p.join(tmp.path, rel))
    ..createSync(recursive: true)
    ..writeAsStringSync(body);
  String read(final String rel) =>
      File(p.join(tmp.path, rel)).readAsStringSync();
  List<String> codes(final L10nDoctorReport r) =>
      r.issues.map((final L10nIssue i) => i.code).toList();

  const String pubspec = 'name: my_app\n'
      'dependencies:\n'
      '  flutter:\n'
      '    sdk: flutter\n'
      '  flutter_localizations:\n'
      '    sdk: flutter\n'
      '  intl: any\n'
      '\n'
      'flutter:\n'
      '  uses-material-design: true\n';

  test('not applicable without l10n.yaml or flutter_gen imports', () {
    write('pubspec.yaml', pubspec);
    final L10nDoctorReport r = checkL10nSetup(tmp);
    expect(r.applicable, isFalse);
    expect(r.ok, isTrue);
  });

  test('current setup has no issues', () {
    write(
        'pubspec.yaml',
        pubspec.replaceFirst(
            'flutter:\n  uses', 'flutter:\n  generate: true\n  uses'));
    write('l10n.yaml', 'arb-dir: lib/l10n\n');
    final L10nDoctorReport r = checkL10nSetup(tmp);
    expect(r.applicable, isTrue);
    expect(r.issues, isEmpty);
  });

  test('reports all three without touching files', () {
    write('pubspec.yaml', pubspec);
    write('l10n.yaml', 'arb-dir: lib/l10n\nsynthetic-package: true\n');
    write(
      'lib/main.dart',
      "import 'package:flutter_gen/gen_l10n/app_localizations.dart';\n",
    );
    final L10nDoctorReport r = checkL10nSetup(tmp);
    expect(
      codes(r),
      <String>['synthetic-package', 'generate-flag', 'flutter-gen-import'],
    );
    expect(r.ok, isFalse);
    expect(read('l10n.yaml'), contains('synthetic-package: true'));
    expect(read('lib/main.dart'), contains('flutter_gen'));
  });

  test('fix rewrites l10n.yaml, pubspec and imports', () {
    write('pubspec.yaml', pubspec);
    write('l10n.yaml', 'arb-dir: lib/l10n\nsynthetic-package: true\n');
    write(
      'lib/main.dart',
      "import 'package:flutter_gen/gen_l10n/app_localizations.dart';\n",
    );
    write(
      'test/widget_test.dart',
      "import 'package:flutter_gen/gen_l10n/app_localizations.dart';\n",
    );
    final L10nDoctorReport r = checkL10nSetup(tmp, fix: true);
    expect(r.ok, isTrue);
    expect(read('l10n.yaml'), 'arb-dir: lib/l10n\n');
    expect(read('pubspec.yaml'),
        contains('flutter:\n  generate: true\n  uses-material-design: true'));
    expect(read('pubspec.yaml'), contains('  flutter:\n    sdk: flutter'));
    for (final String f in <String>['lib/main.dart', 'test/widget_test.dart']) {
      expect(
        read(f),
        "import 'package:my_app/l10n/app_localizations.dart';\n",
      );
    }
    expect(checkL10nSetup(tmp).issues, isEmpty);
  });

  test('imports follow output-dir', () {
    write('pubspec.yaml', pubspec);
    write('l10n.yaml', 'arb-dir: assets/arb\noutput-dir: lib/gen/l10n\n');
    write(
        'lib/a.dart', "import 'package:flutter_gen/gen_l10n/strings.dart';\n");
    checkL10nSetup(tmp, fix: true);
    expect(
        read('lib/a.dart'), "import 'package:my_app/gen/l10n/strings.dart';\n");
  });

  test('output outside lib is reported but not rewritten', () {
    write('pubspec.yaml', pubspec);
    write('l10n.yaml', 'arb-dir: assets/arb\n');
    write(
        'lib/a.dart', "import 'package:flutter_gen/gen_l10n/strings.dart';\n");
    final L10nDoctorReport r = checkL10nSetup(tmp, fix: true);
    expect(r.ok, isFalse);
    expect(read('lib/a.dart'), contains('flutter_gen'));
  });

  test('generate: false becomes true, and a pubspec without flutter gets one',
      () {
    write('pubspec.yaml', 'name: a\nflutter:\n    generate: false\n');
    write('l10n.yaml', 'arb-dir: lib/l10n\n');
    checkL10nSetup(tmp, fix: true);
    expect(read('pubspec.yaml'), 'name: a\nflutter:\n    generate: true\n');

    write('pubspec.yaml', 'name: a\n');
    checkL10nSetup(tmp, fix: true);
    expect(read('pubspec.yaml'), 'name: a\n\nflutter:\n  generate: true\n');
  });

  test('missing flutter_localizations and intl are reported, not fixed', () {
    write('pubspec.yaml', 'name: a\nflutter:\n  generate: true\n');
    write('l10n.yaml', 'arb-dir: lib/l10n\n');
    final L10nDoctorReport r = checkL10nSetup(tmp, fix: true);
    expect(codes(r), <String>['dependencies']);
    expect(r.issues.single.message, contains('--sdk=flutter'));
    expect(r.issues.single.message, contains('intl:any'));
    expect(r.ok, isFalse);
  });

  test('synthetic-package: false is left alone', () {
    write('pubspec.yaml', '$pubspec  generate: true\n');
    write('l10n.yaml', 'arb-dir: lib/l10n\nsynthetic-package: false\n');
    expect(checkL10nSetup(tmp).issues, isEmpty);
  });
}
