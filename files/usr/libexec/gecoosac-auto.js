#!/usr/bin/env node
'use strict';

// No npm dependencies: use the firmware's immutable Node baseline.
const fs = require('node:fs');
const cp = require('node:child_process');
const crypto = require('node:crypto');
const net = require('node:net');
const {once} = require('node:events');

const BOARDS = new Set(['jdcloud,re-cs-07', 'jdcloud,re-ss-01', 'jdcloud,re-cs-02']);
const PROFILE = '/etc/gecoosac-auto/profile.json';
const DATA = '/data/gecoosac-auto';
const DB = '/etc/gecoosac';
const STATUS = '/var/run/gecoosac-auto.status.json';
const LOCK = '/var/run/gecoosac-auto.lock';
const NAME = 'OpenWrt-CI managed AP';
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

function run(file, args = [], allowFailure = false) {
  const r = cp.spawnSync(file, args, {encoding: 'utf8', timeout: 30000});
  if (r.status !== 0 && !allowFailure) throw new Error(`${file.split('/').pop()} failed`);
  return r.status === 0 ? r.stdout.trim() : '';
}
function uci(key) { return run('uci', ['-q', 'get', key], true); }
function parseJSON(text, label) {
  try { return JSON.parse(text); } catch { throw new Error(`${label} is invalid JSON`); }
}
function writePrivate(file, value) {
  fs.mkdirSync(require('node:path').dirname(file), {recursive: true, mode: 0o700});
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, `${JSON.stringify(value, null, 2)}\n`, {mode: 0o600});
  fs.renameSync(tmp, file);
}
function mac(value) {
  const normalized = String(value || '').toLowerCase().replace(/[:-]/g, '');
  return /^[0-9a-f]{12}$/.test(normalized) ? normalized : '';
}
function inLAN(ip, addresses) {
  if (net.isIP(ip) !== 4) return false;
  const number = value => value.split('.').reduce((n, octet) => (n * 256 + Number(octet)) >>> 0, 0);
  const n = number(ip);
  return addresses.some(({address, mask}) => {
    if (net.isIP(address) !== 4 || !Number.isInteger(mask) || mask < 1 || mask > 30 || ip === address) return false;
    const bits = (0xffffffff << (32 - mask)) >>> 0;
    const subnet = (number(address) & bits) >>> 0;
    const broadcast = (subnet | (~bits >>> 0)) >>> 0;
    return ((n & bits) >>> 0) === subnet && n !== subnet && n !== broadcast;
  });
}
function discoverAPs(aplist, targets, lan) {
  const known = new Set(targets.map(t => mac(t.mac)));
  const ids = new Set(targets.map(t => t.id).filter(Boolean));
  const found = [];
  for (const ap of aplist) {
    const address = mac(ap.mac);
    if (!address || known.has(address) || ap.online !== 'yes' || ap.is_low_version !== false ||
        !/^GCOAP-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}$/.test(ap.ap_pid || '') ||
        ids.has(ap.ap_pid) || !inLAN(ap.ip, lan)) continue;
    known.add(address);
    ids.add(ap.ap_pid);
    found.push({mac: address, id: ap.ap_pid});
  }
  return found;
}
function validSSID(value) {
  return typeof value === 'string' && Buffer.byteLength(value) > 0 &&
    Buffer.byteLength(value) <= 32 && !/[\x00-\x1f\x7f]/.test(value);
}
function encryption(value) {
  const mode = String(value || '').split('+')[0];
  return {psk2: 'wpa_2', psk: 'wpa_1', 'psk-mixed': 'wpa_1_2',
    sae: 'wpa_3', 'sae-mixed': 'wpa_2_3', none: 'none', owe: 'owe'}[mode];
}
function validKey(mode, key) {
  if (mode === 'none' || mode === 'owe') return true;
  return typeof key === 'string' && ((/^[\x20-\x7e]{8,63}$/.test(key)) ||
    (mode !== 'wpa_3' && mode !== 'wpa_2_3' && /^[0-9a-fA-F]{64}$/.test(key)));
}

