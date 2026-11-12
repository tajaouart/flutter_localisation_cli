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
}
