'use strict';
// `ng add @flutterlocalisation/angular`: the setup Angular's own
// `ng add @angular/localize` makes, plus ARB extraction into the locale
// folder, the `fl` command and three npm scripts. Running it again changes
// nothing that is already in place.
const { SchematicsException } = require('@angular-devkit/schematics');
const { NodePackageInstallTask } = require('@angular-devkit/schematics/tasks');

const LOCALIZE_POLYFILL = '@angular/localize/init';
const LOCALIZE_TYPES = '@angular/localize';

function readJson(tree, file) {
  const buffer = tree.read(file);
  if (!buffer) throw new SchematicsException(`${file} not found.`);
  return JSON.parse(stripJsonComments(buffer.toString('utf8')));
}

function writeJson(tree, file, value) {
  const text = JSON.stringify(value, null, 2) + '\n';
  if (tree.read(file).toString('utf8') !== text) tree.overwrite(file, text);
}

// tsconfig files are JSON with comments; this reads one.
function stripJsonComments(text) {
  let out = '';
  let inString = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    const next = text[i + 1];
    if (inString) {
      out += c;
      if (c === '\\') { out += next; i++; } else if (c === '"') inString = false;
    } else if (c === '"') {
      inString = true;
      out += c;
    } else if (c === '/' && next === '/') {
      while (i < text.length && text[i] !== '\n') i++;
      out += '\n';
    } else if (c === '/' && next === '*') {
      i += 2;
      while (i < text.length && !(text[i] === '*' && text[i + 1] === '/')) i++;
      i++;
    } else {
      out += c;
    }
  }
  return out.replace(/,(\s*[}\]])/g, '$1');
}

function pickProject(workspace, wanted) {
  const projects = workspace.projects || {};
  if (wanted) {
    if (!projects[wanted]) throw new SchematicsException(`No project "${wanted}" in angular.json.`);
    return [wanted, projects[wanted]];
  }
  const apps = Object.entries(projects).filter(([, p]) => p.projectType !== 'library');
  if (!apps.length) throw new SchematicsException('angular.json has no application to set up.');
  return apps.length === 1 ? apps[0] : (apps.find(([, p]) => (p.root || '') === '') || apps[0]);
}

function addPolyfill(options) {
  if (!options) return false;
  const list = options.polyfills == null ? [] : [].concat(options.polyfills);
  if (list.includes(LOCALIZE_POLYFILL)) return false;
  options.polyfills = [...list, LOCALIZE_POLYFILL];
  return true;
}

// Added in place, so the comments Angular writes in a tsconfig stay.
function addTypes(tree, file) {
  if (!file || !tree.exists(file)) return false;
  const config = readJson(tree, file);
  config.compilerOptions = config.compilerOptions || {};
  const types = config.compilerOptions.types || [];
  if (types.includes(LOCALIZE_TYPES)) return false;
  const text = tree.read(file).toString('utf8');
  const entry = JSON.stringify(LOCALIZE_TYPES);
  let edited = text;
  if (config.compilerOptions.types) {
    edited = text.replace(/("types"\s*:\s*\[)([^\]]*)\]/, (_, open, body) => {
      const kept = body.replace(/[\s,]+$/, '');
      return `${open}${kept}${kept.trim() ? ', ' : ''}${entry}]`;
    });
  } else {
    const more = Object.keys(config.compilerOptions).length ? ',' : '';
    edited = text.replace(/("compilerOptions"\s*:\s*\{)/, `$1\n    "types": [${entry}]${more}`);
  }
  try {
    const result = JSON.parse(stripJsonComments(edited));
    if (((result.compilerOptions || {}).types || []).includes(LOCALIZE_TYPES)) {
      tree.overwrite(file, edited);
      return true;
    }
  } catch (_) {
    // An unusual layout: written from the parsed content below.
  }
  config.compilerOptions.types = [...types, LOCALIZE_TYPES];
  writeJson(tree, file, config);
  return true;
}

