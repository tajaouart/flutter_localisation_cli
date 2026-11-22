'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { HostTree } = require('@angular-devkit/schematics');
const { SchematicTestRunner } = require('@angular-devkit/schematics/testing');
const { stripJsonComments } = require('../angular/src/ng-add/index.js');

// The package.json build.mjs writes, for the schematic's own version.
const fs = require('node:fs');
const own = path.join(__dirname, '..', 'angular', 'package.json');
if (!fs.existsSync(own)) fs.writeFileSync(own, JSON.stringify({ version: '0.0.0-test' }));
test.after(() => { if (JSON.parse(fs.readFileSync(own, 'utf8')).version === '0.0.0-test') fs.unlinkSync(own); });

const runner = new SchematicTestRunner('flutterlocalisation', path.join(__dirname, '..', 'angular', 'collection.json'));

function app({ polyfills = ['zone.js'], withTest = true, project = 'shop', i18n } = {}) {
  const tree = new HostTree();
  tree.create('angular.json', JSON.stringify({
    version: 1,
    projects: {
      [project]: {
        projectType: 'application',
        root: '',
        ...(i18n ? { i18n } : {}),
        architect: {
          build: { builder: '@angular-devkit/build-angular:application', options: { polyfills, tsConfig: 'tsconfig.app.json' } },
          ...(withTest ? { test: { options: { polyfills: ['zone.js', 'zone.js/testing'], tsConfig: 'tsconfig.spec.json' } } } : {}),
          'extract-i18n': { builder: '@angular-devkit/build-angular:extract-i18n', options: { buildTarget: `${project}:build` } },
        },
      },
      lib: { projectType: 'library', root: 'projects/lib' },
    },
  }));
  tree.create('tsconfig.app.json', '/* To learn more */\n{\n  "extends": "./tsconfig.json",\n  "compilerOptions": { "types": [], },\n}\n');
  tree.create('tsconfig.spec.json', '{ "compilerOptions": { "types": ["jasmine"] } }');
  tree.create('package.json', JSON.stringify({ name: 'shop', scripts: {}, dependencies: { '@angular/core': '^17.3.0' } }));
  return tree;
}

const read = (tree, file) => JSON.parse(stripJsonComments(tree.readContent(file)));

test('sets up localize, ARB extraction, the CLI and the scripts', async () => {
  const tree = await runner.runSchematic('ng-add', { skipInstall: true }, app());
  const project = read(tree, 'angular.json').projects.shop;
  assert.deepEqual(project.architect.build.options.polyfills, ['zone.js', '@angular/localize/init']);
  assert.ok(project.architect.test.options.polyfills.includes('@angular/localize/init'));
  assert.deepEqual(project.architect['extract-i18n'].options, { buildTarget: 'shop:build', format: 'arb', outputPath: 'src/locale' });
  assert.deepEqual(project.i18n, { sourceLocale: 'en', locales: {} });
  assert.deepEqual(read(tree, 'tsconfig.app.json').compilerOptions.types, ['@angular/localize']);
  assert.deepEqual(read(tree, 'tsconfig.spec.json').compilerOptions.types, ['jasmine', '@angular/localize']);
  const pkg = read(tree, 'package.json');
  assert.equal(pkg.dependencies['@angular/localize'], '^17.3.0');
  assert.match(pkg.devDependencies['@flutterlocalisation/cli'], /^\^/);
  assert.equal(pkg.scripts['i18n:pull'], 'fl pull');
  assert.equal(pkg.scripts['i18n:push'], 'ng extract-i18n && fl import src/locale/messages.arb --translate');
});

test('a second run changes nothing', async () => {
  const once = await runner.runSchematic('ng-add', { skipInstall: true }, app());
  const before = ['angular.json', 'package.json', 'tsconfig.app.json'].map(f => once.readContent(f));
  const twice = await runner.runSchematic('ng-add', { skipInstall: true }, once);
  assert.deepEqual(['angular.json', 'package.json', 'tsconfig.app.json'].map(f => twice.readContent(f)), before);
});

test('keeps what the app already chose', async () => {
  const tree = app({ i18n: { sourceLocale: 'fr', locales: { de: 'src/locale/messages.de.arb' } } });
  const pkg = JSON.parse(tree.read('package.json').toString('utf8'));
  pkg.scripts['i18n:pull'] = 'custom';
  tree.overwrite('package.json', JSON.stringify(pkg));
  const out = await runner.runSchematic('ng-add', { skipInstall: true, localeDir: 'i18n/' }, tree);
  const project = read(out, 'angular.json').projects.shop;
  assert.equal(project.i18n.sourceLocale, 'fr');
  assert.deepEqual(project.i18n.locales, { de: 'src/locale/messages.de.arb' });
  assert.equal(project.architect['extract-i18n'].options.outputPath, 'i18n');
  assert.equal(read(out, 'package.json').scripts['i18n:pull'], 'custom');
});

test('an app with no polyfills (zoneless) gets the localize one', async () => {
  const tree = app({ polyfills: null, withTest: false });
  const out = await runner.runSchematic('ng-add', { skipInstall: true }, tree);
  assert.deepEqual(read(out, 'angular.json').projects.shop.architect.build.options.polyfills, ['@angular/localize/init']);
});

test('a new app without extract-i18n gets one from the builder package it builds with', async () => {
  const tree = app({ polyfills: null, withTest: false });
  const ws = JSON.parse(tree.read('angular.json').toString('utf8'));
  ws.projects.shop.architect.build.builder = '@angular/build:application';
  delete ws.projects.shop.architect['extract-i18n'];
  tree.overwrite('angular.json', JSON.stringify(ws));
  const out = await runner.runSchematic('ng-add', { skipInstall: true }, tree);
  assert.deepEqual(read(out, 'angular.json').projects.shop.architect['extract-i18n'], {
    builder: '@angular/build:extract-i18n',
    options: { buildTarget: 'shop:build', format: 'arb', outputPath: 'src/locale' },
  });
});

test('a project that is not there is refused by name', async () => {
  await assert.rejects(runner.runSchematic('ng-add', { skipInstall: true, project: 'nope' }, app()), /No project "nope"/);
});

test('installs unless told not to', async () => {
  await runner.runSchematic('ng-add', {}, app());
  assert.ok(runner.tasks.some(t => t.name === 'node-package'));
});
