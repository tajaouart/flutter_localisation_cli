/// The guard that refuses a caller looping a bulk-capable command.
///
/// These tests encode the two ways it can be wrong, which matter more than the
/// happy path: firing on a person doing legitimate one-off edits (a guard that
/// cries wolf gets disabled), and failing to fire across separate processes
/// (each `fl` run is a fresh VM, so an in-memory counter would never see the
/// loop that actually caused the outage).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_localisation_cli/src/call_budget.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late File ledger;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fl_budget_');
    ledger = File('${tmp.path}/usage.json');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  DateTime at(final int minute) => DateTime(2026, 8, 26, 12, minute);

  CallBudget budgetAt(final int minute) =>
      CallBudget(ledger: ledger, now: () => at(minute));

  void narrowCall(final int minute) => budgetAt(minute).guard(
        command: 'languages add',
        narrow: true,
        bulkForm: 'fl languages add a b c',
      );

  test('tolerates a person making a couple of one-off single-target calls', () {
    expect(() => narrowCall(0), returnsNormally);
    expect(() => narrowCall(1), returnsNormally);
    expect(() => narrowCall(2), returnsNormally);
  });

  test('refuses the fourth narrow call inside the window', () {
    narrowCall(0);
    narrowCall(1);
    narrowCall(2);
    expect(() => narrowCall(3), throwsA(isA<NarrowLoopException>()));
  });

  test('the refusal names the runnable bulk command, not just the problem', () {
    narrowCall(0);
    narrowCall(1);
    narrowCall(2);
    try {
      narrowCall(3);
      fail('expected a refusal');
    } on NarrowLoopException catch (e) {
      expect(e.message, contains('fl languages add a b c'));
      // A refusal that reads as "slow down" teaches sleep-and-retry, which is
      // the same loop. It has to say the opposite.
      expect(e.message, contains('Do not retry'));
    }
  });

  test('the counter survives process death — the loop is only visible on disk',
      () {
    // Three separate CallBudget instances stand in for three `fl` invocations.
    narrowCall(0);
    narrowCall(1);
    narrowCall(2);
    expect(jsonDecode(ledger.readAsStringSync()), isA<Map<String, dynamic>>());
    expect(() => narrowCall(3), throwsA(isA<NarrowLoopException>()));
  });

  test('the window expires, so a slow drip is not a loop', () {
    narrowCall(0);
    narrowCall(1);
    narrowCall(2);
    expect(() => narrowCall(30), returnsNormally);
  });

  test('a wide call is never refused and forgives the narrow history', () {
    narrowCall(0);
    narrowCall(1);
    narrowCall(2);
    // The caller found the bulk form. Holding their earlier fumbling against
    // them would refuse the correct command, which is the worst outcome.
    expect(
      () => budgetAt(3).guard(
          command: 'languages add',
          narrow: false,
          bulkForm: 'fl languages add a b c'),
      returnsNormally,
    );
    expect(() => narrowCall(4), returnsNormally);
  });

  test('commands are counted separately', () {
    narrowCall(0);
    narrowCall(1);
    narrowCall(2);
    expect(
      () => budgetAt(3).guard(
          command: 'retranslate', narrow: true, bulkForm: 'fl retranslate'),
      returnsNormally,
    );
  });

  test('a corrupt ledger degrades to no guard rather than breaking the tool',
      () {
    ledger.parent.createSync(recursive: true);
    ledger.writeAsStringSync('{not json');
    expect(() => narrowCall(0), returnsNormally);
  });

  test('an unwritable ledger does not take the command down', () {
    final CallBudget b = CallBudget(
      ledger: File('/proc/nonexistent/usage.json'),
      now: () => at(0),
    );
    expect(
      () => b.guard(command: 'x', narrow: true, bulkForm: 'y'),
      returnsNormally,
    );
  });
}
