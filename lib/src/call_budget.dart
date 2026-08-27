/// Refuses the one API-usage mistake that keeps happening: looping a command
/// that already accepts many targets.
///
/// The failure is never a single bad call — it is the *shape* of the caller.
/// On 26 Aug 2026 an agent localising an app ran `fl languages add <code>`
/// thirty-four times and `fl retranslate --locale <one>` thirty-three more,
/// with `--chunk-size` lowered eightfold, and drained a 1000/day budget in
/// under an hour. Every individual request was legitimate. Nothing in the tool
/// said "you are holding it wrong" until the daily throttle did, far too late
/// and without naming the right call.
///
/// [SingleKeyWriteThrottle] on the backend already covers key *creation*. This
/// covers the rest, and it covers it on the client, where the correct command
/// can actually be printed. It lives below [Operations] so `fl` and the MCP
/// server inherit it from one place — a guard only the CLI enforces is a guard
/// an agent routes around by calling the MCP tool instead.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_localisation_cli/src/exceptions.dart';

/// Raised when a caller is looping a bulk-capable command one target at a time.
///
/// Carries the exact command that should have been run, because a refusal that
/// only says "don't" teaches nothing — the caller's next move is to retry, or
/// to sleep and retry, which is the same loop wearing a hat.
class NarrowLoopException extends ManagementException {
  NarrowLoopException(super.message);
}

/// A persistent, cross-process record of narrow calls, keyed by command.
///
/// Cross-*process* is the whole point: each `fl` invocation is a fresh VM, so
/// an in-memory counter sees exactly one call and never fires. The loop is only
/// visible from disk.
class CallBudget {
  CallBudget({final File? ledger, final DateTime Function()? now})
      : _ledger = ledger ?? _defaultLedger(),
        _now = now ?? DateTime.now,
        _enabled = true;

  /// A guard that records nothing and refuses nothing.
  ///
  /// For tests and for callers that legitimately drive [Operations] in a loop
  /// they control. Deliberately explicit: the default is on, so a new call site
  /// inherits the protection instead of having to remember it.
  CallBudget.disabled()
      : _ledger = File('/dev/null'),
        _now = DateTime.now,
        _enabled = false;

  final File _ledger;
  final DateTime Function() _now;
  final bool _enabled;

  /// How many narrow calls of one command are tolerated inside [_window].
  ///
  /// Three, not one: a person fixing a bad translation legitimately runs a
  /// couple of single-target commands back to back, and a guard that fires on
  /// the second would be wrong more often than right. A *fourth* inside a
  /// quarter of an hour is not hand work.
  static const int _threshold = 3;
  static const Duration _window = Duration(minutes: 15);

  static File _defaultLedger() {
    final String home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '.';
    return File('$home/.config/flutterlocalisation/usage.json');
  }

  /// Record this call and refuse it if it completes a loop.
  ///
  /// [narrow] is the caller's own judgement — "this invocation targets exactly
  /// one locale/key, though the command accepts many". Wide calls are recorded
  /// too (they reset nothing, but the daily counter wants them) and never
  /// refused.
  ///
  /// [bulkForm] must be a runnable command, not a description. It is the entire
  /// value of this class.
  void guard({
    required final String command,
    required final bool narrow,
    required final String bulkForm,
  }) {
    if (!_enabled) return;
    final Map<String, dynamic> state = _read();
    final DateTime now = _now();
    final String today = _dayKey(now);

    // Daily request tally, for the readout. Rolls over on its own.
    if (state['day'] != today) {
      state['day'] = today;
      state['calls'] = 0;
    }
    state['calls'] = ((state['calls'] as int?) ?? 0) + 1;

    final Map<String, dynamic> recent =
        (state['recent'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    final List<int> stamps = <int>[
      for (final Object? t
          in (recent[command] as List<dynamic>?) ?? const <dynamic>[])
        if (t is int) t,
    ]..removeWhere((final int t) => now
            .difference(DateTime.fromMillisecondsSinceEpoch(t))
            .compareTo(_window) >
        0);

    if (!narrow) {
      // A wide call is the behaviour we want. Forgive the history: the caller
      // has demonstrably found the bulk form, and holding their earlier
      // single-target calls against them would refuse the *correct* command.
      recent.remove(command);
      state['recent'] = recent;
      _write(state);
      return;
    }

    if (stamps.length >= _threshold) {
      recent[command] = stamps;
      state['recent'] = recent;
      _write(state);
      throw NarrowLoopException(
        'Refusing: this is call ${stamps.length + 1} to `$command` in '
        '${_window.inMinutes} minutes, each targeting a single item.\n'
        'Looping a bulk command is what drains the daily API budget — it is '
        'the bug, not the pace. Run them together instead:\n'
        '\n'
        '    $bulkForm\n'
        '\n'
        'One invocation, one pass. Do not retry this command, and do not sleep '
        'between calls: neither changes the number of requests.',
      );
    }

    recent[command] = <int>[...stamps, now.millisecondsSinceEpoch];
    state['recent'] = recent;
    _write(state);
  }

  /// Calls made today, for surfacing alongside `fl status`.
  int callsToday() {
    final Map<String, dynamic> state = _read();
    return state['day'] == _dayKey(_now()) ? (state['calls'] as int?) ?? 0 : 0;
  }

  static String _dayKey(final DateTime t) =>
      '${t.year}-${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')}';

  Map<String, dynamic> _read() {
    try {
      if (!_ledger.existsSync()) return <String, dynamic>{};
      return jsonDecode(_ledger.readAsStringSync()) as Map<String, dynamic>;
    } on Object catch (_) {
      // A corrupt ledger must never block real work: the guard is a safety
      // net, and a safety net that becomes a failure mode is worse than none.
      return <String, dynamic>{};
    }
  }

  void _write(final Map<String, dynamic> state) {
    try {
      _ledger.parent.createSync(recursive: true);
      _ledger.writeAsStringSync(jsonEncode(state));
    } on Object catch (_) {
      // Read-only HOME, sandbox, whatever — degrade to no guard rather than
      // taking the command down with us.
    }
  }
}
