'use strict';
const assert = require('node:assert/strict');
const {wifiProfiles, makeTemplate, matches, reconcile, mac, inLAN, discoverAPs, parseJSON} = require('../files/usr/libexec/gecoosac-auto.js');
const preset = {fallback_ssid: 'Fixture AP', fallback_key: 'fixture-pass'};
const base = {tempid: 'default', name: 'default', enable: 'no', reference: 0,
  roamtrigger: '-100',
  '2g': {htmode: 'HT40', suffix: '', channel: '1', txpower: '10'},
  '5g': {htmode: 'HT80', suffix: '_5G', channel: '36', txpower: '10'},
  '5g2': {htmode: 'HT160', suffix: '_5G2', channel: '149', txpower: '10'},
  ssid1: {maxassoc: '48', disablekvr: 'yes'}};
const target = {mac: '02:00:00:00:00:01', id: 'fixture-ap'};

async function tests() {
  assert.equal(mac('02:00:00:00:00:01'), '020000000001');
  assert.equal(mac('not-a-mac'), '');
  assert.throws(() => parseJSON('{"key":"fixture-secret"', 'profile'),
    error => error.message === 'profile is invalid JSON');
  const fallback = wifiProfiles({}, {}, preset);
  assert.equal(fallback.source, 'preset');
  assert.deepEqual(fallback.entries[0].bands, ['2g', '5g']);
  assert.throws(() => wifiProfiles({}, {}, {...preset, fallback_key: ''}), /password/);
  const values = {
    radio0: {'.type': 'wifi-device', band: '2g'},
    radio1: {'.type': 'wifi-device', band: '5g'},
    radio2: {'.type': 'wifi-device', band: '5g'},
    first: {'.type': 'wifi-iface', device: 'radio0', mode: 'ap', network: 'lan',
      ssid: 'LAN', encryption: 'psk2+ccmp', key: 'fixture-pass'},
    second: {'.type': 'wifi-iface', device: 'radio1', mode: 'ap', network: ['lan'],
      ssid: 'LAN', encryption: 'psk2+ccmp', key: 'fixture-pass'},
    third: {'.type': 'wifi-iface', device: 'radio2', mode: 'ap', network: 'lan',
      ssid: 'LAN high', encryption: 'sae-mixed', key: 'fixture-pass'},
    guest: {'.type': 'wifi-iface', device: 'radio0', mode: 'ap', network: 'guest',
      ssid: 'Guest', encryption: 'none'}
  };
  const runtime = {radio0: {up: true}, radio1: {up: true}, radio2: {up: true}};
  const router = wifiProfiles(values, runtime, preset);
  assert.equal(router.source, 'router-wifi');
  assert.equal(router.entries.length, 2);
  assert.deepEqual(router.entries[0].bands, ['2g', '5g']);
  assert.equal(router.entries[1].encryption, 'wpa_2_3');
  assert.throws(() => wifiProfiles(values, {}, preset), /not ready/);
  assert.throws(() => wifiProfiles({...values, second: {...values.second, key: 'other-pass'}}, runtime, preset), /conflicting/);
  assert.throws(() => wifiProfiles({...values, first: {...values.first, encryption: 'wpa2'}}, runtime, preset), /unsupported/);
  const template = makeTemplate(base, fallback.entries, 'managed');
  assert.equal(template.ssid1['2g'], 'yes');
  assert.equal(template.ssid1['5g'], 'yes');
  assert.equal(template.ssid1['5g2'], 'yes');
  assert.equal(template['5g'].suffix, '');
  assert.equal(template.ssid2.enable, 'no');
  assert.equal(template.ssid1.encryption, 'wpa_2');
  assert.equal(template.roamtrigger, '-79');
  assert.equal(template.ssid1.disablekvr, 'no');
  for (const band of ['2g', '5g', '5g2']) {
    assert.equal(template[band].channel, 'auto');
    assert.equal(template[band].txpower, 'auto');
  }
  assert.equal(matches(template, {...template, reference: 1}), true);

  let posts = [], aps = [], templates = [base];
  const ac = {async call(route, body) {
    if (body) posts.push([route, structuredClone(body)]);
    if (route.startsWith('apsearch')) return {aplist: structuredClone(aps)};
    if (route === 'tempview') return {templist: structuredClone(templates)};
    if (route === 'tempedit') {
      const t = {...body, tempid: body.tempid || 'managed', reference: 1};
      templates = [base, t]; return {ret: 1};
    }
    if (route === 'apcmd') {
      assert.equal(body.maclist, '020000000001');
      aps[0].template = body.template; return {ret: 1};
    }
    throw new Error('unexpected request');
  }};
  await reconcile(ac, [target], fallback.entries);
  assert.equal(posts.length, 0, 'no AP must produce no POST');
  aps = [{mac: target.mac, ap_pid: 'wrong-identifier', online: 'yes'}];
  assert.equal((await reconcile(ac, [target], fallback.entries))[0].result, 'identity-or-version-mismatch');
  assert.equal(posts.length, 0);
  aps = [{mac: target.mac, ap_pid: target.id, online: 'no'}];
  await reconcile(ac, [target], fallback.entries);
  assert.equal(posts.length, 0, 'offline AP must receive no command');
  aps = [{mac: target.mac, ap_pid: target.id, online: 'yes', template: 'default'},
    {mac: '020000000099', ap_pid: 'foreign', online: 'yes', template: 'default'}];
  assert.equal((await reconcile(ac, [target], fallback.entries))[0].result, 'queued');
  assert.deepEqual(posts.map(p => p[0]), ['tempedit', 'apcmd']);
  assert.equal(aps[1].template, 'default', 'unlisted AP must remain unassigned');
  posts = [];
  assert.equal((await reconcile(ac, [target], fallback.entries))[0].result, 'unchanged');
  assert.equal(posts.length, 0, 'repeat run must produce no POST');
  templates[1].roamtrigger = '-100';
  templates[1].ssid1.disablekvr = 'yes';
  await reconcile(ac, [target], fallback.entries);
  assert.deepEqual(posts.map(p => p[0]), ['tempedit'], 'restore managed roaming policy');
  posts = [];
  await reconcile(ac, [target], fallback.entries);
  assert.equal(posts.length, 0, 'restored roaming policy is stable');
  const changed = [{...fallback.entries[0], key: 'changed-pass'}];
  await reconcile(ac, [target], changed);
  assert.deepEqual(posts.map(p => p[0]), ['tempedit'], 'AC pulls updates without repeated assignment');
  templates[0] = {...base, enable: 'yes'};
  await assert.rejects(reconcile(ac, [target], changed), /default template/);

  const lan = [{address: '192.168.10.1', mask: 24}];
  assert.equal(inLAN('192.168.10.224', lan), true);
  for (const ip of ['192.168.11.224', '192.168.10.0', '192.168.10.255',
                    '192.168.10.1', 'not-an-ip', '::1']) assert.equal(inLAN(ip, lan), false);
  assert.equal(inLAN('6.7.8.9', [{address: '6.7.8.9', mask: 32}]), false);
  const newAP = {mac: '020000000002', ap_pid: 'GCOAP-M0001-00001-00001-00001',
    online: 'yes', ip: '192.168.10.224', is_low_version: false, template: 'default'};
  const found = [{mac: newAP.mac, id: newAP.ap_pid}];
  assert.deepEqual(discoverAPs([newAP], [], lan), found);
  assert.deepEqual(discoverAPs([newAP, newAP], [], lan), found, 'deduplicate discovered APs');
  assert.deepEqual(discoverAPs([newAP], found, lan), []);
  for (const patch of [{online: 'no'}, {ip: '192.168.11.224'}, {is_low_version: true},
                       {is_low_version: undefined}, {ap_pid: 'foreign'}, {mac: 'invalid'}]) {
    assert.deepEqual(discoverAPs([{...newAP, ...patch}], [], lan), []);
  }
  assert.deepEqual(discoverAPs([{...newAP, mac: '020000000003'}], found, lan), [], 'do not adopt a conflicting device ID');
  let saved = [], adoptionPosts = [];
  let adoptionTemplates = [base];
  const adoptionAC = {async call(route, body) {
    if (body) adoptionPosts.push(route);
    if (route.startsWith('apsearch')) return {aplist: [newAP]};
    if (route === 'tempview') return {templist: structuredClone(adoptionTemplates)};
    if (route === 'tempedit') {
      adoptionTemplates = [base, {...body, tempid: 'managed'}]; return {ret: 1};
    }
    if (route === 'apcmd') {
      assert.deepEqual(saved, found, 'persist identity before assignment');
      assert.equal(body.maclist, newAP.mac);
      newAP.template = body.template; return {ret: 1};
    }
    throw new Error('unexpected adoption request');
  }};
  await reconcile(adoptionAC, [], fallback.entries);
  assert.equal(adoptionPosts.length, 0, 'fixed-list mode must not adopt new APs');
  const adoption = {autoAdopt: true, lan, onDiscovered: targets => {saved = targets;}};
  const adopted = await reconcile(adoptionAC, [], fallback.entries, adoption);
  assert.equal(adopted[0].adopted, true);
  assert.equal(adopted[0].result, 'queued');
  assert.deepEqual(adoptionPosts, ['tempedit', 'apcmd']);
  adoptionPosts = [];
  await reconcile(adoptionAC, saved, fallback.entries, adoption);
  assert.equal(adoptionPosts.length, 0, 'adopted AP must remain stable on later checks');
  await reconcile(adoptionAC, [], fallback.entries, {...adoption, lan: []});
  assert.equal(adoptionPosts.length, 0, 'unavailable LAN subnet must prevent adoption');
  console.log('gecoosac-auto functional tests passed');
}
tests().catch(e => { console.error(e); process.exitCode = 1; });
