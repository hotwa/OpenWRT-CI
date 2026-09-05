#!/usr/bin/env node
'use strict';

// Exercise each configured extension through the same Jiti/alias route Pi uses
// for a normal Node distribution.  SEA/bundled Pi uses its internal virtual
// modules; the build-time Node package uses these equivalent Pi-owned aliases.

const fs = require('node:fs');
const path = require('node:path');
const { createRequire } = require('node:module');

function die(message) {
  console.error(`ERROR: [pi-extension-verify] ${message}`);
  process.exit(1);
}

function parseArgs(argv) {
  const options = {};
  for (let index = 2; index < argv.length; index += 1) {
    const key = argv[index];
    if (!['--directory', '--vendor-extension'].includes(key)) die(`unknown argument: ${key}`);
    const value = argv[++index];
    if (!value) die(`missing value for ${key}`);
    options[key.slice(2).replace(/-([a-z])/g, (_, char) => char.toUpperCase())] = value;
  }
  if (!options.directory) die('--directory is required');
  return options;
}

function packageEntries(root, name) {
  const packageRoot = path.join(root, ...name.split('/'));
  const manifestPath = path.join(packageRoot, 'package.json');
  if (!fs.existsSync(manifestPath)) die(`missing package manifest for ${name}`);
  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  const explicit = manifest.pi?.extensions;
  if (Array.isArray(explicit) && explicit.length) {
    return explicit.map(entry => path.resolve(packageRoot, entry));
  }
  for (const entry of ['index.ts', 'index.js', manifest.module, manifest.main, 'dist/index.js']) {
    if (typeof entry !== 'string') continue;
    const resolved = path.resolve(packageRoot, entry);
    if (fs.existsSync(resolved)) return [resolved];
  }
  die(`${name} declares no Pi extension entry`);
}

const options = parseArgs(process.argv);
const stagingDir = path.resolve(options.directory);
const nodeModules = fs.existsSync(path.join(stagingDir, 'node_modules'))
  ? path.join(stagingDir, 'node_modules')
  : path.join(stagingDir, 'lib', 'node_modules');
const catalogPath = fs.existsSync(path.join(stagingDir, 'package.json'))
  ? path.join(stagingDir, 'package.json')
  : path.join(stagingDir, 'agent-runtime-package.json');
if (!fs.existsSync(catalogPath)) die(`missing catalog: ${catalogPath}`);
if (!fs.existsSync(nodeModules)) die(`missing node_modules: ${nodeModules}`);
const catalog = JSON.parse(fs.readFileSync(catalogPath, 'utf8'));
if (!Array.isArray(catalog.openwrtPiExtensions)) die('catalog has no openwrtPiExtensions list');

const piRoot = path.join(nodeModules, '@earendil-works', 'pi-coding-agent');
const piManifestPath = path.join(piRoot, 'package.json');
if (!fs.existsSync(piManifestPath)) die('missing installed Pi package manifest');
const piManifest = JSON.parse(fs.readFileSync(piManifestPath, 'utf8'));
const piModuleEntry = path.resolve(piRoot, typeof piManifest.main === 'string' ? piManifest.main : 'dist/index.js');
const piCliEntry = path.resolve(piRoot, typeof piManifest.bin?.pi === 'string' ? piManifest.bin.pi : 'dist/bundle/cli.js');
if (!fs.existsSync(piModuleEntry)) die(`Pi module entry is missing: ${piModuleEntry}`);
if (!fs.existsSync(piCliEntry)) die(`Pi loader entry is missing: ${piCliEntry}`);
// New Pi releases use an exports map that intentionally has no CommonJS
// require target. Creating the resolver from its concrete CLI bundle avoids
// require.resolve(package-name), while retaining Pi's own dependency tree.
const piRequire = createRequire(piCliEntry);
const jiti = piRequire('jiti').createJiti;
if (typeof jiti !== 'function') die('Pi-owned jiti.createJiti is unavailable');
function packageRoot(name) {
  const root = path.join(nodeModules, ...name.split('/'));
  if (!fs.existsSync(path.join(root, 'package.json'))) die(`Pi resolver cannot find ${name}`);
  return root;
}
function packageEntry(name, fallback) {
  const root = packageRoot(name);
  const manifest = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'));
  const candidate = typeof manifest.module === 'string' ? manifest.module
    : typeof manifest.main === 'string' ? manifest.main
      : fallback;
  const entry = path.resolve(root, candidate);
  if (!fs.existsSync(entry)) die(`Pi resolver cannot find ${name} entry: ${entry}`);
  return entry;
}
function packageFile(name, relativePath) {
  const filename = path.resolve(packageRoot(name), relativePath);
  if (!fs.existsSync(filename)) die(`Pi resolver cannot find ${name}/${relativePath}`);
  return filename;
}

