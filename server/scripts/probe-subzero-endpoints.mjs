#!/usr/bin/env node
/**
 * Probe Sub-Zero APIM for actual endpoint paths.
 *
 * Usage: node server/scripts/probe-subzero-endpoints.mjs
 *
 * Reads config from server/data/config.json to get the access token.
 * Tries many path/method/header variations for SignalR negotiate and Direct Method.
 */

import { readFileSync } from 'fs';
import { resolve, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const configPath = resolve(__dirname, '..', 'data', 'config.json');

const config = JSON.parse(readFileSync(configPath, 'utf8'));
const szConfig = config.subZero;
if (!szConfig?.accessToken) {
  console.error('No Sub-Zero access token in config. Link account first.');
  process.exit(1);
}

const API_BASE = 'https://prod.iot.subzero.com';
const TOKEN = szConfig.accessToken;
const USER_ID = szConfig.userId ?? '';

const ALL_SUB_KEYS = [
  '0e85d3216b604e51a711f147c09e228a',
  '16ca8ba0ad3f4eddaffcf8520454c2c9',
  '180fd5156a734e69b355970c9615403c',
  '25126214b7b7408283baefaec38010de',
  'a93bb184cbf944c7af266d5fa2680652',
  'e88bf0b60baf441583f822fa9ba9c895',
];

// Use the first key for path discovery; once we find a working path we'll try all keys
const PRIMARY_KEY = ALL_SUB_KEYS[0];

async function probe(method, path, key, extraHeaders = {}, body = undefined) {
  const headers = {
    'Authorization': `Bearer ${TOKEN}`,
    'Ocp-Apim-Subscription-Key': key,
    'Accept': 'application/json',
    'Content-Type': 'application/json',
    ...extraHeaders,
  };
  if (USER_ID) headers['userId'] = USER_ID;

  const opts = { method, headers };
  if (body) opts.body = JSON.stringify(body);

  try {
    const res = await fetch(`${API_BASE}${path}`, opts);
    const text = await res.text().catch(() => '');
    return { status: res.status, body: text.slice(0, 300) };
  } catch (err) {
    return { status: 0, body: `ERR: ${err.message}` };
  }
}

// ── Phase 1: SignalR negotiate endpoint discovery ──────────────────────────

const SIGNALR_PATHS = [
  '/api-signalr/negotiateUser',
  '/api-signalr/negotiate',
  '/api-signalr',
  '/signalr/negotiate',
  '/signalr/negotiateUser',
  '/api/signalr/negotiate',
  '/api/signalr/negotiateUser',
  '/hubs/signalr/negotiate',
  '/negotiate',
  '/negotiateUser',
  '/api-signalr/v1/negotiate',
  '/api-signalr/v1/negotiateUser',
  '/v1/api-signalr/negotiate',
  '/v1/api-signalr/negotiateUser',
  '/consumerapp/signalr/negotiate',
  '/consumerapp/api-signalr/negotiate',
  // Azure SignalR often uses /client/negotiate
  '/api-signalr/client/negotiate',
  '/signalr/client/negotiate',
  // Function-based negotiate
  '/api/negotiate',
  '/api/negotiateUser',
];

const SIGNALR_QUERY_PATHS = [
  // Azure SignalR negotiate with hub name in query
  '/api-signalr/negotiate?hub=default',
  '/api-signalr/negotiate?hub=szg',
  '/api-signalr/negotiate?hub=SubZero',
  '/api-signalr/negotiate?hub=appliance',
];

console.log('═══════════════════════════════════════════════════════════');
console.log('  Phase 1: SignalR negotiate path discovery');
console.log('  Using key:', PRIMARY_KEY.slice(0, 8) + '...');
console.log('═══════════════════════════════════════════════════════════\n');

// Try POST first (standard SignalR negotiate is POST)
for (const path of SIGNALR_PATHS) {
  const r = await probe('POST', path, PRIMARY_KEY);
  const emoji = r.status < 400 ? '✅' : r.status === 404 ? '  ' : '⚠️';
  console.log(`${emoji} POST ${path} => ${r.status} ${r.body.slice(0, 120)}`);
}

// Also try GET for negotiate
console.log('\n--- GET variants ---');
for (const path of ['/api-signalr/negotiateUser', '/api-signalr/negotiate', '/signalr/negotiate', '/negotiate']) {
  const r = await probe('GET', path, PRIMARY_KEY);
  const emoji = r.status < 400 ? '✅' : r.status === 404 ? '  ' : '⚠️';
  console.log(`${emoji} GET  ${path} => ${r.status} ${r.body.slice(0, 120)}`);
}

// Try with query params
console.log('\n--- Query param variants ---');
for (const path of SIGNALR_QUERY_PATHS) {
  const r = await probe('POST', path, PRIMARY_KEY);
  const emoji = r.status < 400 ? '✅' : r.status === 404 ? '  ' : '⚠️';
  console.log(`${emoji} POST ${path} => ${r.status} ${r.body.slice(0, 120)}`);
}

// Try subscription key as query param instead of header
console.log('\n--- Sub key in query param ---');
for (const path of ['/api-signalr/negotiateUser', '/api-signalr/negotiate']) {
  const r = await probe('POST', `${path}?subscription-key=${PRIMARY_KEY}`, PRIMARY_KEY);
  const emoji = r.status < 400 ? '✅' : r.status === 404 ? '  ' : '⚠️';
  console.log(`${emoji} POST ${path}?subscription-key=... => ${r.status} ${r.body.slice(0, 120)}`);
}

// ── Phase 2: Direct Method endpoint discovery ──────────────────────────────

const DIRECTMETHOD_PATHS = [
  '/directmethod/executeAPICmd',
  '/api/directmethod/executeAPICmd',
  '/api-directmethod/executeAPICmd',
  '/api-iot/directmethod/executeAPICmd',
  '/iot/directmethod/executeAPICmd',
  '/api/iot/directmethod',
  '/directmethod',
  '/api-directmethod',
  '/commands/executeAPICmd',
  '/consumerapp/directmethod/executeAPICmd',
  '/consumerapp/commands/executeAPICmd',
  '/v1/directmethod/executeAPICmd',
  '/api/commands/execute',
  '/api/device/command',
  '/api-iot/v1/directmethod/executeAPICmd',
  // IoT Hub Direct Method patterns
  '/api/devices/command',
  '/api/appliance/command',
  '/api/device/setProperty',
];

// Grab first device ID from the device list
console.log('\n═══════════════════════════════════════════════════════════');
console.log('  Fetching device list for direct method testing...');
console.log('═══════════════════════════════════════════════════════════\n');

const devicesRes = await probe('GET', '/consumerapp/user/devices', PRIMARY_KEY);
let firstDeviceId = '';
let allDeviceIds = [];
try {
  const devices = JSON.parse(devicesRes.body);
  const items = Array.isArray(devices) ? devices : (devices.data ?? devices.devices ?? []);
  for (const d of items) {
    const id = d.deviceId ?? d.id ?? '';
    const name = d.name ?? d.applianceName ?? '';
    console.log(`  Device: ${name} => id: ${String(id).slice(0, 40)}...`);
    allDeviceIds.push(String(id));
  }
  firstDeviceId = allDeviceIds[0] ?? '';
} catch {
  console.log('  Could not parse device list:', devicesRes.body.slice(0, 200));
}

// Dummy command body
const cmdBody = firstDeviceId ? {
  deviceId: firstDeviceId,
  commandName: 'getProperty',
  commandPayload: { propertyName: 'unit_on' },
} : { test: true };

console.log('\n═══════════════════════════════════════════════════════════');
console.log('  Phase 2: Direct Method path discovery');
console.log('  Using device:', firstDeviceId.slice(0, 40) + '...');
console.log('═══════════════════════════════════════════════════════════\n');

for (const path of DIRECTMETHOD_PATHS) {
  const r = await probe('POST', path, PRIMARY_KEY, {}, cmdBody);
  const emoji = r.status < 400 ? '✅' : r.status === 404 ? '  ' : '⚠️';
  console.log(`${emoji} POST ${path} => ${r.status} ${r.body.slice(0, 120)}`);
}

// ── Phase 3: Try every key on the most promising paths ─────────────────────

const pathsToKeyTest = [
  { method: 'POST', path: '/api-signalr/negotiateUser' },
  { method: 'POST', path: '/api-signalr/negotiate' },
  { method: 'POST', path: '/directmethod/executeAPICmd', body: cmdBody },
];

console.log('\n═══════════════════════════════════════════════════════════');
console.log('  Phase 3: Try ALL keys on primary paths');
console.log('═══════════════════════════════════════════════════════════\n');

for (const { method, path, body } of pathsToKeyTest) {
  console.log(`--- ${method} ${path} ---`);
  for (const key of ALL_SUB_KEYS) {
    const r = await probe(method, path, key, {}, body);
    const emoji = r.status < 400 ? '✅' : r.status === 404 ? '  ' : '⚠️';
    console.log(`  ${emoji} key ${key.slice(0, 8)}... => ${r.status} ${r.body.slice(0, 100)}`);
  }
}

// ── Phase 4: Discovery via OPTIONS / HEAD ──────────────────────────────────

console.log('\n═══════════════════════════════════════════════════════════');
console.log('  Phase 4: OPTIONS / HEAD discovery on base paths');
console.log('═══════════════════════════════════════════════════════════\n');

const basePaths = ['/api-signalr', '/directmethod', '/api-directmethod', '/api-iot', '/signalr', '/api'];
for (const bp of basePaths) {
  for (const m of ['OPTIONS', 'HEAD', 'GET']) {
    const r = await probe(m, bp, PRIMARY_KEY);
    if (r.status !== 404) {
      console.log(`⚠️ ${m.padEnd(7)} ${bp} => ${r.status} ${r.body.slice(0, 120)}`);
    }
  }
}

// ── Phase 5: Try alternate base URLs ───────────────────────────────────────

console.log('\n═══════════════════════════════════════════════════════════');
console.log('  Phase 5: Alternate base URLs');
console.log('═══════════════════════════════════════════════════════════\n');

const ALT_BASES = [
  'https://api.subzero-wolf.com',
  'https://iot.subzero.com',
  'https://api.subzero.com',
  'https://prod.api.subzero.com',
  'https://consumerapp.subzero.com',
  'https://prod-iot-subzero.azure-api.net',
];

for (const base of ALT_BASES) {
  const headers = {
    'Authorization': `Bearer ${TOKEN}`,
    'Ocp-Apim-Subscription-Key': PRIMARY_KEY,
    'Accept': 'application/json',
  };
  if (USER_ID) headers['userId'] = USER_ID;
  try {
    const res = await fetch(`${base}/consumerapp/user/devices`, { headers, signal: AbortSignal.timeout(5000) });
    const text = await res.text().catch(() => '');
    console.log(`  ${base} => ${res.status} ${text.slice(0, 100)}`);
  } catch (err) {
    console.log(`  ${base} => ERR: ${err.message?.slice(0, 80)}`);
  }
}

// ── Phase 6: Raw device JSON dump ──────────────────────────────────────────

console.log('\n═══════════════════════════════════════════════════════════');
console.log('  Phase 6: Full device JSON (first device)');
console.log('═══════════════════════════════════════════════════════════\n');

try {
  const fullRes = await probe('GET', '/consumerapp/user/devices', PRIMARY_KEY);
  const parsed = JSON.parse(fullRes.body);
  const items = Array.isArray(parsed) ? parsed : (parsed.data ?? parsed.devices ?? []);
  if (items.length > 0) {
    // Print full first device
    console.log(JSON.stringify(items[0], null, 2).slice(0, 2000));
    console.log(`\n... total devices: ${items.length}`);
    // Print keys of all devices
    for (let i = 0; i < items.length; i++) {
      console.log(`  Device[${i}] keys: ${Object.keys(items[i]).sort().join(', ')}`);
    }
  }
} catch (err) {
  console.log('  Failed:', err.message);
}

console.log('\n✅ Probe complete.');
