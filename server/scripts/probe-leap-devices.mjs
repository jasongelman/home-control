#!/usr/bin/env node
// Probe the Lutron LEAP processor to discover device resources.
// Specifically looking for keypad/Alisse device info and LED intensity control.
//
// Usage:
//   cd server && node scripts/probe-leap-devices.mjs
//
// Reads processor IP + certs from server/data/config.json and server/data/certs/.
// Prints all device data it finds so we can see what LEAP exposes.

import tls from 'node:tls';
import net from 'node:net';
import { readFileSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const DATA_DIR = join(__dirname, '..', 'data');
const CONFIG_PATH = join(DATA_DIR, 'config.json');
const CERT_DIR = join(DATA_DIR, 'certs');

// ── Load config ──────────────────────────────────────────────────────────────

if (!existsSync(CONFIG_PATH)) {
  console.error('No config.json found at', CONFIG_PATH);
  process.exit(1);
}
const config = JSON.parse(readFileSync(CONFIG_PATH, 'utf-8'));
const ip = config.processor?.ip;
if (!ip) {
  console.error('No processor IP in config.json');
  process.exit(1);
}

const hasCerts =
  existsSync(join(CERT_DIR, 'client.crt')) &&
  existsSync(join(CERT_DIR, 'client.key'));

const certPem = hasCerts ? readFileSync(join(CERT_DIR, 'client.crt'), 'utf-8') : null;
const keyPem = hasCerts ? readFileSync(join(CERT_DIR, 'client.key'), 'utf-8') : null;
const caPath = join(CERT_DIR, 'ca.crt');
const caPem = existsSync(caPath) ? readFileSync(caPath, 'utf-8') : null;

// ── LEAP transport ───────────────────────────────────────────────────────────

let socket = null;
let buffer = '';
let tagCounter = 0;
const pending = new Map();

function tryPort(port, useTLS) {
  return new Promise((resolve, reject) => {
    console.log(`  Trying ${ip}:${port} (TLS=${useTLS})...`);
    let s;
    if (useTLS) {
      s = tls.connect(port, ip, {
        cert: certPem,
        key: keyPem,
        ca: caPem || undefined,
        rejectUnauthorized: false,
      }, () => resolve(s));
    } else {
      s = net.connect(port, ip, () => resolve(s));
    }
    s.on('error', reject);
  });
}

async function connect() {
  console.log(`Connecting to ${ip}...`);
  try {
    socket = await tryPort(8083, true);
  } catch {
    console.log('  TLS 8083 failed, trying plain 8081...');
    socket = await tryPort(8081, false);
  }

  socket.setEncoding('utf-8');
  socket.on('data', (data) => {
    buffer += data;
    let nl;
    while ((nl = buffer.indexOf('\n')) !== -1) {
      const line = buffer.slice(0, nl).trim();
      buffer = buffer.slice(nl + 1);
      if (!line) continue;
      try {
        const msg = JSON.parse(line);
        const tag = msg.Header?.ClientTag;
        if (tag && pending.has(tag)) {
          pending.get(tag).resolve(msg);
          pending.delete(tag);
        }
      } catch {}
    }
  });
}

function send(msg) {
  return new Promise((resolve, reject) => {
    const tag = `probe_${++tagCounter}`;
    msg.Header = msg.Header || {};
    msg.Header.ClientTag = tag;
    const timer = setTimeout(() => {
      pending.delete(tag);
      reject(new Error(`Timeout waiting for ${msg.Header.Url}`));
    }, 10000);
    pending.set(tag, { resolve, reject, timer });
    socket.write(JSON.stringify(msg) + '\n');
  });
}

// ── Main ─────────────────────────────────────────────────────────────────────

try {
  await connect();
  console.log('Connected!\n');

  // Always login on plain TCP; cert auth only works over TLS
  const loginResp = await send({
    CommuniqueType: 'CreateRequest',
    Header: { Url: '/login' },
    Body: {
      Login: {
        ContextType: 'Application',
        LoginId: config.processor?.username || 'lutron',
        Password: config.processor?.password || 'integration',
      },
    },
  });
  console.log('Login:', loginResp.Header?.StatusCode);

  // 1. Query /device
  console.log('\n═══ /device ═══');
  try {
    const resp = await send({
      CommuniqueType: 'ReadRequest',
      Header: { Url: '/device' },
    });
    const devices = resp.Body?.Devices || [];
    console.log(`Found ${devices.length} devices`);
    for (const d of devices) {
      const id = d.href?.match(/\/device\/(\d+)/)?.[1] || '?';
      const type = d.DeviceType || d.ModelNumber || '(unknown type)';
      console.log(`  [${id}] ${d.Name || '(unnamed)'} — type=${type}, model=${d.ModelNumber || '?'}`);

      // If it looks like a keypad, dig deeper
      const name = (d.Name || '').toLowerCase();
      const model = (d.ModelNumber || '').toLowerCase();
      if (name.includes('keypad') || name.includes('alisse') ||
          model.includes('keypad') || model.includes('alisse') ||
          d.DeviceType === 'Keypad' || d.DeviceType === 'Sunnata Keypad') {
        console.log(`    *** Keypad detected — full payload:`);
        console.log(JSON.stringify(d, null, 4));

        // Query this specific device
        try {
          const detail = await send({
            CommuniqueType: 'ReadRequest',
            Header: { Url: `/device/${id}` },
          });
          console.log(`    /device/${id} detail:`);
          console.log(JSON.stringify(detail.Body, null, 4));
        } catch (e) {
          console.log(`    /device/${id} query failed: ${e.message}`);
        }
      }
    }
  } catch (e) {
    console.log(`/device query failed: ${e.message}`);
  }

  // 2. Query /buttongroup (if it exists)
  console.log('\n═══ /buttongroup ═══');
  try {
    const resp = await send({
      CommuniqueType: 'ReadRequest',
      Header: { Url: '/buttongroup' },
    });
    const groups = resp.Body?.ButtonGroups || [];
    console.log(`Found ${groups.length} button groups`);
    for (const g of groups) {
      const id = g.href?.match(/\/buttongroup\/(\d+)/)?.[1] || '?';
      console.log(`  [${id}] StopIfMoving=${g.StopIfMoving}, SortOrder=${g.SortOrder}`);
      console.log(JSON.stringify(g, null, 4));
    }
  } catch (e) {
    console.log(`/buttongroup query failed: ${e.message}`);
  }

  // 3. Query /button (physical buttons, not virtual)
  console.log('\n═══ /button ═══');
  try {
    const resp = await send({
      CommuniqueType: 'ReadRequest',
      Header: { Url: '/button' },
    });
    const buttons = resp.Body?.Buttons || [];
    console.log(`Found ${buttons.length} buttons`);
    // Show first 20 to get a sense
    for (const b of buttons.slice(0, 20)) {
      const id = b.href?.match(/\/button\/(\d+)/)?.[1] || '?';
      console.log(`  [${id}] ${b.Name || '(unnamed)'} — Engraving="${b.Engraving || ''}" ProgrammingType=${b.ProgrammingType || '?'}`);
      if (b.AssociatedLED) {
        console.log(`    *** Has AssociatedLED: ${JSON.stringify(b.AssociatedLED)}`);
      }
    }
    if (buttons.length > 20) {
      console.log(`  ... and ${buttons.length - 20} more`);
    }
  } catch (e) {
    console.log(`/button query failed: ${e.message}`);
  }

  // 4. Look for /led endpoint
  console.log('\n═══ /led ═══');
  try {
    const resp = await send({
      CommuniqueType: 'ReadRequest',
      Header: { Url: '/led' },
    });
    console.log('LED response:');
    console.log(JSON.stringify(resp.Body, null, 4));
  } catch (e) {
    console.log(`/led query failed: ${e.message}`);
  }

  console.log('\n═══ Done ═══');
  socket.end();
  process.exit(0);

} catch (e) {
  console.error('Fatal:', e.message);
  process.exit(1);
}
