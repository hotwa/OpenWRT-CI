#!/usr/bin/env node
'use strict';

// Probe legacy native backends only while CommandCode declares or ships them.
// Resolve from CommandCode itself, including nested npm dependencies.
const fs = require('node:fs');
const path = require('node:path');
const { createRequire } = require('node:module');
const directory = process.argv[2];
if (!directory || process.argv.length !== 3) {
  console.error('Usage: verify_commandcode_native.js <node-prefix>');
  process.exit(1);
}
try {
  const manifestPath = path.resolve(directory, 'lib/node_modules/command-code/package.json');
  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  if (manifest.name !== 'command-code') throw new Error('unexpected CommandCode manifest');
  const fromCommandCode = createRequire(manifestPath);
  for (const name of ['@napi-rs/keyring', 'zigpty']) {
    const declared = Object.hasOwn(manifest.dependencies || {}, name) ||
      Object.hasOwn(manifest.optionalDependencies || {}, name);
    let resolved;
    try {
      resolved = fromCommandCode.resolve(name);
    } catch (error) {
      if (!declared && error.code === 'MODULE_NOT_FOUND') {
        console.log(`CommandCode ${manifest.version}: ${name} not declared or installed`);
        continue;
      }
      throw error;
    }
    fromCommandCode(resolved);
    console.log(`CommandCode native backend loaded: ${name}`);
  }
} catch (error) {
  console.error(`ERROR: CommandCode native probe: ${error.message}`);
  process.exit(1);
}
