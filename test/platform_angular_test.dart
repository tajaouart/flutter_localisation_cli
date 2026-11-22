import 'package:flutter_localisation_cli/src/angular.dart';
import 'package:flutter_localisation_cli/src/platform.dart';
import 'package:test/test.dart';

void main() {
  group('AppPlatform', () {
    test('reads the service names, in the service order, Flutter by default',
        () {
      expect(platformsFromJson(<String>['angular', 'flutter', 'android']),
          <AppPlatform>[AppPlatform.flutter, AppPlatform.angular]);
      expect(platformsFromJson(null), <AppPlatform>[AppPlatform.flutter]);
      expect(platformsFromJson(<String>['nope']),
          <AppPlatform>[AppPlatform.flutter]);
    });

    test('every platform says what it writes and whether it gets live updates',
        () {
      for (final AppPlatform p in AppPlatform.values) {
        expect(AppPlatform.fromWire(p.wire), p);
        expect(p.label, isNotEmpty);
        expect(p.files, isNotEmpty);
      }
      expect(AppPlatform.angular.liveUpdates, isFalse);
      expect(
          platformLabels(<AppPlatform>[AppPlatform.flutter, AppPlatform.ios]),
          'Flutter + iOS');
      expect(platformWires(<AppPlatform>[AppPlatform.angular]),
          <String>['angular']);
    });
  });

  group('Angular files', () {
    test(
        'an extraction and a translated file are recognised, a Flutter ARB is not',
        () {
      expect(
          isAngularArbJson(<String, dynamic>{
            '@@locale': 'en',
            'a': 'A',
            '@a': <String, dynamic>{'x-locations': <dynamic>[]},
          }),
          isTrue);
      expect(
          isAngularArbJson(
              <String, dynamic>{'@@locale': 'fr', 'a': r'Hi {$INTERPOLATION}'}),
          isTrue);
      expect(
          isAngularArbJson(
              <String, dynamic>{'@@locale': 'fr', 'a': 'Hi {name}'}),
          isFalse);
      expect(isAngularArbJson(<String, dynamic>{'a': r'{$X}'}), isFalse);
      expect(angularTargetName('pt-BR'), 'messages.pt-BR.arb');
    });

    test('names what the service would leave out, the hash sub-message once',
        () {
      final List<String> problems = angularImportProblems(<String, dynamic>{
        '@@locale': 'en',
        'home.updated': r'Updated {$ICU}',
        '2489446912124995477':
            '{VAR_PLURAL, plural, other {{INTERPOLATION} min}}',
        '7353399126222573266': 'No id here',
        'home.title': 'Fine',
      });
      expect(problems, hasLength(2));
      expect(problems.first, startsWith('home.updated: a plural or select'));
      expect(problems.last, startsWith('7353399126222573266: no @@id'));
    });
  });
}