// Mirror enabled LAN AP interfaces, including separate SSIDs on the two 5GHz
// radios of RE-CS-02. Never mirror a guest VLAN, disabled radio or STA uplink.
function wifiProfiles(values, runtime, profile) {
  const merged = new Map();
  let configured = false;
  for (const iface of Object.values(values)) {
    if (iface['.type'] !== 'wifi-iface' || iface.mode !== 'ap' ||
        String(iface.disabled || '0') === '1' ||
        !String(Array.isArray(iface.network) ? iface.network.join(' ') : iface.network || '')
          .split(/\s+/).includes('lan')) continue;
    const radio = values[iface.device];
    if (!radio || String(radio.disabled || '0') === '1') continue;
    configured = true;
    if (!runtime[iface.device]?.up) throw new Error('LAN Wi-Fi is not ready; waiting');
    const band = radio.band || (radio.hwmode === '11g' ? '2g' : '5g');
    if (!['2g', '5g'].includes(band)) throw new Error('unsupported router Wi-Fi band');
    const enc = encryption(iface.encryption);
    if (!enc || !validSSID(iface.ssid) || !validKey(enc, iface.key)) {
      throw new Error('unsupported or incomplete LAN Wi-Fi profile');
    }
    const key = ['none', 'owe'].includes(enc) ? '' : iface.key;
    if (merged.has(iface.ssid) &&
        (merged.get(iface.ssid).encryption !== enc || merged.get(iface.ssid).key !== key)) {
      throw new Error('same router SSID has conflicting credentials');
    }
    const entry = merged.get(iface.ssid) || {ssid: iface.ssid, key, encryption: enc, bands: []};
    if (!entry.bands.includes(band)) entry.bands.push(band);
    merged.set(iface.ssid, entry);
  }
  if (configured) {
    if (!merged.size || merged.size > 4) throw new Error('AC supports one to four LAN SSIDs');
    return {source: 'router-wifi', entries: [...merged.values()]};
  }
  if (!validSSID(profile.fallback_ssid) || !validKey('wpa_2', profile.fallback_key)) {
    throw new Error('fallback Wi-Fi password is not configured');
  }
  return {source: 'preset', entries: [{ssid: profile.fallback_ssid,
    key: profile.fallback_key, encryption: 'wpa_2', bands: ['2g', '5g']}]};
}
function makeTemplate(base, entries, id) {
  const t = structuredClone(base);
  t.tempid = id || '';
  t.name = NAME;
  t.enable = 'yes';
  t.autoreboot = '0';
  // Keep the managed roaming policy stable even if the upstream default changes.
  t.roamtrigger = '-79';
  t.customConf = null;
  for (const band of ['2g', '5g', '5g2']) {
    t[band] = {...t[band], channel: 'auto', txpower: 'auto', suffix: ''};
  }
  for (const key of ['ext_vlan', 'ext2_vlan', 'ext3_vlan', 'ext4_vlan']) t[key] = '';
  for (let i = 1; i <= 4; i++) {
    const e = entries[i - 1];
    t[`ssid${i}`] = {...base.ssid1, enable: e ? 'yes' : 'no', ssid: e?.ssid || '',
      key: e?.key || '', encryption: e?.encryption || 'none',
      '2g': e?.bands.includes('2g') ? 'yes' : 'no',
      '5g': e?.bands.includes('5g') ? 'yes' : 'no',
      '5g2': e?.bands.includes('5g') ? 'yes' : 'no',
      disablekvr: 'no', hidden: 'no', isolate: 'no', vlan: '', macpolicy: '', timerange: '',
      weekdays: '', daystype: '', r_key: '', mlo_enable: 'no'};
  }
  delete t.reference;
  return t;
}
function matches(expected, actual) {
  if (expected === null || typeof expected !== 'object') return expected === actual;
  return actual !== null && typeof actual === 'object' &&
    Object.entries(expected).every(([k, v]) => matches(v, actual[k]));
}

