import 'dart:io';

import 'package:flutter_localisation_cli/src/codegen.dart';
import 'package:test/test.dart';

void main() {
  group('generatorTarget', () {
    test('an absolute arb_dir inside the app is passed relative to it', () {
      expect(
        generatorTarget('/Volumes/x/app/arbs/Default', '/Volumes/x/app'),
        (flavorsFolder: 'arbs', flavor: 'Default'),
      );
    });

    test('a relative arb_dir is read against the app root', () {
      expect(generatorTarget('arbs/staging', '/work/app'),
          (flavorsFolder: 'arbs', flavor: 'staging'));
      expect(generatorTarget('./l10n/arbs/Default/', '/work/app'),
          (flavorsFolder: 'l10n/arbs', flavor: 'Default'));
    });

    test('a flavor folder at the root and one outside the app', () {
      expect(generatorTarget('/work/app/Default', '/work/app'),
          (flavorsFolder: '.', flavor: 'Default'));
      expect(generatorTarget('/shared/arbs/Default', '/work/app'),
          (flavorsFolder: '/shared/arbs', flavor: 'Default'));
    });
  });

  test('tail keeps the last non-empty lines', () {
    final String text =
        List<String>.generate(30, (final int i) => 'line $i').join('\n\n');
    expect(tail(text, lines: 2), 'line 28\nline 29');
    expect(tail('one\n\n'), 'one');
  });

  test('an app with l10n.yaml and no flutter_localisation uses gen-l10n', () {
    final Directory root = Directory.systemTemp.createTempSync('fl_codegen');
    addTearDown(() => root.deleteSync(recursive: true));
    final File pubspec = File('${root.path}/pubspec.yaml')
      ..writeAsStringSync('name: app\ndependencies:\n  intl: any\n');
    expect(usesPlainGenL10n(root), isFalse);

    File('${root.path}/l10n.yaml').writeAsStringSync('arb-dir: lib/l10n\n');
    expect(usesPlainGenL10n(root), isTrue);

    pubspec.writeAsStringSync(
        'name: app\ndependencies:\n  flutter_localisation: ^2.7.2\n');
    expect(usesPlainGenL10n(root), isFalse);
  });
}