function ngAdd(options) {
  return (tree, context) => {
    const workspace = readJson(tree, 'angular.json');
    const [name, project] = pickProject(workspace, options.project);
    const architect = project.architect || project.targets || {};
    const dir = (options.localeDir || 'src/locale').replace(/\/+$/, '');
    const done = [];

    if (addPolyfill(architect.build && architect.build.options)) done.push('build polyfills');
    if (addPolyfill(architect.test && architect.test.options)) done.push('test polyfills');

    // The builder package the app already builds with: `@angular/build` from
    // Angular 17.2 on, `@angular-devkit/build-angular` before.
    const buildPackage = ((architect.build && architect.build.builder) || '').split(':')[0]
      || '@angular-devkit/build-angular';
    const extract = architect['extract-i18n'] || (architect['extract-i18n'] = {
      builder: `${buildPackage}:extract-i18n`,
      options: { buildTarget: `${name}:build` },
    });
    extract.options = extract.options || {};
    if (extract.options.format !== 'arb' || extract.options.outputPath !== dir) {
      extract.options.format = 'arb';
      extract.options.outputPath = dir;
      done.push(`extract-i18n writes ARB to ${dir}`);
    }
    project.i18n = project.i18n || {};
    if (!project.i18n.sourceLocale) {
      project.i18n.sourceLocale = options.sourceLocale || 'en';
      done.push(`source locale ${project.i18n.sourceLocale}`);
    }
    project.i18n.locales = project.i18n.locales || {};
    writeJson(tree, 'angular.json', workspace);

    const buildOptions = (architect.build && architect.build.options) || {};
    const testOptions = (architect.test && architect.test.options) || {};
    if (addTypes(tree, buildOptions.tsConfig)) done.push(`${buildOptions.tsConfig} types`);
    if (addTypes(tree, testOptions.tsConfig)) done.push(`${testOptions.tsConfig} types`);

    const pkg = readJson(tree, 'package.json');
    pkg.dependencies = pkg.dependencies || {};
    pkg.devDependencies = pkg.devDependencies || {};
    pkg.scripts = pkg.scripts || {};
    const angular = pkg.dependencies['@angular/core'];
    if (!pkg.dependencies['@angular/localize'] && !pkg.devDependencies['@angular/localize']) {
      if (!angular) throw new SchematicsException('package.json has no @angular/core to match @angular/localize to.');
      // A build-time package, where Angular's own `ng add` puts it.
      pkg.devDependencies['@angular/localize'] = angular;
      done.push(`@angular/localize ${angular}`);
    }
    if (!pkg.devDependencies['@flutterlocalisation/cli']) {
      pkg.devDependencies['@flutterlocalisation/cli'] = `^${require('../../package.json').version}`;
      done.push('@flutterlocalisation/cli');
    }
    const scripts = {
      'i18n:extract': 'ng extract-i18n',
      'i18n:push': `ng extract-i18n && fl import ${dir}/messages.arb --translate`,
      'i18n:pull': 'fl pull',
    };
    for (const [key, value] of Object.entries(scripts)) {
      if (!pkg.scripts[key]) pkg.scripts[key] = value;
    }
    writeJson(tree, 'package.json', pkg);

    if (!options.skipInstall) context.addTask(new NodePackageInstallTask());
    context.logger.info(done.length
      ? `FlutterLocalisation set up ${name}: ${done.join(', ')}.`
      : `${name} was already set up for FlutterLocalisation.`);
    context.logger.info([
      'Next:',
      '  1. Mark your text: <h1 i18n="@@home.title">Hello</h1>, $localize`:@@toast.saved:Saved`',
      '  2. npx fl init            pick the project (create it in the dashboard first)',
      '  3. npm run i18n:push      extract and send the strings, translated',
      '  4. npm run i18n:pull      bring messages.<locale>.arb back, listed in angular.json',
      '  5. ng build --localize',
    ].join('\n'));
    return tree;
  };
}

module.exports = { ngAdd, stripJsonComments, pickProject };