// Pi packages are ESM-only. Resolve the concrete exported files instead of
// calling CommonJS require.resolve(), which cannot select their `import`
// export condition. This mirrors Pi's normal-node alias table.
const piAgentCore = packageEntry('@earendil-works/pi-agent-core', 'dist/index.js');
const piTui = packageEntry('@earendil-works/pi-tui', 'dist/index.js');
const piAi = packageEntry('@earendil-works/pi-ai', 'dist/index.js');
const piAiCompat = packageFile('@earendil-works/pi-ai', 'dist/compat.js');
const piAiOauth = packageFile('@earendil-works/pi-ai', 'dist/oauth.js');
const piAiProvidersAll = packageFile('@earendil-works/pi-ai', 'dist/providers/all.js');
const typebox = packageEntry('typebox', 'build/index.mjs');
const typeboxCompile = packageFile('typebox', 'build/compile/index.mjs');
const typeboxValue = packageFile('typebox', 'build/value/index.mjs');
const aliases = {
  '@earendil-works/pi-coding-agent': piModuleEntry,
  '@earendil-works/pi-agent-core': piAgentCore,
  '@earendil-works/pi-tui': piTui,
  '@earendil-works/pi-ai': piAi,
  '@earendil-works/pi-ai/compat': piAiCompat,
  '@earendil-works/pi-ai/oauth': piAiOauth,
  '@earendil-works/pi-ai/providers/all': piAiProvidersAll,
  '@mariozechner/pi-coding-agent': piModuleEntry,
  '@mariozechner/pi-agent-core': piAgentCore,
  '@mariozechner/pi-tui': piTui,
  '@mariozechner/pi-ai': piAi,
  '@mariozechner/pi-ai/compat': piAiCompat,
  '@mariozechner/pi-ai/oauth': piAiOauth,
  '@mariozechner/pi-ai/providers/all': piAiProvidersAll,
  typebox,
  'typebox/compile': typeboxCompile,
  'typebox/value': typeboxValue,
  '@sinclair/typebox': typebox,
  '@sinclair/typebox/compile': typeboxCompile,
  '@sinclair/typebox/value': typeboxValue,
};
const importer = jiti(piCliEntry, { moduleCache: false, alias: aliases, tryNative: false });

async function verify(name, entry) {
  try {
    const loaded = await importer.import(entry, { default: true });
    if (typeof loaded !== 'function') die(`${name} entry is not an extension factory: ${entry}`);
    console.log(`PI EXTENSION LOAD ${name} ${entry}`);
  } catch (error) {
    die(`${name} failed to import ${entry}: ${error instanceof Error ? error.message : String(error)}`);
  }
}

(async () => {
  for (const name of catalog.openwrtPiExtensions) {
    for (const entry of packageEntries(nodeModules, name)) await verify(name, entry);
  }
  if (options.vendorExtension) await verify('pi-plan-mode', path.resolve(options.vendorExtension));
  console.log('PI EXTENSIONS OK');
})().catch(error => die(error instanceof Error ? error.stack || error.message : String(error)));
