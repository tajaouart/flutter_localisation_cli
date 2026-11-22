// Lays out every npm package of a release in npm/dist, versioned like
// pubspec.yaml, ready for `npm publish` from each folder.
//
//   node npm/build.mjs --binaries <dir>
//
// <dir>/<os>-<cpu>/ holds the `fl` and `fl_mcp` executables of that target
// (`fl.exe` on Windows), as `dart compile exe` wrote them. A target without
// binaries gets no package; CI builds all of them.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.dirname(here);
const dist = path.join(here, 'dist');
const args = process.argv.slice(2);
const binaries = args.includes('--binaries') ? path.resolve(args[args.indexOf('--binaries') + 1]) : null;

const version = /^version:\s*(\S+)/m.exec(fs.readFileSync(path.join(root, 'pubspec.yaml'), 'utf8'))[1];
const targets = JSON.parse(fs.readFileSync(path.join(here, 'targets.json'), 'utf8'));
const common = {
  version,
  license: 'MIT',
  homepage: 'https://flutterlocalisation.com',
  repository: { type: 'git', url: 'https://github.com/tajaouart/flutter_localisation_cli' },
  author: 'Aylan Technologies LLC',
};

fs.rmSync(dist, { recursive: true, force: true });
const write = (dir, file, body) => {
  fs.mkdirSync(path.join(dist, dir), { recursive: true });
  fs.writeFileSync(path.join(dist, dir, file), typeof body === 'string' ? body : JSON.stringify(body, null, 2) + '\n');
};
const copy = (from, dir) => fs.cpSync(from, path.join(dist, dir), { recursive: true });

// The launcher.
copy(path.join(here, 'cli'), 'cli');
fs.copyFileSync(path.join(here, 'targets.json'), path.join(dist, 'cli', 'targets.json'));
write('cli', 'package.json', {
  name: '@flutterlocalisation/cli',
  description: 'The fl command and the fl_mcp MCP server of FlutterLocalisation, for Flutter, iOS and Angular apps. No Dart needed.',
  ...common,
  bin: { fl: 'bin/fl.js', fl_mcp: 'bin/fl_mcp.js' },
  files: ['bin', 'targets.json', 'README.md'],
  engines: { node: '>=18' },
  optionalDependencies: Object.fromEntries(targets.map(t => [`@flutterlocalisation/cli-${t.os}-${t.cpu}`, version])),
  keywords: ['i18n', 'l10n', 'localization', 'translation', 'angular', 'flutter', 'arb', 'mcp'],
});

// One package per target, with its two binaries.
const built = [];
for (const t of targets) {
  const exe = t.os === 'win32' ? '.exe' : '';
  const from = binaries && path.join(binaries, `${t.os}-${t.cpu}`);
  if (!from || !fs.existsSync(path.join(from, `fl${exe}`))) continue;
  const dir = `cli-${t.os}-${t.cpu}`;
  fs.mkdirSync(path.join(dist, dir, 'bin'), { recursive: true });
  for (const name of ['fl', 'fl_mcp']) {
    const target = path.join(dist, dir, 'bin', name + exe);
    fs.copyFileSync(path.join(from, name + exe), target);
    fs.chmodSync(target, 0o755);
  }
  write(dir, 'package.json', {
    name: `@flutterlocalisation/cli-${t.os}-${t.cpu}`,
    description: `The fl and fl_mcp binaries for ${t.os}-${t.cpu}. Install @flutterlocalisation/cli instead.`,
    ...common,
    os: [t.os],
    cpu: [t.cpu],
    files: ['bin'],
    preferUnplugged: true,
  });
  write(dir, 'README.md', `# @flutterlocalisation/cli-${t.os}-${t.cpu}\n\nThe \`fl\` and \`fl_mcp\` binaries for ${t.os}-${t.cpu}. Install [@flutterlocalisation/cli](https://www.npmjs.com/package/@flutterlocalisation/cli), which picks this package on this machine.\n`);
  built.push(dir);
}

// The Angular setup.
copy(path.join(here, 'angular'), 'angular');
write('angular', 'package.json', {
  name: '@flutterlocalisation/angular',
  description: 'ng add for FlutterLocalisation: sets up @angular/localize, ARB extraction and the fl command in an Angular app.',
  ...common,
  schematics: './collection.json',
  'ng-add': { save: 'devDependencies' },
  files: ['collection.json', 'src', 'README.md'],
  peerDependencies: { '@angular/core': '>=15.0.0' },
  dependencies: { '@angular-devkit/schematics': '>=15.0.0' },
  keywords: ['angular', 'i18n', 'localize', 'schematics', 'ng-add', 'translation', 'arb'],
});

console.log(`npm packages ${version} in ${path.relative(process.cwd(), dist)}: cli, angular${built.length ? ', ' + built.join(', ') : ''}`);
