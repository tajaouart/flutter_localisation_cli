/// What `fl init` can read off the repository before asking anything.
///
/// A Flutter app already says where its ARBs live (`l10n.yaml`), an iOS app
/// already has a String Catalog somewhere under the Xcode target. The wizard
/// prefills from these and only asks when a guess would be a coin toss.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:flutter_localisation_cli/src/native_sync.dart';

/// `arb-dir` from `l10n.yaml`, or null when the file or the key is absent.
String? l10nArbDir(final Directory root) {
  final File l10n = File(p.join(root.path, 'l10n.yaml'));
  if (!l10n.existsSync()) return null;
  for (final String line in l10n.readAsLinesSync()) {
    final String t = line.trim();
    if (t.startsWith('#') || !t.startsWith('arb-dir:')) continue;
    String v = t.substring('arb-dir:'.length).trim();
    final int hash = v.indexOf('#');
    if (hash >= 0) v = v.substring(0, hash).trim();
    v = v.replaceAll('"', '').replaceAll("'", '');
    if (v.isNotEmpty) return v;
  }
  return null;
}

/// Folders skipped while looking for a String Catalog: build output and
/// dependencies carry catalogs that are not the app's.
const Set<String> _skippedDirs = <String>{
  'Pods',
  'build',
  '.build',
  'DerivedData',
  'node_modules',
  '.dart_tool',
  '.git',
  'Carthage',
};

/// The folder holding `Localizable.xcstrings`, relative to [root], or null.
///
/// Shallow before deep: the first catalog found by breadth-first walk is the
/// app target's, a nested one belongs to an extension or a package.
String? existingCatalogDir(final Directory root) {
  final List<Directory> queue = <Directory>[root];
  while (queue.isNotEmpty) {
    final Directory dir = queue.removeAt(0);
    List<FileSystemEntity> entries;
    try {
      entries = dir.listSync();
    } on FileSystemException {
      continue;
    }
    for (final FileSystemEntity e in entries) {
      if (e is File && p.basename(e.path) == 'Localizable.xcstrings') {
        final String rel = p.relative(dir.path, from: root.path);
        return rel == '.' ? '.' : rel;
      }
    }
    for (final FileSystemEntity e in entries) {
      if (e is Directory && !_skippedDirs.contains(p.basename(e.path))) {
        queue.add(e);
      }
    }
  }
  return null;
}

/// Where a first `fl pull` should write the String Catalogs for a project
/// that has none on disk yet: beside `Info.plist` of the iOS target when
/// there is one, else the repository root.
String defaultCatalogDir(final Directory root) {
  final Directory? target = findIosTargetDir(root);
  if (target != null) return p.relative(target.path, from: root.path);
  for (final FileSystemEntity e in root.listSync()) {
    if (e is Directory && e.path.endsWith('.xcodeproj')) {
      final String app = p.basenameWithoutExtension(e.path);
      if (Directory(p.join(root.path, app)).existsSync()) return app;
    }
  }
  return '.';
}

/// True when the folder looks like a Flutter app (has a pubspec that depends
/// on Flutter) as opposed to a bare iOS project.
bool looksLikeFlutterApp(final Directory root) {
  final File pubspec = File(p.join(root.path, 'pubspec.yaml'));
  if (!pubspec.existsSync()) return false;
  return pubspec.readAsStringSync().contains('flutter:');
}

/// Line-oriented prompts for the wizard. Every question has a default so
/// `--yes` (or no terminal) can answer it without a human.
class Prompter {
  Prompter({required this.interactive});

  /// False under `--yes` or when stdin is not a terminal: every call returns
  /// its default without printing a question.
  final bool interactive;

  String ask(final String question, final String fallback) {
    if (!interactive) return fallback;
    stdout.write('$question [$fallback]: ');
    final String? line = stdin.readLineSync();
    final String v = (line ?? '').trim();
    return v.isEmpty ? fallback : v;
  }

  bool confirm(final String question, {final bool fallback = true}) {
    if (!interactive) return fallback;
    stdout.write('$question ${fallback ? '[Y/n]' : '[y/N]'}: ');
    final String v = (stdin.readLineSync() ?? '').trim().toLowerCase();
    if (v.isEmpty) return fallback;
    return v == 'y' || v == 'yes';
  }

  /// Pick one of [labels] by number. Returns the index, or null when the
  /// caller must decide (not interactive, several choices, no default).
  int? choose(final String question, final List<String> labels,
      {final int? fallback}) {
    if (labels.length == 1) return 0;
    if (!interactive) return fallback;
    stdout.writeln(question);
    for (int i = 0; i < labels.length; i++) {
      stdout.writeln('  ${i + 1}. ${labels[i]}');
    }
    while (true) {
      stdout.write('Number${fallback != null ? ' [${fallback + 1}]' : ''}: ');
      final String v = (stdin.readLineSync() ?? '').trim();
      if (v.isEmpty && fallback != null) return fallback;
      final int? n = int.tryParse(v);
      if (n != null && n >= 1 && n <= labels.length) return n - 1;
      stdout.writeln('Type a number between 1 and ${labels.length}.');
    }
  }

  /// Read a secret without echoing it. Falls back to a plain read when the
  /// terminal refuses to switch echo off.
  String secret(final String question) {
    stdout.write('$question: ');
    bool echo = true;
    try {
      echo = stdin.echoMode;
      stdin.echoMode = false;
    } on StdinException {
      // not a terminal; read as-is
    }
    final String v = (stdin.readLineSync() ?? '').trim();
    try {
      stdin.echoMode = echo;
    } on StdinException {
      // same
    }
    stdout.writeln();
    return v;
  }
}
