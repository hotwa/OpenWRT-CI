#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');

function fail(message) {
  process.stderr.write(`pi-settings-merge: ${message}\n`);
  process.exit(1);
}

function readSettings(filename, label) {
  let stat;
  try {
    stat = fs.lstatSync(filename);
  } catch {
    fail(`${label} settings file is unavailable`);
  }
  if (!stat.isFile() || stat.isSymbolicLink()) {
    fail(`${label} settings path is not a regular file`);
  }

  let parsed;
  try {
    parsed = JSON.parse(fs.readFileSync(filename, 'utf8'));
  } catch {
    fail(`${label} settings JSON is invalid; original file preserved`);
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    fail(`${label} settings JSON must be an object; original file preserved`);
  }
  return { parsed, stat };
}

function packageList(settings, label, allowMissing) {
  if (settings.packages === undefined && allowMissing) return [];
  if (!Array.isArray(settings.packages) ||
      settings.packages.some(item => typeof item !== 'string' || item.length === 0)) {
    fail(`${label} settings packages must be an array of non-empty strings; original file preserved`);
  }
  return settings.packages;
}

function isNonRegistrySpec(packageSpec) {
  return packageSpec.startsWith('.') ||
    packageSpec.startsWith('/') ||
    packageSpec.startsWith('\\') ||
    packageSpec.startsWith('~') ||
    /^[A-Za-z]:[\\/]/.test(packageSpec) ||
    /^[A-Za-z][A-Za-z0-9+.-]*:/.test(packageSpec) ||
    /^[^/@\s]+@[^:\s]+:/.test(packageSpec);
}

function registryPackageName(packageSpec) {
  if (isNonRegistrySpec(packageSpec)) return null;

  if (packageSpec.startsWith('@')) {
    const slash = packageSpec.indexOf('/');
    if (slash <= 1) return null;
    const versionAt = packageSpec.indexOf('@', slash + 1);
    const packageName = versionAt === -1 ? packageSpec : packageSpec.slice(0, versionAt);
    if (!/^@[^@/\\\s:]+\/[^@/\\\s:]+$/.test(packageName)) return null;
    return packageName;
  }

  const versionAt = packageSpec.indexOf('@');
  const packageName = versionAt === -1 ? packageSpec : packageSpec.slice(0, versionAt);
  if (!/^[^@/\\\s:]+$/.test(packageName)) return null;
  return packageName;
}

function packageIdentity(packageSpec) {
  const registrySpec = packageSpec.startsWith('npm:')
    ? packageSpec.slice('npm:'.length)
    : packageSpec;
  const packageName = registryPackageName(registrySpec);
  return packageName === null
    ? `literal:${packageSpec}`
    : `registry:${packageName}`;
}

function protocolState(stat) {
  return `${stat.dev}:${stat.ino}:${stat.mtimeNs / 1000000000n}:${stat.size}`;
}

if (process.argv.length !== 4) {
  fail('usage: pi-settings-merge.js <firmware-settings.json> <persistent-settings.json>');
}

const firmwarePath = process.argv[2];
const persistentPath = process.argv[3];
const firmware = readSettings(firmwarePath, 'firmware');
const persistent = readSettings(persistentPath, 'persistent');
const defaults = packageList(firmware.parsed, 'firmware', false);
const existing = packageList(persistent.parsed, 'persistent', true);
const seen = new Set(existing.map(packageIdentity));
const additions = [];

for (const packageName of defaults) {
  const identity = packageIdentity(packageName);
  if (!seen.has(identity)) {
    seen.add(identity);
    additions.push(packageName);
  }
}

if (additions.length === 0) {
  process.stdout.write('unchanged\n');
  process.exit(0);
}

const merged = {
  ...persistent.parsed,
  packages: [...existing, ...additions],
};
const targetDir = path.dirname(persistentPath);
const targetName = path.basename(persistentPath);
const temporaryPath = path.join(
  targetDir,
  `.${targetName}.new.${process.pid}.${Date.now()}`,
);
let temporaryCreated = false;
let stagedState = '';

try {
  const mode = persistent.stat.mode & 0o7777;
  const fd = fs.openSync(temporaryPath, 'wx', mode);
  temporaryCreated = true;
  try {
    const temporaryStat = fs.fstatSync(fd);
    if (temporaryStat.uid !== persistent.stat.uid || temporaryStat.gid !== persistent.stat.gid) {
      fs.fchownSync(fd, persistent.stat.uid, persistent.stat.gid);
    }
    // chown(2) may clear special permission bits, so apply the original mode
    // after ownership has been restored.
    fs.fchmodSync(fd, mode);
    fs.writeFileSync(fd, `${JSON.stringify(merged, null, 2)}\n`, 'utf8');
    fs.fsyncSync(fd);
    stagedState = protocolState(fs.fstatSync(fd, { bigint: true }));
  } finally {
    fs.closeSync(fd);
  }

  // Do not overwrite a settings file that changed while the merge was being
  // prepared. A later boot can retry against the administrator's new file.
  const current = fs.lstatSync(persistentPath);
  if (!current.isFile() || current.isSymbolicLink() ||
      current.dev !== persistent.stat.dev || current.ino !== persistent.stat.ino ||
      current.size !== persistent.stat.size || current.mtimeMs !== persistent.stat.mtimeMs ||
      current.uid !== persistent.stat.uid || current.gid !== persistent.stat.gid ||
      (current.mode & 0o7777) !== (persistent.stat.mode & 0o7777)) {
    throw new Error('persistent settings changed during merge; original file preserved');
  }

  fs.renameSync(temporaryPath, persistentPath);
  temporaryCreated = false;
  const published = fs.lstatSync(persistentPath, { bigint: true });
  if (!published.isFile() || published.isSymbolicLink() ||
      protocolState(published) !== stagedState) {
    throw new Error('published settings changed before confirmation; marker must remain unchanged');
  }
  process.stdout.write(`changed ${stagedState}\n`);
} catch (error) {
  if (temporaryCreated) {
    try {
      fs.unlinkSync(temporaryPath);
    } catch {
      // Preserve the primary failure; the unique temporary file contains no
      // data beyond the already-existing settings object.
    }
  }
  fail(error instanceof Error ? error.message : 'atomic settings update failed');
}
