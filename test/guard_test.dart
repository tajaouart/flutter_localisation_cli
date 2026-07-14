import 'dart:convert';
import 'dart:io';

import 'package:flutter_localisation_cli/src/guard.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('fl_guard_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('deriveGuardGlobs reads arb_dir (config) + l10n.yaml dirs + methods file',
      () {
    File('${tmp.path}/l10n.yaml').writeAsStringSync(
      'arb-dir: lib/l10n\n'
      'output-dir: lib/localization/generated\n'
      'output-localization-file: app_localizations.dart\n',
    );

    final List<String> globs =
        deriveGuardGlobs(tmp, arbDirFromConfig: './arbs/');

    expect(globs, contains('arbs/**'));
    expect(globs, contains('lib/l10n/**'));
    expect(globs, contains('lib/localization/generated/**'));
    expect(globs, contains('lib/generated_translation_methods.dart'));
  });

  test('deriveGuardGlobs always includes the generated methods file', () {
    final List<String> globs = deriveGuardGlobs(tmp);
    expect(globs, <String>['lib/generated_translation_methods.dart']);
  });

  test('installGuard creates settings.json with Edit+Write deny rules', () {
    final GuardResult r =
        installGuard(tmp, globs: <String>['arbs/**', 'lib/x.dart']);

    expect(r.created, isTrue);
    final Map<String, dynamic> json = jsonDecode(
      File('${tmp.path}/.claude/settings.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final List<dynamic> deny =
        (json['permissions'] as Map<String, dynamic>)['deny'] as List<dynamic>;
    expect(deny, containsAll(<String>[
      'Edit(arbs/**)',
      'Write(arbs/**)',
      'Edit(lib/x.dart)',
      'Write(lib/x.dart)',
    ]),);
  });

  test('installGuard merges into existing settings without clobbering or duping',
      () {
    final Directory claude = Directory('${tmp.path}/.claude')..createSync();
    File('${claude.path}/settings.json').writeAsStringSync(jsonEncode(
      <String, dynamic>{
        'permissions': <String, dynamic>{
          'allow': <String>['Bash(git *)'],
          'deny': <String>['Edit(arbs/**)'],
        },
        'model': 'sonnet',
      },
    ),);

    final GuardResult r =
        installGuard(tmp, globs: <String>['arbs/**', 'lib/gen.dart']);

    expect(r.created, isFalse);
    // Only the genuinely-new rules are reported as added.
    expect(r.added, isNot(contains('Edit(arbs/**)')));
    expect(r.added, contains('Edit(lib/gen.dart)'));

    final Map<String, dynamic> json = jsonDecode(
      File('${claude.path}/settings.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final Map<String, dynamic> perms =
        json['permissions'] as Map<String, dynamic>;
    // Existing settings preserved.
    expect(json['model'], 'sonnet');
    expect(perms['allow'], <String>['Bash(git *)']);
    // No duplicate of the pre-existing deny rule.
    final List<dynamic> deny = perms['deny'] as List<dynamic>;
    expect(deny.where((final dynamic e) => e == 'Edit(arbs/**)').length, 1);
  });
}
