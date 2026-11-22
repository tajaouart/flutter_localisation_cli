'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const fl = path.join(__dirname, '..', 'cli', 'bin', 'fl.js');
fs.copyFileSync(path.join(__dirname, '..', 'targets.json'), path.join(__dirname, '..', 'cli', 'targets.json'));
test.after(() => fs.unlinkSync(path.join(__dirname, '..', 'cli', 'targets.json')));

test('passes the arguments, the exit code and FL_INSTALLED_BY to the binary', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fl-launch-'));
  const bin = path.join(dir, process.platform === 'win32' ? 'fl.exe' : 'fl');
  fs.writeFileSync(bin, '#!/bin/sh\necho "$FL_INSTALLED_BY $*"\nexit 3\n', { mode: 0o755 });
  const r = spawnSync(process.execPath, [fl, 'pull', '--adopt'], { env: { ...process.env, FL_BINARY_DIR: dir }, encoding: 'utf8' });
  assert.equal(r.stdout.trim(), 'npm pull --adopt');
  assert.equal(r.status, 3);
});

test('a machine without its binary package is told what to do', () => {
  const r = spawnSync(process.execPath, [fl, '--version'], { env: { ...process.env, FL_BINARY_DIR: '' }, encoding: 'utf8' });
  assert.equal(r.status, 1);
  assert.match(r.stderr, /dart pub global activate flutter_localisation_cli/);
});
