import 'dart:convert';

import 'package:flutter_localisation_cli/src/management_client.dart';
import 'package:flutter_localisation_cli/src/operations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// Captures the decoded JSON body of the last matching request.
class _Capture {
  Map<String, dynamic>? body;
}

void main() {
  group('addKey metadata round-trip', () {
    test('includes description, placeholders and is_placeholders_enabled when provided',
        () async {
      final _Capture cap = _Capture();
      final MockClient mock = MockClient((final http.Request req) async {
        if (req.url.path == '/api/projects/7/translation_keys/') {
          cap.body = jsonDecode(req.body) as Map<String, dynamic>;
        }
        return http.Response('{}', 201);
      });
      final ManagementClient client =
          ManagementClient(baseUrl: 'http://t', token: 'x', httpClient: mock);

      await client.addKey(
        7,
        'items',
        'You have {count} items',
        placeholders: <String, dynamic>{
          'count': <String, String>{'type': 'int', 'format': 'decimalPattern'},
        },
        isPlaceholdersEnabled: true,
        description: 'Count of items in the cart',
      );

      expect(cap.body, isNotNull);
      expect(cap.body!['key'], 'items');
      expect(cap.body!['base_value'], 'You have {count} items');
      expect(cap.body!['description'], 'Count of items in the cart');
      expect(cap.body!['is_placeholders_enabled'], true);
      expect(
        cap.body!['placeholders'],
        <String, dynamic>{
          'count': <String, dynamic>{'type': 'int', 'format': 'decimalPattern'},
        },
      );
    });

    test('omits metadata fields when not provided (empty map/string not sent)',
        () async {
      final _Capture cap = _Capture();
      final MockClient mock = MockClient((final http.Request req) async {
        if (req.url.path == '/api/projects/7/translation_keys/') {
          cap.body = jsonDecode(req.body) as Map<String, dynamic>;
        }
        return http.Response('{}', 201);
      });
      final ManagementClient client =
          ManagementClient(baseUrl: 'http://t', token: 'x', httpClient: mock);

      await client.addKey(7, 'greeting', 'Hello');

      expect(cap.body, isNotNull);
      expect(cap.body!.keys, containsAll(<String>['key', 'base_value']));
      expect(cap.body!.containsKey('description'), isFalse);
      expect(cap.body!.containsKey('placeholders'), isFalse);
      expect(cap.body!.containsKey('is_placeholders_enabled'), isFalse);
    });

    test('omits empty placeholders map and empty description', () async {
      final _Capture cap = _Capture();
      final MockClient mock = MockClient((final http.Request req) async {
        if (req.url.path == '/api/projects/7/translation_keys/') {
          cap.body = jsonDecode(req.body) as Map<String, dynamic>;
        }
        return http.Response('{}', 201);
      });
      final ManagementClient client =
          ManagementClient(baseUrl: 'http://t', token: 'x', httpClient: mock);

      await client.addKey(
        7,
        'greeting',
        'Hello',
        placeholders: <String, dynamic>{},
        description: '',
      );

      expect(cap.body!.containsKey('placeholders'), isFalse);
      expect(cap.body!.containsKey('description'), isFalse);
    });
  });

  group('updateTranslation metadata round-trip', () {
    test('includes description when provided', () async {
      final _Capture cap = _Capture();
      final MockClient mock = MockClient((final http.Request req) async {
        if (req.url.path == '/api/update_translation/42/') {
          cap.body = jsonDecode(req.body) as Map<String, dynamic>;
        }
        return http.Response('{}', 200);
      });
      final ManagementClient client =
          ManagementClient(baseUrl: 'http://t', token: 'x', httpClient: mock);

      await client.updateTranslation(
        42,
        value: 'Bonjour',
        description: 'The greeting shown on the home page',
      );

      expect(cap.body, isNotNull);
      expect(cap.body!['value'], 'Bonjour');
      expect(cap.body!['description'], 'The greeting shown on the home page');
    });

    test('omits description when not provided or empty', () async {
      final _Capture cap = _Capture();
      final MockClient mock = MockClient((final http.Request req) async {
        if (req.url.path == '/api/update_translation/42/') {
          cap.body = jsonDecode(req.body) as Map<String, dynamic>;
        }
        return http.Response('{}', 200);
      });
      final ManagementClient client =
          ManagementClient(baseUrl: 'http://t', token: 'x', httpClient: mock);

      await client.updateTranslation(42, value: 'Bonjour', description: '');

      expect(cap.body!['value'], 'Bonjour');
      expect(cap.body!.containsKey('description'), isFalse);
    });
  });

  group('TranslationEntry.fromJson', () {
    test('reads description and placeholders', () {
      final TranslationEntry e = TranslationEntry.fromJson(<String, dynamic>{
        'id': 1,
        'key': 'items',
        'value': 'You have {count} items',
        'description': 'Count of items',
        'placeholders': <String, dynamic>{
          'count': <String, dynamic>{'type': 'int', 'format': 'decimalPattern'},
        },
      });

      expect(e.description, 'Count of items');
      expect(
        e.placeholders,
        <String, dynamic>{
          'count': <String, dynamic>{'type': 'int', 'format': 'decimalPattern'},
        },
      );
    });

    test('defaults description to "" and placeholders to {} when absent', () {
      final TranslationEntry e = TranslationEntry.fromJson(<String, dynamic>{
        'id': 1,
        'key': 'greeting',
        'value': 'Hello',
      });

      expect(e.description, '');
      expect(e.placeholders, isEmpty);
    });
  });

  group('parsePlaceholderSpecs (--placeholder CLI parsing)', () {
    test('name:type:format parses into {name: {type, format}}', () {
      expect(
        parsePlaceholderSpecs(<String>['count:int:decimalPattern']),
        <String, dynamic>{
          'count': <String, String>{'type': 'int', 'format': 'decimalPattern'},
        },
      );
    });

    test('name:type parses without a format', () {
      expect(
        parsePlaceholderSpecs(<String>['count:num']),
        <String, dynamic>{
          'count': <String, String>{'type': 'num'},
        },
      );
    });

    test('bare name defaults type to String', () {
      expect(
        parsePlaceholderSpecs(<String>['name']),
        <String, dynamic>{
          'name': <String, String>{'type': 'String'},
        },
      );
    });

    test('multiple specs are all parsed', () {
      expect(
        parsePlaceholderSpecs(<String>['count:int', 'when:DateTime:yMd']),
        <String, dynamic>{
          'count': <String, String>{'type': 'int'},
          'when': <String, String>{'type': 'DateTime', 'format': 'yMd'},
        },
      );
    });

    test('empty list returns null (so no clobbering empty map is sent)', () {
      expect(parsePlaceholderSpecs(<String>[]), isNull);
    });
  });
}
