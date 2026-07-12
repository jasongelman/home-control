#!/usr/bin/env node
/**
 * Passive, receive-only listener on the Sub-Zero "connectedappliances" SignalR
 * hub. Logs every frame verbatim with a timestamp. Sends NOTHING except the
 * protocol handshake + ping/pong. Used to capture the live property-update
 * schema that the upstream pushes when the real Owner's app requests state.
 *
 *   node server/scripts/subzero-signalr-listen.mjs [seconds]
 */

import { readFileSync } from 'node:fs';

const API_BASE = 'https://prod.iot.subzero.com';
const SIGNALR_KEY = 'e88bf0b60baf441583f822fa9ba9c895';
const RS = '\x1e';
const SECONDS = Number(process.argv[2] ?? 180);

const tok = JSON.parse(readFileSync('server/data/subzero-token.json', 'utf8'));
const ts = () => new Date().toISOString().slice(11, 19);

const neg = await fetch(`${API_BASE}/signal-r/negotiateUser`, {
  method: 'POST',
  headers: { Authorization: `Bearer ${tok.access_token}`, 'Ocp-Apim-Subscription-Key': SIGNALR_KEY, 'Content-Type': 'application/json', userId: String(tok.userId ?? '') },
  body: '{}',
});
if (!neg.ok) { console.error('negotiate failed', neg.status, await neg.text()); process.exit(1); }
const { url, accessToken } = await neg.json();

const ws = new WebSocket(url.replace(/^http/, 'ws') + `&access_token=${encodeURIComponent(accessToken)}`);
let handshaken = false, frames = 0;

ws.addEventListener('open', () => { console.log(`${ts()} ws open`); ws.send(JSON.stringify({ protocol: 'json', version: 1 }) + RS); });
ws.addEventListener('message', (ev) => {
  const raw = typeof ev.data === 'string' ? ev.data : Buffer.from(ev.data).toString('utf8');
  for (const part of raw.split(RS)) {
    if (!part) continue;
    let m; try { m = JSON.parse(part); } catch { console.log(`${ts()} raw:`, part.slice(0, 200)); continue; }
    if (!handshaken) { handshaken = true; console.log(`${ts()} handshake ${m.error ? 'ERR ' + m.error : 'OK — listening, open the app now'}`); continue; }
    if (m.type === 6) { ws.send(JSON.stringify({ type: 6 }) + RS); continue; } // pong
    frames++;
    console.log(`${ts()} ◄ type=${m.type}${m.target ? ' target=' + m.target : ''} ${JSON.stringify(m.arguments ?? m.result ?? m).slice(0, 4000)}`);
  }
});
ws.addEventListener('error', (e) => console.error(`${ts()} ws error`, e.message ?? e));
ws.addEventListener('close', (e) => console.log(`${ts()} ws closed ${e.code}`));

setTimeout(() => { console.log(`\n${ts()} — done, ${frames} data frame(s) captured —`); ws.close(); process.exit(0); }, SECONDS * 1000);
