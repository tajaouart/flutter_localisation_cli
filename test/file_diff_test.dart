import 'package:flutter_localisation_cli/src/angular.dart';
import 'package:flutter_localisation_cli/src/file_diff.dart';
import 'package:test/test.dart';

void main() {
  group('compareMessages', () {
    final FileDiff d = compareMessages(
      <String, String>{'b': 'B', 'a': 'A2', 'new': 'N'},
      <String, String>{'a': 'A', 'b': 'B', 'old': 'O'},
      language: 'en',
      isBase: true,
      format: 'arb',
    );

    test('sorts every key into one list', () {
      expect(d.added, <String>['new']);
      expect(d.changed.keys, <String>['a']);
      expect(d.changed['a'], (local: 'A2', remote: 'A'));
      expect(d.same, 1);
      expect(d.gone, <String>['old']);
      expect(d.isEmpty, isFalse);
    });

    test('reads in a few lines and lists every key in json', () {
      final String text = describeDiff(d, 'app_en.arb');
      expect(text, contains('app_en.arb against "en" (the source)'));
      expect(text, contains('1 new, not on the service yet: new'));
      expect(text, contains('1 only on the service: old'));
      expect(d.toJson()['changed'], <String, dynamic>{
        'a': <String, String>{'file': 'A2', 'service': 'A'},
      });
    });

    test('a long list is cut on screen', () {
      final FileDiff many = compareMessages(
        <String, String>{for (int i = 0; i < 30; i++) 'k$i': 'v'},
        <String, String>{},
        language: 'fr',
        isBase: false,
        format: 'angular',
      );
      expect(describeDiff(many, 'messages.fr.arb', limit: 5),
          contains('… and 25 more (--json lists all)'));
    });
  });

  group('inSourceOrder', () {
    test('puts @@locale first, then the source order, then the rest sorted',
        () {
      final Map<String, dynamic> doc = inSourceOrder(
        <String, dynamic>{'z': 1, 'a': 2, '@@locale': 'fr', 'm': 3, 'b': 4},
        <String>['m', 'z'],
      );
      expect(doc.keys, <String>['@@locale', 'm', 'z', 'a', 'b']);
    });

    test('leaves the document alone without a source', () {
      final Map<String, dynamic> doc = <String, dynamic>{'b': 1, 'a': 2};
      expect(inSourceOrder(doc, null).keys, <String>['b', 'a']);
    });
  });
}
