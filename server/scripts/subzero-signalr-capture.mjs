#!/usr/bin/env node
/**
 * Connect to the Sub-Zero "connectedappliances" Azure SignalR hub and capture
 * every real-time message, to learn the live property schema + command surface.
 *
 * READ-ONLY: it only listens (and optionally invokes read-style hub methods to
 * trigger a property snapshot). It never sends a setProperty / command.
 *
 * Uses Node's built-in WebSocket + the SignalR JSON protocol (records delimited
 * by 0x1e). No @microsoft/signalr dependency needed.
 *
 *   node server/scripts/subzero-signalr-capture.mjs        # reads server/data/subzero-token.json
 */

import { readFileSync } from 'node:fs';

const API_BASE = 'https://prod.iot.subzero.com';
const SIGNALR_KEY = 'e88bf0b60baf441583f822fa9ba9c895'; // key #5 — the SignalR APIM product
const RS = '\x1e'; // SignalR record separator

const tok = JSON.parse(readFileSync('server/data/subzero-token.json', 'utf8'));
const TOKEN = tok.access_token, USER_ID = String(tok.userId ?? '');

// 1) negotiate for {url, accessToken}
const neg = await fetch(`${API_BASE}/signal-r/negotiateUser`, {
  method: 'POST',
  headers: {
    Authorization: `Bearer ${TOKEN}`, 'Ocp-Apim-Subscription-Key': SIGNALR_KEY,
    'Content-Type': 'application/json', userId: USER_ID,
  },
  body: '{}',
});
if (!neg.ok) { console.error('negotiate failed', neg.status, await neg.text()); process.exit(1); }
const { url, accessToken } = await neg.json();
console.log('negotiated hub url:', url);

// Grab an applianceId to open a channel against (read-only get_async).
const dl = await fetch(`${API_BASE}/consumerapp/user/devices`, {
  headers: { Authorization: `Bearer ${TOKEN}`, 'Ocp-Apim-Subscription-Key': '0e85d3216b604e51a711f147c09e228a', userId: USER_ID },
});
const devs = (await dl.json()).devices ?? [];
const APP = process.env.SZ_APPLIANCE ?? devs[0]?.applianceId;
const HEX = devs[0]?.id;
console.log('target applianceId:', APP);

// 2) open raw WebSocket to the Azure SignalR service
const wsUrl = url.replace(/^http/, 'ws') + `&access_token=${encodeURIComponent(accessToken)}`;
const ws = new WebSocket(wsUrl);
let handshaken = false;
const seen = new Set();

const send = (obj) => ws.send(JSON.stringify(obj) + RS);

ws.addEventListener('open', () => {
  console.log('ws open — sending SignalR handshake');
  ws.send(JSON.stringify({ protocol: 'json', version: 1 }) + RS);
});

ws.addEventListener('message', (ev) => {
  const raw = typeof ev.data === 'string' ? ev.data : Buffer.from(ev.data).toString('utf8');
  for (const part of raw.split(RS)) {
    if (!part) continue;
    let m; try { m = JSON.parse(part); } catch { console.log('◄ non-json:', part.slice(0, 120)); continue; }
    if (!handshaken) {
      handshaken = true;
      console.log(m.error ? `handshake error: ${m.error}` : 'handshake OK');
      // READ-ONLY exploration: open a cloud async channel + request state snapshot
      // (get_async only — never a `set`). Try the likely hub method + arg shapes;
      // completions/errors will tell us which target+shape the hub accepts.
      let n = 0;
      const inv = (target, args) => send({ type: 1, invocationId: `${target}#${n++}`, target, arguments: args });
      const GET = { cmd: 'get_async' };
      for (const id of [APP, HEX].filter(Boolean)) {
        inv('openCloudAsyncChannel', [id]);
        inv('openCloudAsyncChannel', [{ deviceId: id }]);
        inv('openCloudAsyncChannel', [{ applianceId: id }]);
        inv('executeAPICmd', [{ deviceId: id, cmd: 'get_async' }]);
        inv('executeAPICmd', [{ applianceId: id, payload: GET }]);
        inv('executeAPICmd', [id, GET]);
        inv('executeAPICmd', [{ deviceId: id, methodName: 'executeAPICmd', payload: GET }]);
        inv('subscribe', [id]);
        inv('associateAppliance', [id]);
      }
      continue;
    }
    // Log EVERYTHING verbatim so we don't miss the schema.
    switch (m.type) {
      case 1: case 4:
        console.log(`◄ INVOCATION target=${m.target} args=${JSON.stringify(m.arguments).slice(0, 3000)}`);
        break;
      case 3:
        console.log(`◄ COMPLETION id=${m.invocationId} ${m.error ? 'ERR=' + m.error : 'result=' + JSON.stringify(m.result).slice(0, 2500)}`);
        break;
      case 6: send({ type: 6 }); break;
      case 7: console.log('◄ CLOSE', m.error ?? ''); break;
      default: console.log('◄ type', m.type, JSON.stringify(m).slice(0, 400));
    }
  }
});

ws.addEventListener('error', (e) => console.error('ws error:', e.message ?? e));
ws.addEventListener('close', (e) => console.log('ws closed', e.code, e.reason));

// keep the socket alive and quit after a capture window
setTimeout(() => { console.log('\n— capture window elapsed, closing —'); ws.close(); process.exit(0); }, 30000);
