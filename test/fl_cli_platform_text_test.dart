/// `fl edit --target`, `--platforms`, `--max-length`, `fl shorten` and the
/// status lines, as typed, against a service that knows platform text and
/// one from before it.
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
}

void main() {
  late FakeBackend backend;
  late Directory tmp;
  late String checkout;

  Future<Run> fl(final List<String> args) async {
    final ProcessResult r = await Process.run(
      Platform.resolvedExecutable,
      <String>['run', p.join(packageRoot(), 'bin', 'fl.dart'), ...args],
      workingDirectory: checkout,
      environment: <String, String>{
        'FL_API_TOKEN': 'flk_live_test',
        'HOME': tmp.path,
        'USERPROFILE': tmp.path,
        'FL_NO_UPDATE_NOTICE': '1',
      },
    );
    return Run(r.exitCode, r.stdout as String, r.stderr as String);
  }

  setUpAll(() async => backend = await FakeBackend.start());
  tearDownAll(() => backend.close());

  setUp(() {
    backend
      ..platforms = <String>['flutter', 'ios']
      ..languages = <String>['en', 'fr']
      ..targets = <String, Map<String, dynamic>>{
        'fr': <String, dynamic>{'value': 'Nettoyage… {arg1} s restantes'},
      }
      ..platformText = true
      ..overrides = <String, List<Map<String, dynamic>>>{}
      ..keyPlatforms = <String>[]
      ..keyMaxLength = <String, int>{};
    backend.updates.clear();
    backend.keyPosts.clear();
    backend.shortens.clear();
    tmp = Directory(Directory.systemTemp
        .createTempSync('fl_cli_platform_text_test')
        .resolveSymbolicLinksSync());
    checkout = p.join(tmp.path, 'app');
    Directory(checkout).createSync();
    File(p.join(checkout, 'flutterlocalisation.json'))
        .writeAsStringSync(jsonEncode(<String, Object>{
      'base_url': backend.url,
      'project': 'Gush',
      'arb_dir': 'lib/l10n',
    }));
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('edit --target writes that target\'s text of the row', () async {
    final Run r = await fl(<String>[
      'edit', 'running', '--locale', 'fr', '--target', 'ios', //
      '--value', '{arg1} s',
    ]);
    expect(r.code, 0, reason: r.err);
    expect(r.out, contains('Wrote the ios text of "running %lld" [fr]'));
    expect(backend.updates.single, <String, dynamic>{
      'id': 501,
      'target': 'ios',
      'value': '{arg1} s',
    });
  });

  test('edit --target takes the text as a second argument', () async {
    final Run r =
        await fl(<String>['edit', 'running', '--target', 'ios', '{arg1} s']);
    expect(r.code, 0, reason: r.err);
    expect(backend.updates.single, <String, dynamic>{
      'id': 1,
      'target': 'ios',
      'value': '{arg1} s',
    });
  });

  test('edit --target --clear sends an empty value for that target', () async {
    backend.overrides = <String, List<Map<String, dynamic>>>{
      'en': <Map<String, dynamic>>[
        <String, dynamic>{'target': 'ios/applewatch', 'value': '{arg1}s'},
      ],
    };
    final Run r = await fl(
        <String>['edit', 'running', '--target', 'ios/applewatch', '--clear']);
    expect(r.code, 0, reason: r.err);
    expect(r.out, contains('Removed the ios/applewatch text'));
    expect(backend.updates.single, <String, dynamic>{
      'id': 1,
      'target': 'ios/applewatch',
      'value': '',
    });
  });

  test('edit --target says when the text is over the limit', () async {
    backend.keyMaxLength = <String, int>{'ios': 5};
    final Run r = await fl(<String>[
      'edit', 'running', '--target', 'ios', '--value', '{arg1} s to go', //
    ]);
    expect(r.code, 0, reason: r.err);
    expect(r.out, contains('over the ios limit of 5'));
  });

  test('edit --target must keep the placeholders of the full text', () async {
    final Run r = await fl(
        <String>['edit', 'running', '--target', 'ios', '--value', 'Busy']);
    expect(r.code, 1);
    expect(r.out, contains('must keep {arg1}'));
    expect(backend.updates, isEmpty);
  });

  test('edit --target with plural flags is refused', () async {
    final Run r = await fl(<String>[
      'edit', 'running', '--target', 'ios', '--value', '{arg1}', //
      '--plural-case', 'x',
    ]);
    expect(r.code, 1);
    expect(r.out, contains('one string'));
    expect(backend.updates, isEmpty);
  });

  test('edit --platforms --max-length re-posts the key with them', () async {
    backend.keyMaxLength = <String, int>{'flutter': 60};
    final Run r = await fl(<String>[
      'edit', 'running', '--platforms', 'ios', '--max-length', 'ios=20', //
      '--max-length', 'flutter=0',
    ]);
    expect(r.code, 0, reason: r.err);
    expect(r.out, contains('ships to ios only'));
    expect(backend.updates, isEmpty);
    expect(backend.keyPosts.single, <String, dynamic>{
      'key': 'running %lld',
      'base_value': 'Cleaning… {arg1} s left',
      'platforms': <String>['ios'],
      'max_length': <String, int>{'ios': 20},
    });
  });

  test('a platform the project does not ship is refused', () async {
    final Run r = await fl(<String>['edit', 'running', '--platforms', 'ngx']);
    expect(r.code, 1);
    expect(r.out, contains('does not ship to ngx'));
    expect(backend.keyPosts, isEmpty);
  });

  test('add --platforms --max-length sends them with the key', () async {
    final Run r = await fl(<String>[
      'add', 'promo', '--value', 'Save now', '--platforms', 'ios,flutter', //
      '--max-length', 'ios=12',
    ]);
    expect(r.code, 0, reason: r.err);
    expect(backend.keyPosts.single['platforms'], <String>['ios', 'flutter']);
    expect(backend.keyPosts.single['max_length'], <String, int>{'ios': 12});
  });

  test('an unknown target is a usage error', () async {
    final Run r = await fl(
        <String>['edit', 'running', '--target', 'android', '--value', 'x']);
    expect(r.code, 64);
    expect(r.err, contains('"android" is not a target'));
  });

  test('status names texts over the limit and texts to check', () async {
    backend.keyMaxLength = <String, int>{'ios': 5};
    backend.overrides = <String, List<Map<String, dynamic>>>{
      'fr': <Map<String, dynamic>>[
        <String, dynamic>{
          'target': 'ios',
          'value': '{arg1} s',
          'needs_review': true,
        },
      ],
    };
    final Run r = await fl(<String>['status']);
    expect(r.code, 0, reason: r.err);
    expect(r.out, contains('over the limit: 1 on ios'));
    expect(r.out, contains('1 platform text(s) to check'));
    expect(r.out, contains('`fl shorten --target ios`'));
  });

  test('shorten sends the keys over the limit and reports them fitting',
      () async {
    backend.keyMaxLength = <String, int>{'ios': 10};
    final Run r = await fl(<String>['shorten']);
    expect(r.code, 0, reason: '${r.out}${r.err}');
    expect(r.out, contains('Shortened 1/1 key(s) for ios'));
    expect(backend.shortens.single, <String, dynamic>{
      'keys': <String>['running %lld'],
      'target': 'ios',
    });
  });

  group('an older service', () {
    setUp(() => backend.platformText = false);

    test('refuses --target before writing anything', () async {
      final Run r = await fl(
          <String>['edit', 'running', '--target', 'ios', '--value', '{arg1}']);
      expect(r.code, 1);
      expect(r.err, contains('does not support platform text yet'));
      expect(backend.updates, isEmpty);
    });

    test('refuses add --platforms before adding the key', () async {
      final Run r = await fl(
          <String>['add', 'promo', '--value', 'Save', '--platforms', 'ios']);
      expect(r.code, 1);
      expect(r.err, contains('does not support platform text yet'));
      expect(backend.keyPosts, isEmpty);
    });

    test('refuses shorten', () async {
      final Run r = await fl(<String>['shorten', '--target', 'ios']);
      expect(r.code, 1);
      expect(r.err, contains('does not support platform text yet'));
      expect(backend.shortens, isEmpty);
    });

    test('a plain edit is sent as before', () async {
      final Run r = await fl(<String>['edit', 'running', '--value', '{arg1}']);
      expect(r.code, 0, reason: r.err);
      expect(backend.updates.single,
          <String, dynamic>{'id': 1, 'value': '{arg1}'});
    });
  });
}