class AC {
  constructor(port, password) { this.url = `http://127.0.0.1:${port}/api/`; this.password = password; }
  async raw(route, body) {
    const r = await fetch(this.url + route, {method: body === undefined ? 'GET' : 'POST',
      headers: {'Content-Type': 'application/json', sysauth: this.token || ''},
      body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(8000)});
    if (!r.ok) throw new Error(`AC HTTP ${r.status}`);
    try { return await r.json(); } catch { throw new Error('AC response is invalid JSON'); }
  }
  async login() {
    const r = await this.raw('getrandom');
    if (!r.random) throw new Error('AC challenge is unavailable');
    const password = crypto.createHash('md5').update(r.random + this.password).digest('hex');
    const result = await this.raw('sysauth', {password});
    if (result.ret !== 1 || !result.token) throw new Error('AC login failed');
    this.token = result.token;
  }
  async call(route, body) {
    if (!this.token) await this.login();
    let r = await this.raw(route, body);
    if (r.ret === -99) { await this.login(); r = await this.raw(route, body); }
    if (r.ret !== 1) throw new Error(`AC ${route.split('?')[0]} rejected request`);
    return r;
  }
}

async function reconcile(ac, targets, entries, options = {}) {
  const result = [];
  const list = await ac.call('apsearch?numperpage=1000&pagenum=1');
  const discovered = options.autoAdopt ? discoverAPs(list.aplist || [], targets, options.lan || []) : [];
  if (discovered.length && options.onDiscovered) await options.onDiscovered(discovered);
  const online = [];
  for (const target of [...targets, ...discovered]) {
    const ap = (list.aplist || []).find(a => mac(a.mac) === mac(target.mac));
    if (!ap || ap.online !== 'yes') { result.push({mac: target.mac, result: 'absent'}); continue; }
    if ((target.id && ap.ap_pid !== target.id) || ap.is_low_version) {
      result.push({mac: target.mac, result: 'identity-or-version-mismatch'}); continue;
    }
    online.push(ap);
  }
  // No AP match means no POST, including no template modification.
  if (!online.length) return result;
  const templates = await ac.call('tempview');
  const base = templates.templist.find(t => t.tempid === 'default');
  if (!base || base.enable !== 'no') throw new Error('default template must be disabled');
  let current = templates.templist.find(t => t.name === NAME);
  const wanted = makeTemplate(base, entries, current?.tempid);
  const changed = !current || !matches(wanted, current);
  if (changed) {
    await ac.call('tempedit', wanted);
    const refreshed = await ac.call('tempview');
    current = refreshed.templist.find(t => t.name === NAME);
    if (!current || !matches({...wanted, tempid: current.tempid}, current)) {
      throw new Error('AC did not save the requested template');
    }
  }
  for (const ap of online) {
    const needsAssignment = ap.template !== current.tempid;
    if (needsAssignment) {
      await ac.call('apcmd', {maclist: mac(ap.mac), cmd: 'settemplate', template: current.tempid});
    }
    result.push({mac: ap.mac, model: ap.model, ip: ap.ip,
      result: changed || needsAssignment ? 'queued' : 'unchanged',
      ...(discovered.some(t => t.mac === mac(ap.mac)) ? {adopted: true} : {}),
      template: current.tempid, synctime: ap.synctime || ''});
  }
  return result;
}

function dataMounted() {
  return fs.readFileSync('/proc/mounts', 'utf8').split('\n').some(line => {
    const f = line.split(' ');
    return f[1] === '/data' && ['ext4', 'f2fs', 'btrfs', 'xfs'].includes(f[2]) && f[3].split(',').includes('rw');
  });
}
function loadProfile() {
  const baked = parseJSON(fs.readFileSync(PROFILE, 'utf8'), 'firmware AP profile');
  if (!dataMounted()) throw new Error('persistent /data is not ready; waiting');
  fs.mkdirSync(DATA, {recursive: true, mode: 0o700});
  fs.chmodSync(DATA, 0o700);
  const saved = `${DATA}/profile.json`;
  if (!fs.existsSync(saved)) writePrivate(saved, baked);
  const profile = parseJSON(fs.readFileSync(saved, 'utf8'), 'persistent AP profile');
  let updated = false;
  // A new private image can provision an initially unconfigured data profile.
  if (!profile.fallback_key && baked.fallback_key) {
    profile.fallback_key = baked.fallback_key;
    updated = true;
  }
  // Upgrade the earlier fixed-list profile; an explicit local false is retained.
  if (typeof profile.auto_adopt !== 'boolean' && typeof baked.auto_adopt === 'boolean') {
    profile.auto_adopt = baked.auto_adopt;
    updated = true;
  }
  if (updated) writePrivate(saved, profile);
  if (!Array.isArray(profile.targets) || (!profile.targets.length && !profile.auto_adopt) ||
      profile.targets.some(t => !mac(t.mac))) throw new Error('AP allowlist is invalid');
  return profile;
}

