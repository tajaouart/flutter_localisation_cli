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

  test('installAgentDocs creates AGENTS.md + CLAUDE.md with the managed block',
      () {
    final AgentDocsResult r = installAgentDocs(
      tmp,
      projectLabel: 'Atelier',
      globs: <String>['arbs/**', 'lib/generated_translation_methods.dart'],
    );

    expect(r.files, hasLength(2));
    expect(r.created, hasLength(2));
    for (final String name in <String>['AGENTS.md', 'CLAUDE.md']) {
      final String body = File('${tmp.path}/$name').readAsStringSync();
      expect(body, contains(kGuardDocStart));
      expect(body, contains(kGuardDocEnd));
      expect(body, contains('Source of truth'),
          reason: 'states the SaaS is authoritative');
      expect(body, contains('project "Atelier"'));
      expect(body, contains('fl pull'));
      expect(body, contains('`arbs/**`'));
    }
  });

  test('installAgentDocs is idempotent — re-run leaves exactly one block', () {
    installAgentDocs(tmp, projectLabel: 'Atelier', globs: <String>['arbs/**']);
    installAgentDocs(tmp, projectLabel: 'Atelier', globs: <String>['arbs/**']);

    final String body = File('${tmp.path}/CLAUDE.md').readAsStringSync();
    expect(kGuardDocStart.allMatches(body).length, 1);
    expect(kGuardDocEnd.allMatches(body).length, 1);
  });

  test('installAgentDocs preserves surrounding content and refreshes the block',
      () {
    final File claude = File('${tmp.path}/CLAUDE.md')
      ..writeAsStringSync('# My project\n\nHand-written notes stay.\n');

    installAgentDocs(tmp, projectLabel: 'OldName', globs: <String>['arbs/**']);
    installAgentDocs(tmp, projectLabel: 'NewName', globs: <String>['arbs/**']);

    final String body = claude.readAsStringSync();
    // The project's own content is untouched.
    expect(body, contains('# My project'));
    expect(body, contains('Hand-written notes stay.'));
    // The managed block is refreshed in place, not duplicated.
    expect(kGuardDocStart.allMatches(body).length, 1);
    expect(body, contains('project "NewName"'));
    expect(body, isNot(contains('project "OldName"')));
  });
}
