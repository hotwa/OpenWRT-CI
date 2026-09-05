#!/usr/bin/env node
'use strict';

// Resolve the build's latest Pi/plugin catalog, then make the extension tree
// expose the same @earendil-works generation as the installed Pi CLI.  This is
// intentionally a build-staging operation: it never edits the repository
// catalog or a router's existing /data project tree.

const childProcess = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

function die(message) {
  console.error(`ERROR: [pi-extension-peers] ${message}`);
  process.exit(1);
}

function parseArgs(argv) {
  const options = { os: 'linux', cpu: '', libc: 'musl' };
  for (let index = 2; index < argv.length; index += 1) {
    const key = argv[index];
    if (!['--directory', '--os', '--cpu', '--libc'].includes(key)) die(`unknown argument: ${key}`);
    const value = argv[++index];
    if (!value) die(`missing value for ${key}`);
    options[key.slice(2)] = value;
  }
  if (!options.directory || !options.cpu) die('--directory and --cpu are required');
  return options;
}

const options = parseArgs(process.argv);
const stagingDir = path.resolve(options.directory);
const packagePath = path.join(stagingDir, 'package.json');
const nodeModules = path.join(stagingDir, 'node_modules');
const piPackage = '@earendil-works/pi-coding-agent';

if (!fs.existsSync(packagePath)) die(`missing catalog: ${packagePath}`);
const catalog = JSON.parse(fs.readFileSync(packagePath, 'utf8'));
if (!catalog.dependencies || typeof catalog.dependencies !== 'object') die('catalog has no dependencies object');
if (!Array.isArray(catalog.openwrtPiExtensions) || catalog.openwrtPiExtensions.length === 0) {
  die('catalog has no openwrtPiExtensions list');
}
for (const [name, selector] of Object.entries(catalog.dependencies)) {
  if (selector !== 'latest') die(`catalog dependency ${name} must use latest, got ${JSON.stringify(selector)}`);
}

function npmInstall() {
  const npmBinary = process.env.NPM || (process.platform === 'win32' ? 'npm.cmd' : 'npm');
  const result = childProcess.spawnSync(npmBinary, [
    'install',
    '--prefix', stagingDir,
    '--omit=dev',
    '--no-audit',
    '--no-fund',
    '--ignore-scripts',
    '--legacy-peer-deps',
    `--os=${options.os}`,
    `--cpu=${options.cpu}`,
    `--libc=${options.libc}`,
  ], { stdio: 'inherit', env: process.env, shell: process.platform === 'win32' });
  if (result.error) die(`npm install could not start: ${result.error.message}`);
  if (result.status !== 0) die(`npm install failed with exit status ${result.status ?? 'unknown'}`);
}

function readPackage(name) {
  const filename = path.join(nodeModules, ...name.split('/'), 'package.json');
  if (!fs.existsSync(filename)) die(`resolved package is missing: ${name}`);
  const pkg = JSON.parse(fs.readFileSync(filename, 'utf8'));
  if (!/^\d+\.\d+\.\d+(?:[-+].*)?$/.test(pkg.version || '')) die(`resolved ${name} has invalid version`);
  return { filename, pkg };
}

function peerNames() {
  const peers = new Set([piPackage]);
  for (const extension of catalog.openwrtPiExtensions) {
    const { pkg } = readPackage(extension);
    for (const group of [pkg.peerDependencies, pkg.dependencies, pkg.optionalDependencies]) {
      for (const name of Object.keys(group || {})) {
        if (name.startsWith('@earendil-works/')) peers.add(name);
      }
    }
  }
  return [...peers].sort();
}

// A package-lock location can itself be nested below an @earendil-works
// package.  Match only the package directory, never arbitrary descendants
// such as @earendil-works/pi-coding-agent/node_modules/@aws-sdk/... .
function earendilNamesFromLock(lock) {
  const names = new Set();
  for (const location of Object.keys(lock.packages || {})) {
    const match = location.match(/(?:^|\/)node_modules\/(@earendil-works\/[^/]+)$/);
    if (match) names.add(match[1]);
  }
  return names;
}

// First resolve every requested extension at its registry latest.  Only then do
// we know the Pi generation and the peer names that the selected plugin set
// actually imports.
npmInstall();
const piVersion = readPackage(piPackage).pkg.version;
const initialLockPath = path.join(stagingDir, 'package-lock.json');
if (!fs.existsSync(initialLockPath)) die('initial npm install did not write package-lock.json');
const initialLock = JSON.parse(fs.readFileSync(initialLockPath, 'utf8'));
const peers = [...new Set([...peerNames(), ...earendilNamesFromLock(initialLock)])].sort();

// These additions exist only in the staging package.json/lock.  They give the
// independent extension tree a top-level, exact peer API that matches Pi; the
// repository catalog remains latest-at-build and does not hard-code a Pi
// generation.
for (const peer of peers) catalog.dependencies[peer] = piVersion;
// Top-level dependencies alone cannot repair a plugin that pins an old
// @earendil-works package beneath its own node_modules. These generated
// overrides make npm install one exact Pi API generation throughout this
// staging tree. They are deliberately not written to the source catalog.
catalog.overrides = { ...(catalog.overrides || {}) };
for (const peer of peers) catalog.overrides[peer] = piVersion;
fs.writeFileSync(packagePath, `${JSON.stringify(catalog, null, 2)}\n`);
npmInstall();

const lockPath = path.join(stagingDir, 'package-lock.json');
if (!fs.existsSync(lockPath)) die('npm did not write package-lock.json');
const lock = JSON.parse(fs.readFileSync(lockPath, 'utf8'));
const mismatches = [];
for (const [location, entry] of Object.entries(lock.packages || {})) {
  const match = location.match(/(?:^|\/)node_modules\/(@earendil-works\/[^/]+)$/);
  if (!match) continue;
  const name = match[1];
  if (entry.version !== piVersion) mismatches.push(`${name}@${entry.version || 'missing'} (${location})`);
}
if (mismatches.length) {
  die(`Pi ${piVersion} peer mismatch: ${mismatches.join('; ')}`);
}
for (const peer of peers) {
  const resolved = readPackage(peer).pkg.version;
  if (resolved !== piVersion) die(`top-level ${peer}@${resolved} differs from Pi ${piVersion}`);
}

const components = {};
for (const name of Object.keys(catalog.dependencies).sort()) components[name] = readPackage(name).pkg.version;
const resolved = {
  schema_version: 1,
  pi_version: piVersion,
  extension_packages: Object.fromEntries(catalog.openwrtPiExtensions.map(name => [name, components[name]])),
  aligned_peers: peers,
  components,
};
fs.writeFileSync(path.join(stagingDir, 'openwrt-agent-runtime-resolved.json'), `${JSON.stringify(resolved, null, 2)}\n`);

console.log(`PI VERSION ${piVersion}`);
console.log(`PI PEERS ALIGNED ${peers.map(name => `${name}@${piVersion}`).join(', ')}`);
console.log('PI EXTENSION DEPENDENCY TREE OK');
