import 'dart:convert';
import 'dart:io';

import 'package:flutter_localisation_cli/src/guard.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('fl_guard_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test(
      'deriveGuardGlobs reads arb_dir (config) + l10n.yaml dirs + methods file',
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

  test('deriveGuardGlobs makes an absolute arb_dir relative to the project',
      () {
    final String inside = <String>[tmp.absolute.path, 'arbs', 'Default']
        .join(Platform.pathSeparator);
    expect(deriveGuardGlobs(tmp, arbDirFromConfig: inside),
        contains('arbs/Default/**'));
  });

  test('deriveGuardGlobs leaves out an arb_dir outside the project', () {
    final String outside = <String>[tmp.parent.absolute.path, 'shared_arbs']
        .join(Platform.pathSeparator);
    expect(deriveGuardGlobs(tmp, arbDirFromConfig: outside),
        <String>['lib/generated_translation_methods.dart']);
    expect(deriveGuardGlobs(tmp, arbDirFromConfig: '../shared_arbs'),
        <String>['lib/generated_translation_methods.dart']);
  });

  test('installGuard replaces the absolute and Write rules of older versions',
      () {
    final String old = '${tmp.absolute.path}${Platform.pathSeparator}arbs/**';
    final Directory claude = Directory('${tmp.path}/.claude')..createSync();
    File('${claude.path}/settings.json').writeAsStringSync(
      jsonEncode(<String, dynamic>{
        'permissions': <String, dynamic>{
          'deny': <String>[
            'Edit($old)',
            'Write($old)',
            'Write(arbs/**)',
            'Edit(/etc/**)',
          ],
        },
      }),
    );

    installGuard(tmp, globs: <String>['arbs/**']);

    final Map<String, dynamic> json = jsonDecode(
      File('${claude.path}/settings.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    expect((json['permissions'] as Map<String, dynamic>)['deny'],
        <String>['Edit(/etc/**)', 'Edit(arbs/**)']);
  });

  test('deriveGuardGlobs always includes the generated methods file', () {
    final List<String> globs = deriveGuardGlobs(tmp);
    expect(globs, <String>['lib/generated_translation_methods.dart']);
  });

  test('installGuard creates settings.json with one Edit rule per path', () {
    final GuardResult r =
        installGuard(tmp, globs: <String>['arbs/**', 'lib/x.dart']);

    expect(r.created, isTrue);
    final Map<String, dynamic> json = jsonDecode(
      File('${tmp.path}/.claude/settings.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final List<dynamic> deny =
        (json['permissions'] as Map<String, dynamic>)['deny'] as List<dynamic>;
    expect(deny, <String>['Edit(arbs/**)', 'Edit(lib/x.dart)']);
  });

  test(
      'installGuard merges into existing settings without clobbering or duping',
      () {
    final Directory claude = Directory('${tmp.path}/.claude')..createSync();
    File('${claude.path}/settings.json').writeAsStringSync(
      jsonEncode(
        <String, dynamic>{
          'permissions': <String, dynamic>{
            'allow': <String>['Bash(git *)'],
            'deny': <String>['Edit(arbs/**)'],
          },
          'model': 'sonnet',
        },
      ),
    );

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

  test('installAgentDocs writes the block for every agent, Copilot included',
      () {
    final AgentDocsResult r = installAgentDocs(
      tmp,
      projectLabel: 'Atelier',
      globs: <String>['arbs/**', 'lib/generated_translation_methods.dart'],
    );

    expect(kAgentDocFiles, contains('.github/copilot-instructions.md'));
    expect(r.files, hasLength(kAgentDocFiles.length));
    expect(r.created, hasLength(kAgentDocFiles.length));
    for (final String name in kAgentDocFiles) {
      final String body = File('${tmp.path}/$name').readAsStringSync();
      expect(body, contains(kGuardDocStart));
      expect(body, contains(kGuardDocEnd));
      expect(body, contains('Source of truth'),
          reason: 'states the SaaS is authoritative');
      expect(body, contains('project "Atelier"'));
      expect(body, contains('fl pull'));
      expect(body, contains('`arbs/**`'));
      expect(body, contains(kCopilotHookFile));
    }
  });

  test('installAgentDocs keeps the notes already in copilot-instructions.md',
      () {
    final File copilot = File('${tmp.path}/.github/copilot-instructions.md')
      ..createSync(recursive: true)
      ..writeAsStringSync('# House rules\n\nTabs, not spaces.\n');

    final AgentDocsResult r = installAgentDocs(tmp,
        projectLabel: 'Atelier', globs: <String>['arbs/**']);

    expect(r.created, isNot(contains(copilot.path)));
    final String body = copilot.readAsStringSync();
    expect(body, startsWith('# House rules'));
    expect(body, contains('Tabs, not spaces.'));
    expect(kGuardDocStart.allMatches(body).length, 1);
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

  group('Copilot hook', () {
    const List<String> globs = <String>[
      'arbs/**',
      'lib/l10n gen/**',
      'lib/generated_translation_methods.dart',
    ];

    /// Runs the hook the way Copilot does, from the repository root with the
    /// tool call on stdin, and returns what it printed.
    Future<String> runHook(final Map<String, dynamic> call) async {
      final Map<String, dynamic> entry = (((jsonDecode(
        File('${tmp.path}/$kCopilotHookFile').readAsStringSync(),
      ) as Map<String, dynamic>)['hooks'] as Map<String, dynamic>)['preToolUse']
              as List<dynamic>)
          .single as Map<String, dynamic>;
      final Process p = Platform.isWindows
          ? await Process.start(
              'pwsh',
              <String>['-NoProfile', '-Command', entry['powershell'] as String],
              workingDirectory: tmp.path,
            )
          : await Process.start(
              'sh',
              <String>['-c', entry['bash'] as String],
              workingDirectory: tmp.path,
            );
      p.stdin.write(jsonEncode(call));
      await p.stdin.close();
      final String out = await p.stdout.transform(utf8.decoder).join();
      await p.stderr.drain<void>();
      expect(await p.exitCode, 0, reason: 'a hook that fails blocks the call');
      return out.trim();
    }

    String abs(final String relative) => Platform.isWindows
        ? '${tmp.path}\\${relative.replaceAll('/', r'\')}'
        : '${tmp.path}/$relative';

    Map<String, dynamic> call(final String tool, final Object args) =>
        <String, dynamic>{
          'sessionId': 's',
          'timestamp': 1794577751035,
          'cwd': tmp.path,
          'toolCallId': 't',
          'toolName': tool,
          'toolArgs': args,
        };

    void expectDenied(final String out) {
      final Map<String, dynamic> decision =
          jsonDecode(out) as Map<String, dynamic>;
      expect(decision['permissionDecision'], 'deny');
      expect(decision['permissionDecisionReason'], kCopilotDenyReason);
      expect(out, isNot(contains('\n')), reason: 'Copilot wants one line');
    }

    setUp(() => installCopilotGuard(tmp, globs: globs));

    test('writes the hook and both scripts, and says which were new', () {
      final CopilotGuardResult again = installCopilotGuard(tmp, globs: globs);

      expect(again.files, hasLength(3));
      expect(again.created, isEmpty, reason: 'setUp already wrote them');
      final Map<String, dynamic> config = jsonDecode(
        File('${tmp.path}/$kCopilotHookFile').readAsStringSync(),
      ) as Map<String, dynamic>;
      expect(config['version'], 1);
      final Map<String, dynamic> entry = ((config['hooks']
              as Map<String, dynamic>)['preToolUse'] as List<dynamic>)
          .single as Map<String, dynamic>;
      expect(entry['matcher'], 'edit|create|str_replace_editor|apply_patch');
      expect(entry['bash'], contains(kCopilotHookSh));
      expect(entry['powershell'], contains(kCopilotHookPs1));
    });

    test('a changed arb_dir replaces the old paths on the next run', () {
      installCopilotGuard(tmp, globs: <String>['translations/**']);

      for (final String name in <String>[kCopilotHookSh, kCopilotHookPs1]) {
        final String body = File('${tmp.path}/$name').readAsStringSync();
        expect(body, contains('translations'));
        expect(body, isNot(contains('arbs')));
      }
    });

    test('refuses an edit and a create inside a protected folder', () async {
      expectDenied(await runHook(call('edit', <String, dynamic>{
        'path': abs('arbs/app_en.arb'),
        'old_str': '"a"',
        'new_str': '"b"',
      })));
      expectDenied(await runHook(call('create', <String, dynamic>{
        'path': abs('arbs/nested/app_fr.arb'),
        'file_text': '{}',
      })));
      expectDenied(await runHook(call('create', <String, dynamic>{
        'path': abs('lib/l10n gen/app_localizations.dart'),
        'file_text': '',
      })));
    });

    test('refuses the generated methods file, and a relative path', () async {
      expectDenied(await runHook(call('edit', <String, dynamic>{
        'path': abs('lib/generated_translation_methods.dart'),
      })));
      expectDenied(await runHook(call('edit', <String, dynamic>{
        'path': 'arbs/app_en.arb',
      })));
      expectDenied(await runHook(call('edit', <String, dynamic>{
        'path': './arbs/app_en.arb',
      })));
    });

    test('refuses a patch that touches a protected file among others',
        () async {
      for (final String header in <String>[
        '*** Update File: ${abs('arbs/app_en.arb')}',
        '*** Add File: ${abs('arbs/app_fr.arb')}',
        '*** Delete File: arbs/app_de.arb',
        '*** Update File: ${abs('lib/old.dart')}\n'
            '*** Move to: ${abs('arbs/moved.arb')}',
      ]) {
        expectDenied(await runHook(call(
          'apply_patch',
          '*** Begin Patch\n'
              '*** Update File: ${abs('lib/main.dart')}\n@@\n-a\n+b\n'
              '$header\n@@\n-{}\n+{"a":"b"}\n'
              '*** End Patch\n',
        )));
      }
    });

    test('lets every other edit through', () async {
      expect(
          await runHook(call('edit', <String, dynamic>{
            'path': abs('lib/main.dart'),
            // Text that only mentions a protected file is not an edit of it.
            'new_str': 'see arbs/app_en.arb and "path":"arbs/app_en.arb"',
          })),
          isEmpty);
      expect(
          await runHook(call('create', <String, dynamic>{
            'path': abs('arbs_notes/readme.md'),
            'file_text': 'a sibling folder with the same prefix',
          })),
          isEmpty);
      expect(
          await runHook(call(
            'apply_patch',
            '*** Begin Patch\n'
                '*** Update File: ${abs('lib/main.dart')}\n@@\n'
                '+// *** Update File: arbs/app_en.arb\n'
                '*** End Patch\n',
          )),
          isEmpty);
    });

    test('lets reads and shell commands through, fl pull writes these files',
        () async {
      expect(
          await runHook(call('view', <String, dynamic>{
            'path': abs('arbs/app_en.arb'),
          })),
          isEmpty);
      expect(
          await runHook(call('bash', <String, dynamic>{
            'command': 'fl pull && cat arbs/app_en.arb',
          })),
          isEmpty);
    });

    test('lets the edit through when the payload is not what it expects',
        () async {
      expect(await runHook(<String, dynamic>{'unexpected': true}), isEmpty);
      expect(await runHook(call('edit', <String, dynamic>{})), isEmpty);
    });
  });
}
