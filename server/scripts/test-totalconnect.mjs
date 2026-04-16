#!/usr/bin/env node
// One-shot proof-out for Resideo / Total Connect 2.0.
//
// Usage:
//   TC_USERNAME='you@example.com' TC_PASSWORD='...' node server/scripts/test-totalconnect.mjs
//
// Exits 0 on full end-to-end success. Prints every step so you can see where
// it fails. Does not write anything to disk; credentials are read from env
// vars only (so they don't land in shell history if you use a leading space).

import { publicEncrypt, constants } from 'node:crypto';

const APP_CONFIG_URL = 'https://totalconnect2.com/application.config.json';
const TOKEN_URL      = 'https://rs.alarmnet.com/TC2API.Auth/token';
const API_BASE       = 'https://rs.alarmnet.com/TC2API.TCResource/';

const username = process.env.TC_USERNAME;
const password = process.env.TC_PASSWORD;

if (!username || !password) {
  console.error('Set TC_USERNAME and TC_PASSWORD env vars.');
  process.exit(2);
}

const log = (step, msg) => console.log(`[${step}] ${msg}`);
const fail = (step, err) => { console.error(`[${step}] FAIL:`, err?.message ?? err); process.exit(1); };

// Step 1: fetch app config
log('1/5', `GET ${APP_CONFIG_URL}`);
const cfgRes = await fetch(APP_CONFIG_URL);
if (!cfgRes.ok) fail('1/5', `HTTP ${cfgRes.status}`);
const cfg = await cfgRes.json();

const appConfig  = cfg.AppConfig?.[0];
const brandEntry = cfg.brandInfo?.find(b => b.BrandName === 'totalconnect') ?? cfg.brandInfo?.[0];
const rsaKeyB64  = appConfig?.tc2APIKey;
const clientId   = appConfig?.tc2ClientId;
const appId      = brandEntry?.AppID != null ? String(brandEntry.AppID) : '';
const appVersion = cfg.version ?? cfg.RevisionNumber ?? '5.0.0';

if (!rsaKeyB64 || !clientId) fail('1/5', 'missing tc2APIKey / tc2ClientId');
log('1/5', `OK — appId=${appId} appVersion=${appVersion} clientId=${clientId.slice(0,8)}… rsaKey=${rsaKeyB64.length} chars`);

// Step 2: RSA-PKCS1v15 encrypt
log('2/5', 'RSA-encrypting credentials');
const pem = `-----BEGIN PUBLIC KEY-----\n${rsaKeyB64.match(/.{1,64}/g).join('\n')}\n-----END PUBLIC KEY-----`;
let encUser, encPass;
try {
  encUser = publicEncrypt({ key: pem, padding: constants.RSA_PKCS1_PADDING }, Buffer.from(username, 'utf8')).toString('base64');
  encPass = publicEncrypt({ key: pem, padding: constants.RSA_PKCS1_PADDING }, Buffer.from(password, 'utf8')).toString('base64');
} catch (e) { fail('2/5', e); }
log('2/5', `OK — user=${encUser.length}b64chars pass=${encPass.length}b64chars`);

// Step 3: OAuth2 password grant
log('3/5', `POST ${TOKEN_URL}`);
const tokenRes = await fetch(TOKEN_URL, {
  method: 'POST',
  headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
  body: new URLSearchParams({
    grant_type: 'password',
    client_id:  clientId,
    username:   encUser,
    password:   encPass,
  }).toString(),
});
const tokenBody = await tokenRes.text();
if (!tokenRes.ok) fail('3/5', `HTTP ${tokenRes.status} — ${tokenBody}`);
let token;
try { token = JSON.parse(tokenBody).access_token; } catch { fail('3/5', `non-JSON: ${tokenBody}`); }
if (!token) fail('3/5', `no access_token in response: ${tokenBody}`);
log('3/5', `OK — token acquired (${token.length} chars)`);

// Step 4: session details
const sessUrl = `${API_BASE}api/v3/authentication/sessiondetails?appId=${encodeURIComponent(appId)}&appVersion=${encodeURIComponent(appVersion)}`;
log('4/5', `GET ${sessUrl}`);
const sessRes = await fetch(sessUrl, { headers: { Authorization: `Bearer ${token}` } });
if (!sessRes.ok) fail('4/5', `HTTP ${sessRes.status} — ${await sessRes.text().catch(()=>'') }`);
const sess = await sessRes.json();
const rawLocations = sess?.SessionDetailsResult?.Locations ?? [];
if (rawLocations.length === 0) fail('4/5', 'no locations at all in response');

// Debug dump: show keys + any device-ish arrays on the first location so we
// can see where the security device id actually lives.
const first = rawLocations[0];
console.log('        [debug] first location keys:', Object.keys(first));
for (const [k, v] of Object.entries(first)) {
  if (Array.isArray(v) && v.length && typeof v[0] === 'object') {
    console.log(`        [debug] ${k}[0] keys:`, Object.keys(v[0]));
    console.log(`        [debug] ${k}[0] value:`, JSON.stringify(v[0]).slice(0, 600));
  }
}

// Try several known shapes: SecurityDevices[] (old), DeviceList[] with
// DeviceClassID==1 (python total-connect-client), or Devices[].
function findSecurityDeviceId(loc) {
  if (loc.SecurityDevices?.[0]?.DeviceID != null) return String(loc.SecurityDevices[0].DeviceID);
  const devList = loc.DeviceList ?? loc.Devices ?? [];
  // DeviceClassID 1 = security panel per python total-connect-client.
  const sec = devList.find(d => d.DeviceClassID === 1 || d.DeviceClassID === '1')
           ?? devList.find(d => (d.DeviceName ?? '').toLowerCase().includes('security'))
           ?? devList[0];
  return sec?.DeviceID != null ? String(sec.DeviceID) : '';
}

const locations = rawLocations.map(l => ({
  locationId:       String(l.LocationID ?? ''),
  securityDeviceId: findSecurityDeviceId(l),
  name:             l.LocationName ?? 'Home',
  partitionIds:     l.PartitionIDs ?? [1],
})).filter(l => l.locationId && l.securityDeviceId);

if (locations.length === 0) fail('4/5', `no locations with a recognizable security device — raw first location: ${JSON.stringify(first).slice(0, 1500)}`);
log('4/5', `OK — ${locations.length} location(s):`);
for (const l of locations) {
  console.log(`        • ${l.name} (locationId=${l.locationId}, deviceId=${l.securityDeviceId}, partitions=[${l.partitionIds.join(',')}])`);
}

// Step 5: panel full status for each location
for (const loc of locations) {
  const url = `${API_BASE}api/v3/locations/${loc.locationId}/partitions/fullStatus`;
  log('5/5', `GET ${url}`);
  const res = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
  if (!res.ok) fail('5/5', `HTTP ${res.status} — ${await res.text().catch(()=>'') }`);
  const data = await res.json();
  const armingState = data?.PanelStatus?.Partitions?.[0]?.ArmingState ?? null;
  const zones       = data?.PanelStatus?.Zones ?? [];
  console.log(`        • ${loc.name}: armingState=${armingState}  zones=${zones.length}`);
  for (const z of zones.slice(0, 10)) {
    const st = z.ZoneStatus ?? 0;
    console.log(`            - [${z.ZoneID}] ${z.ZoneDescription ?? ''}  status=${st} (faulted=${(st&2)!==0} bypassed=${(st&1)!==0} lowBat=${(st&8)!==0})`);
  }
  if (zones.length > 10) console.log(`            … and ${zones.length - 10} more`);
}

console.log('\nSUCCESS — Total Connect 2.0 integration works end-to-end.');