async function bootstrap(db, password) {
  const server = net.createServer();
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const port = server.address().port;
  await new Promise(resolve => server.close(resolve));
  const dir = fs.mkdtempSync('/tmp/gecoosac-auto-bootstrap-');
  const child = cp.spawn('/usr/bin/gecoosac', ['-p', String(port), '-isonlyoneprot', '1',
    '-dbpath', `${db}/`, '-f', `${dir}/`, '-piddir', `${dir}/`, '-showtip', '0', '-token', '1',
    '-debug', '0'], {stdio: 'ignore'});
  let spawnError = false;
  child.on('error', () => { spawnError = true; });
  const exited = once(child, 'exit').catch(() => {});
  try {
    const ac = new AC(port, password);
    let templates;
    for (let i = 0; i < 30; i++) {
      if (spawnError || child.exitCode !== null) throw new Error('AC bootstrap process failed');
      try { templates = await ac.call('tempview'); break; } catch { await delay(300); }
    }
    if (!templates) throw new Error('AC bootstrap API is unavailable');
    const t = templates.templist.find(t => t.tempid === 'default');
    if (!t) throw new Error('AC default template is unavailable');
    if (t.enable !== 'no') { t.enable = 'no'; await ac.call('tempedit', t); }
  } finally {
    child.kill('SIGTERM');
    const timer = setTimeout(() => child.kill('SIGKILL'), 5000);
    await exited;
    clearTimeout(timer);
    fs.rmSync(dir, {recursive: true, force: true});
  }
}

async function prepareAC(profile) {
  const persistent = `${DATA}/ac-db`;
  fs.mkdirSync(persistent, {recursive: true, mode: 0o700});
  fs.mkdirSync(DB, {recursive: true, mode: 0o700});
  // Keep the package's supported logical DB path; use a bind mount rather than
  // a symlink so both old and new upstream path guards accept the directory.
  const a = fs.statSync(persistent), b = fs.statSync(DB);
  const bound = a.dev === b.dev && a.ino === b.ino;
  const ready = `${DATA}/prepared-v1`;
  if (!bound || !fs.existsSync(ready)) {
    run('/etc/init.d/gecoosac', ['stop']);
    run('/etc/init.d/gecoosac', ['disable']);
    if (!bound && !fs.existsSync(`${persistent}/data.db`) && fs.existsSync(`${DB}/data.db`)) {
      fs.cpSync(DB, persistent, {recursive: true, preserveTimestamps: true});
    }
    await bootstrap(persistent, profile.ac_password || 'admin');
    if (!bound) run('mount', ['-o', 'bind', persistent, DB]);
    fs.writeFileSync(ready, 'default-template-disabled\n', {mode: 0o600});
  }
  let configChanged = false;
  for (const [key, value] of Object.entries({enabled: '1', db_dir: `${DB}/`,
    port: '60650', isonlyoneprot: '1', debug: '0', log_level: 'info', showtip: '0'})) {
    if (uci(`gecoosac.config.${key}`) !== value) {
      run('uci', ['set', `gecoosac.config.${key}=${value}`]);
      configChanged = true;
    }
  }
  if (configChanged) run('uci', ['commit', 'gecoosac']);
  // The auto worker owns startup: native AC must not open a fresh default DB
  // at S90 before /data and the disabled default template have been prepared.
  run('/etc/init.d/gecoosac', ['disable']);
  const ac = new AC(60650, profile.ac_password || 'admin');
  try { await ac.call('basicview'); } catch {
    run('/etc/init.d/gecoosac', ['start']);
    for (let i = 0; i < 20; i++) {
      try { await ac.call('basicview'); break; } catch {
        if (i === 19) throw new Error('AC service is unavailable');
        await delay(300);
      }
    }
  }
  const lan = parseJSON(run('ubus', ['call', 'network.interface.lan', 'status']), 'LAN status');
  if (!lan.up || !lan.l3_device || !/^[A-Za-z0-9_.:-]+$/.test(lan.l3_device)) {
    throw new Error('LAN is not ready');
  }
  const addresses = run('ip', ['-4', 'addr', 'show', 'dev', lan.l3_device]);
  if (!/inet 6\.7\.8\.9\/32\b/.test(addresses)) {
    run('ip', ['addr', 'add', '6.7.8.9/32', 'dev', lan.l3_device]);
  }
  return {ac, lan: lan['ipv4-address'] || []};
}

