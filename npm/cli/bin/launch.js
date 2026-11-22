'use strict';
// Runs the native `fl` or `fl_mcp` binary that npm installed for this
// machine as one of the optional @flutterlocalisation/cli-<os>-<cpu>
// packages (the esbuild pattern: no download at install time, no Dart).
const { spawnSync } = require('node:child_process');
const path = require('node:path');

const targets = require('../targets.json');

function binaryPath(name) {
  if (process.env.FL_BINARY_DIR) {
    return path.join(process.env.FL_BINARY_DIR, name + (process.platform === 'win32' ? '.exe' : ''));
  }
  const target = targets.find(t => t.os === process.platform && t.cpu === process.arch);
  if (!target) {
    fail(`No ${name} binary is published for ${process.platform}-${process.arch}.`);
  }
  const pkg = `@flutterlocalisation/cli-${target.os}-${target.cpu}`;
  const file = `bin/${name}${target.os === 'win32' ? '.exe' : ''}`;
  try {
    return require.resolve(`${pkg}/${file}`);
  } catch {
    fail(`${pkg} is not installed. It is an optional dependency of @flutterlocalisation/cli; ` +
      'reinstall without --no-optional / --omit=optional.');
  }
}

function fail(message) {
  console.error(`${message}\nThe same commands come with Dart: dart pub global activate flutter_localisation_cli`);
  process.exit(1);
}

module.exports = function launch(name) {
  const result = spawnSync(binaryPath(name), process.argv.slice(2), {
    stdio: 'inherit',
    env: { ...process.env, FL_INSTALLED_BY: 'npm' },
  });
  if (result.error) fail(`Could not start ${name}: ${result.error.message}`);
  process.exit(result.status === null ? 1 : result.status);
};
