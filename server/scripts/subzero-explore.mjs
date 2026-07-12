#!/usr/bin/env node
/**
 * Sub-Zero / Wolf live API exploration harness.
 *
 * Purpose: with a valid B2C access token, determine the REAL request shape for
 * the SignalR negotiate + per-device state endpoints that were confirmed to
 * exist in the app binary (libapp.so) but return 404 with our previous guesses.
 *
 * This is READ-ONLY. It never sends a device command / setProperty.
 *
 * Provide a token (temporary is fine — B2C tokens live ~1h):
 *   SZ_TOKEN=<bearer access token>  [SZ_USERID=<sitecore user id>]  \
 *     node server/scripts/subzero-explore.mjs
 *
 * The token is read from the environment only. It is never written to disk,
 * logged in full, or committed. Do not paste it into a tracked file.
 */

const API_BASE = 'https://prod.iot.subzero.com';

// Community-reverse-engineered APIM subscription keys (same values already in
// probe-subzero-endpoints.mjs; the vendor's mobile-app product keys, not per-user).
const SUB_KEYS = [
  '0e85d3216b604e51a711f147c09e228a',
  '16ca8ba0ad3f4eddaffcf8520454c2c9',
  '180fd5156a734e69b355970c9615403c',
  '25126214b7b7408283baefaec38010de',
  'a93bb184cbf944c7af266d5fa2680652',
  'e88bf0b60baf441583f822fa9ba9c895',
];

const TOKEN = process.env.SZ_TOKEN;
if (!TOKEN) {
  console.error('Set SZ_TOKEN=<bearer token>. Optionally SZ_USERID=<id>.');
  process.exit(1);
}

// Derive userId from the JWT if not supplied (claim name varies).
function userIdFromJwt(jwt) {
  try {
    const p = JSON.parse(Buffer.from(jwt.split('.')[1], 'base64url').toString());
    return p.extension_sitecoreUserId ?? p.oid ?? p.sub ?? p.uid ?? undefined;
  } catch { return undefined; }
}
const USER_ID = process.env.SZ_USERID ?? userIdFromJwt(TOKEN);
console.log('userId:', USER_ID ?? '(unknown)');

function headers(subKey, extra = {}) {
  const h = {
    Authorization: `Bearer ${TOKEN}`,
    'Ocp-Apim-Subscription-Key': subKey,
    Accept: 'application/json',
    'Content-Type': 'application/json',
    // App UA — some APIM policies gate on it.
    'User-Agent': 'SubZeroGroupOwnersApp/4.6.0 (Flutter; dart:io)',
    ...extra,
  };
  if (USER_ID) h.userId = String(USER_ID);
  return h;
}

async function req(method, path, { subKey = SUB_KEYS[0], body, extra } = {}) {
  const url = `${API_BASE}${path}`;
  const opts = { method, headers: headers(subKey, extra) };
  if (body !== undefined) opts.body = JSON.stringify(body);
  try {
    const res = await fetch(url, opts);
    const text = await res.text();
    return { status: res.status, body: text }; // full body; caller truncates for logging
  } catch (e) {
    return { status: 0, body: `ERR ${e.message}` };
  }
}

const line = (label, r) =>
  console.log(`  ${String(r.status).padEnd(4)} ${label} — ${r.body.replace(/\s+/g, ' ').slice(0, 220)}`);

// Try every subscription key for a method+path; return the first with the best
// status (200 > other non-404/401 > 401 > 404) and log the winner.
async function sweep(method, path, { body } = {}) {
  let best = null, bestKeyIdx = -1;
  const rank = (s) => (s === 200 || s === 201 ? 4 : s === 400 || s === 405 ? 3 : s === 401 ? 2 : s === 404 ? 1 : 0);
  for (let i = 0; i < SUB_KEYS.length; i++) {
    const r = await req(method, path, { subKey: SUB_KEYS[i], body });
    if (!best || rank(r.status) > rank(best.status)) { best = r; bestKeyIdx = i; }
    if (r.status === 200 || r.status === 201) break; // found it
  }
  line(`${method} ${path} [key${bestKeyIdx}=${SUB_KEYS[bestKeyIdx].slice(0, 8)}..]`, best);
  return { ...best, keyIdx: bestKeyIdx };
}

async function main() {
  // 0) Baseline: device list (confirms token + gives us appliance ids)
  console.log('\n═══ device list (baseline) ═══');
  const dl = await req('GET', '/consumerapp/user/devices');
  line('GET /consumerapp/user/devices', dl);
  if (dl.status === 401 || dl.status === 403) {
    console.error('\nToken rejected — get a fresh SZ_TOKEN and retry.');
    process.exit(1);
  }
  let devices = [];
  try {
    const j = JSON.parse(dl.body);
    devices = Array.isArray(j) ? j : (j.devices ?? j.data ?? j.appliances ?? []);
  } catch { /* leave empty */ }
  const first = devices[0] ?? {};
  const applianceId = process.env.SZ_APPLIANCE ?? first.applianceId ?? first.deviceId;
  const hexId = first.id;
  console.log(`parsed ${devices.length} devices; applianceId=${applianceId} hexId=${hexId ? hexId.slice(0, 12) + '…' : '(none)'}`);

  // 1) Per-device detail — does this return live properties/state? Sweep keys.
  console.log('\n═══ per-device detail (state?) ═══');
  for (const id of [applianceId, hexId].filter(Boolean)) {
    await sweep('GET', `/consumerapp/device/${id}`);
  }

  // 2) SignalR negotiate — confirmed path is POST /signal-r/negotiateUser.
  //    Sweep keys to find the SignalR product key; on 200 dump connection info.
  console.log('\n═══ SignalR negotiate (find the key, get connection info) ═══');
  for (const q of ['', '?negotiateVersion=1']) {
    const r = await sweep('POST', `/signal-r/negotiateUser${q}`, { body: {} });
    if (r.status === 200 || r.status === 201) {
      try {
        const info = JSON.parse(r.body);
        console.log('  ► negotiate OK. keys:', Object.keys(info),
          '| url:', info.url ?? info.Url,
          '| hasAccessToken:', !!(info.accessToken ?? info.AccessToken));
      } catch { console.log('  ► negotiate 200 but body not JSON'); }
      break;
    }
  }

  // 3) directmethod — POST-only. Empty body won't execute a command; a 400/401/
  //    405 (not 404) confirms the path + which key. READ-ONLY intent.
  console.log('\n═══ directmethod existence (empty body — no command executed) ═══');
  await sweep('POST', '/directmethod/executeAPICmd', { body: {} });

  console.log('\nDone. 200/201=works · 400/401/405=exists (key/shape issue) · 404=wrong path.');
}

main();