async function main() {
  let board;
  try { board = fs.readFileSync('/tmp/sysinfo/board_name', 'utf8').trim(); } catch { return; }
  if (!BOARDS.has(board)) return;
  const profile = loadProfile();
  if (!profile.enabled) return;
  // Missing credentials or a not-yet-ready router WLAN must not start AC.
  const values = parseJSON(run('ubus', ['call', 'uci', 'get', '{"config":"wireless"}'], true) || '{}', 'Wi-Fi configuration').values || {};
  const runtime = parseJSON(run('ubus', ['call', 'network.wireless', 'status'], true) || '{}', 'Wi-Fi status');
  const desired = wifiProfiles(values, runtime, profile);
  const {ac, lan} = await prepareAC(profile);
  const results = await reconcile(ac, profile.targets, desired.entries, {
    autoAdopt: profile.auto_adopt === true, lan,
    onDiscovered: discovered => {
      // Save identity before assignment so an interrupted run can retry safely.
      profile.targets = [...profile.targets, ...discovered];
      writePrivate(`${DATA}/profile.json`, profile);
    }
  });
  writePrivate(STATUS, {time: new Date().toISOString(), board, source: desired.source,
    ssids: desired.entries.map(e => ({ssid: e.ssid, bands: e.bands})), results});
  if (results.some(r => r.result === 'queued')) {
    console.log('gecoosac-auto: queued Wi-Fi template for allowlisted AP(s)');
  }
}

async function lockedMain() {
  try { fs.mkdirSync(LOCK, {mode: 0o700}); } catch (error) {
    if (error.code !== 'EEXIST') throw error;
    let pid;
    try { pid = Number(fs.readFileSync(`${LOCK}/pid`, 'utf8')); } catch {
      // Another instance may have created the directory but not the PID yet.
      if (Date.now() - fs.statSync(LOCK).mtimeMs < 30000) return;
    }
    if (Number.isInteger(pid) && pid > 0 && fs.existsSync(`/proc/${pid}`)) {
      const command = fs.readFileSync(`/proc/${pid}/cmdline`, 'utf8');
      if (command.includes('gecoosac-auto.js')) return;
    }
    fs.rmSync(LOCK, {recursive: true});
    fs.mkdirSync(LOCK, {mode: 0o700});
  }
  fs.writeFileSync(`${LOCK}/pid`, String(process.pid), {mode: 0o600});
  try { await main(); } finally { fs.rmSync(LOCK, {recursive: true, force: true}); }
}

module.exports = {mac, inLAN, discoverAPs, wifiProfiles, makeTemplate, matches, reconcile, AC, parseJSON};
if (require.main === module) lockedMain().catch(error => {
  // Error messages are deliberately stage-only; never log UCI/API payloads.
  writePrivate(STATUS, {time: new Date().toISOString(), error: error.message});
  console.error(`gecoosac-auto: ${error.message}`);
  process.exitCode = 1;
});
