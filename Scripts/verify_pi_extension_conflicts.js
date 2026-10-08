#!/usr/bin/env node
'use strict';

// Load the full firmware Pi package set through Pi's own DefaultResourceLoader.
// The import-only probe catches missing entries and peers; this complementary
// probe executes every extension factory and asks Pi to report collisions among
// tools, slash commands, flags, shortcuts, and renderers before an image ships.

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { pathToFileURL } = require('node:url');

function die(message) {
  console.error(`ERROR: [pi-extension-conflicts] ${message}`);
  process.exit(1);
}

function parseArgs(argv) {
  const options = {};
  for (let index = 2; index < argv.length; index += 1) {
    const key = argv[index];
    if (!['--directory', '--settings'].includes(key)) die(`unknown argument: ${key}`);
    const value = argv[++index];
    if (!value) die(`missing value for ${key}`);
    options[key.slice(2)] = value;
  }
  if (!options.directory || !options.settings) die('--directory and --settings are required');
  return options;
}

function readJson(filename, label) {
  try {
    return JSON.parse(fs.readFileSync(filename, 'utf8'));
  } catch (error) {
    die(`cannot parse ${label}: ${error instanceof Error ? error.message : String(error)}`);
  }
}

function isPackageName(name) {
  return /^(?:@[a-z0-9][a-z0-9._-]*\/[a-z0-9][a-z0-9._-]*|[a-z0-9][a-z0-9._-]*)$/i.test(name);
}

const options = parseArgs(process.argv);
const stagingDir = path.resolve(options.directory);
// fetch_node_runtime.sh invokes this while dependencies are still in its npm
// staging directory. The signed-generation probe invokes it after that tree
// has been installed beneath Node's normal lib/node_modules location.
const nodeModuleCandidates = [
  path.join(stagingDir, 'node_modules'),
  path.join(stagingDir, 'lib', 'node_modules'),
];
const nodeModules = nodeModuleCandidates.find(candidate => {
  try {
    return fs.statSync(candidate).isDirectory();
  } catch {
    return false;
  }
});
const catalogPath = [
  path.join(stagingDir, 'package.json'),
  path.join(stagingDir, 'agent-runtime-package.json'),
].find(candidate => fs.existsSync(candidate));
if (!nodeModules) die(`missing node_modules; checked: ${nodeModuleCandidates.join(', ')}`);
if (!catalogPath) die(`missing package catalog under: ${stagingDir}`);

const catalog = readJson(catalogPath, 'catalog');
const settings = readJson(path.resolve(options.settings), 'Pi settings');
if (!Array.isArray(catalog.openwrtPiExtensions) || !Array.isArray(catalog.openwrtPiLazyExtensions)) {
  die('catalog must provide active and lazy Pi extension lists');
}
if (!Array.isArray(settings.packages)) die('Pi settings must provide packages');
const configured = new Set(settings.packages.map(spec => typeof spec === 'string' ? spec.replace(/^npm:/, '').replace(/@[^@/]+$/, '') : ''));
for (const name of catalog.openwrtPiExtensions) {
  if (!isPackageName(name) || !configured.has(name)) die(`active extension is not configured: ${name}`);
}
for (const name of catalog.openwrtPiLazyExtensions) {
  if (!isPackageName(name) || !Object.prototype.hasOwnProperty.call(catalog.dependencies || {}, name)) {
    die(`lazy extension is not cataloged: ${name}`);
  }
}

const piRoot = path.join(nodeModules, '@earendil-works', 'pi-coding-agent');
const resourceLoaderPath = path.join(piRoot, 'dist', 'core', 'resource-loader.js');
if (!fs.existsSync(resourceLoaderPath)) die(`Pi native resource loader is missing: ${resourceLoaderPath}`);

// Pi resolves user npm packages from <agentDir>/npm/node_modules. Reuse the
// already peer-aligned staging tree by a private symlink, so this probe never
// reaches the network and cannot alter a real Pi profile.
const sandboxRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'pi-extension-conflicts-'));
const agentDir = path.join(sandboxRoot, 'agent');
const npmRoot = path.join(agentDir, 'npm');
fs.mkdirSync(npmRoot, { recursive: true });
fs.symlinkSync(nodeModules, path.join(npmRoot, 'node_modules'), process.platform === 'win32' ? 'junction' : 'dir');

const probeSettings = {
  ...settings,
  packages: [
    ...settings.packages,
    // A lazy extension is absent from the production startup list by design.
    // Load it here too so Pi's own collision detector covers the tools it
    // would register after `ext({activate: ...})`.
    ...catalog.openwrtPiLazyExtensions.map(name => `npm:${name}`),
  ],
};
fs.writeFileSync(path.join(agentDir, 'settings.json'), `${JSON.stringify(probeSettings, null, 2)}\n`, { mode: 0o600 });

(async () => {
  try {
    const { DefaultResourceLoader } = await import(pathToFileURL(resourceLoaderPath).href);
    const loader = new DefaultResourceLoader({
      cwd: sandboxRoot,
      agentDir,
      noSkills: true,
      noPromptTemplates: true,
      noThemes: true,
      noContextFiles: true,
    });
    await loader.reload();
    const result = loader.getExtensions();
    if (result.errors.length) {
      die(result.errors.map(item => `${item.path}: ${item.error}`).join('\n'));
    }
    if (!result.extensions.length) die('Pi native loader activated no extensions');
    const toolCount = result.extensions.reduce((count, extension) => count + extension.tools.size, 0);
    console.log(`PI NATIVE EXTENSION CONFLICT CHECK OK extensions=${result.extensions.length} tools=${toolCount}`);
  } catch (error) {
    die(error instanceof Error ? error.stack || error.message : String(error));
  } finally {
    fs.rmSync(sandboxRoot, { recursive: true, force: true, maxRetries: 3 });
  }
})();
