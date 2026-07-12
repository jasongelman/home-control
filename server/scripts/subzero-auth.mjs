#!/usr/bin/env node
/**
 * Sub-Zero / Wolf headless B2C auth (Authorization Code + PKCE).
 *
 * The B2C sign-in UI is a remote-hosted template injected via JS, so a headless
 * browser renders blank. Instead we script the B2C "SelfAsserted" flow directly:
 *   1. GET /authorize  -> cookies + SETTINGS (transId, csrf)
 *   2. POST /SelfAsserted (signInName + password, X-CSRF-TOKEN)
 *   3. GET  /api/CombinedSigninAndSignup/confirmed -> 302 to redirect_uri?code=
 *   4. POST /token (code + code_verifier) -> access token
 *
 * Credentials come ONLY from the environment (gitignored server/.subzero.local.env):
 *   set -a; . server/.subzero.local.env; set +a
 *   node server/scripts/subzero-auth.mjs
 *
 * Writes server/data/subzero-token.json (gitignored). Short-lived per-user token;
 * never commit it.
 */

import crypto from 'node:crypto';
import { writeFileSync, readFileSync } from 'node:fs';

// Read creds directly from the gitignored env file (verbatim — NOT via shell
// sourcing, which would expand $, backticks, quotes in the password).
function loadEnvFile(path) {
  try {
    for (const raw of readFileSync(path, 'utf8').split('\n')) {
      const line = raw.replace(/\r$/, '');
      if (!line || line.startsWith('#')) continue;
      const i = line.indexOf('=');
      if (i < 0) continue;
      const key = line.slice(0, i).trim();
      if (!process.env[key]) process.env[key] = line.slice(i + 1); // value verbatim
    }
  } catch { /* file optional if env already set */ }
}
loadEnvFile('server/.subzero.local.env');

const AUTHORITY = 'https://login.subzero-wolf.com/SubZeroB2CPrd.onmicrosoft.com/B2C_1A_SIGNUP_SIGNIN';
const POLICY = 'B2C_1A_SIGNUP_SIGNIN';
const CLIENT_ID = '6eefabd0-49a3-4b92-b329-81b9f638e940';
const REDIRECT_URI = 'com.szg.szgdigitalproductexperience://oauth/redirect';
const SCOPE = `${CLIENT_ID} openid offline_access`;
const UA = 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126 Mobile';

const USER = process.env.SZ_USER, PASS = process.env.SZ_PASS;
if (!USER || !PASS) { console.error('Set SZ_USER and SZ_PASS in the environment.'); process.exit(1); }

const b64url = (b) => b.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const verifier = b64url(crypto.randomBytes(32));
const challenge = b64url(crypto.createHash('sha256').update(verifier).digest());

// Minimal cookie jar.
const jar = new Map();
const storeCookies = (res) => (res.headers.getSetCookie?.() ?? []).forEach((c) => {
  const [nv] = c.split(';'); const i = nv.indexOf('='); jar.set(nv.slice(0, i), nv.slice(i + 1));
});
const cookieHeader = () => [...jar].map(([k, v]) => `${k}=${v}`).join('; ');

async function run() {
  // 1) authorize -> SETTINGS + cookies
  const authorizeUrl = `${AUTHORITY}/oauth2/v2.0/authorize?` + new URLSearchParams({
    client_id: CLIENT_ID, response_type: 'code', redirect_uri: REDIRECT_URI, response_mode: 'query',
    scope: SCOPE, state: 'st', nonce: 'nc', code_challenge: challenge, code_challenge_method: 'S256',
  });
  const a = await fetch(authorizeUrl, { headers: { 'User-Agent': UA } });
  storeCookies(a);
  const html = await a.text();
  const sm = html.match(/var SETTINGS\s*=\s*(\{.*?\});/s);
  if (!sm) { console.error('SETTINGS not found on authorize page'); process.exit(1); }
  const S = JSON.parse(sm[1]);
  const { transId, csrf } = S;

  // 2) SelfAsserted (submit credentials)
  const sa = await fetch(`${AUTHORITY}/SelfAsserted?${new URLSearchParams({ tx: transId, p: POLICY })}`, {
    method: 'POST',
    headers: {
      'User-Agent': UA, 'X-CSRF-TOKEN': csrf, 'X-Requested-With': 'XMLHttpRequest',
      'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8', Cookie: cookieHeader(),
    },
    body: new URLSearchParams({ request_type: 'RESPONSE', signInName: USER, password: PASS }),
  });
  storeCookies(sa);
  const saText = await sa.text();
  let saJson; try { saJson = JSON.parse(saText); } catch { saJson = {}; }
  if (saJson.status !== '200') {
    console.error('SelfAsserted rejected:', sa.status, saText.slice(0, 300));
    console.error('(wrong credentials, or account requires MFA/extra step)');
    process.exit(1);
  }

  // 3) confirmed -> 302 to redirect_uri?code=
  const confirmedUrl = `${AUTHORITY}/api/CombinedSigninAndSignup/confirmed?` + new URLSearchParams({
    rememberMe: 'false', csrf_token: csrf, tx: transId, p: POLICY,
  });
  const c = await fetch(confirmedUrl, { method: 'GET', redirect: 'manual', headers: { 'User-Agent': UA, Cookie: cookieHeader() } });
  const loc = c.headers.get('location') ?? '';
  if (!loc.startsWith('com.szg')) {
    console.error('confirmed did not redirect to app scheme (status', c.status, ') — likely MFA/extra orchestration step.');
    console.error('location:', loc.slice(0, 200) || '(none)');
    console.error('body:', (await c.text()).slice(0, 300));
    process.exit(1);
  }
  const code = new URL(loc).searchParams.get('code');
  if (!code) { console.error('no code in redirect:', loc.slice(0, 200)); process.exit(1); }
  console.log('got authorization code');

  // 4) token exchange
  const tr = await fetch(`${AUTHORITY}/oauth2/v2.0/token`, {
    method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'authorization_code', client_id: CLIENT_ID, code,
      redirect_uri: REDIRECT_URI, code_verifier: verifier, scope: SCOPE,
    }),
  });
  const tok = await tr.json();
  if (!tr.ok) { console.error('token exchange failed', tr.status, JSON.stringify(tok).slice(0, 300)); process.exit(1); }
  const claims = JSON.parse(Buffer.from(tok.access_token.split('.')[1], 'base64url').toString());
  const userId = claims.extension_sitecoreUserId ?? claims.oid ?? claims.sub;
  writeFileSync('server/data/subzero-token.json', JSON.stringify({ ...tok, userId }, null, 2));
  console.log('access token written to server/data/subzero-token.json (gitignored)');
  console.log('userId:', userId, ' expires_in:', tok.expires_in);
}

run();
