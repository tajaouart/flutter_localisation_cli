import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:flutter_localisation_cli/src/init_detect.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('init_detect'));
  tearDown(() => tmp.deleteSync(recursive: true));

  void write(final String rel, [final String body = '']) =>
      File(p.join(tmp.path, rel))
        ..createSync(recursive: true)
        ..writeAsStringSync(body);

  group('l10nArbDir', () {
    test('reads arb-dir, ignoring quotes and comments', () {
      write('l10n.yaml', '# generated\narb-dir: "lib/l10n" # arbs\n');
      expect(l10nArbDir(tmp), 'lib/l10n');
    });
    test('null without the file or the key', () {
      expect(l10nArbDir(tmp), isNull);
      write('l10n.yaml', 'output-dir: lib/gen\n');
      expect(l10nArbDir(tmp), isNull);
    });
  });

  group('existingCatalogDir', () {
    test('finds the shallowest catalog and skips Pods', () {
      write('Pods/Dep/Localizable.xcstrings');
      write('App/Resources/Localizable.xcstrings');
      write('App/Widget/Nested/Localizable.xcstrings');
      expect(existingCatalogDir(tmp), p.join('App', 'Resources'));
    });
    test('null when none', () => expect(existingCatalogDir(tmp), isNull));
  });

  group('defaultCatalogDir', () {
    test('beside Info.plist of a Flutter iOS target', () {
      write('ios/Runner/Info.plist');
      expect(defaultCatalogDir(tmp), p.join('ios', 'Runner'));
    });
    test('the app folder of a bare Xcode project', () {
      write('Shop.xcodeproj/project.pbxproj');
      write('Shop/ContentView.swift');
      expect(defaultCatalogDir(tmp), 'Shop');
    });
    test('the root otherwise', () => expect(defaultCatalogDir(tmp), '.'));
  });

  test('Prompter returns defaults when not interactive', () {
    final Prompter ask = Prompter(interactive: false);
    expect(ask.ask('q', 'd'), 'd');
    expect(ask.confirm('q', fallback: false), isFalse);
    expect(ask.choose('q', <String>['a', 'b']), isNull);
    expect(ask.choose('q', <String>['a', 'b'], fallback: 1), 1);
    expect(ask.choose('q', <String>['only']), 0);
  });
}
