# SmartHQ OAuth Authorization Code Migration

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the broken `password` grant in the server-side SmartHQ integration with the headless OAuth2 authorization_code flow used by the gehome SDK.

**Architecture:** The server simulates the browser-based OAuth flow: GET the login form, POST credentials to `g_authenticate`, handle intermediate pages (MFA skip, terms), capture the auth code from the redirect, exchange it for tokens. No changes to the web UI or iOS app — the `/api/smarthq/login` endpoint still accepts email/password; only the server-side mechanism changes.

**Tech Stack:** Node.js/TypeScript, native `fetch`, regex-based HTML form parsing (no external HTML parser needed — the forms are small and predictable).

---

## File Structure

| Action | File | Responsibility |
|--------|------|----------------|
| Create | `server/src/smarthq/SmartHQAuth.ts` | Headless OAuth flow: form scraping, credential submission, MFA/terms handling, code exchange, token refresh |
| Modify | `server/src/smarthq/SmartHQManager.ts` | Replace `login()` and `refresh()` to delegate to `SmartHQAuth`; update constants to match gehome SDK |
| Modify | `server/src/smarthq/types.ts` | No changes needed — `SmartHQConfig` already has the right shape |
| Modify | `server/scripts/test-smarthq.mjs` | Rewrite auth steps to use the headless OAuth flow instead of password grant |

---

### Task 1: Create SmartHQAuth — headless OAuth flow

**Files:**
- Create: `server/src/smarthq/SmartHQAuth.ts`

This is the core of the migration. It implements the gehome SDK's auth flow in TypeScript using native `fetch`.

- [ ] **Step 1: Create `SmartHQAuth.ts` with constants and types**

```typescript
// server/src/smarthq/SmartHQAuth.ts

const LOGIN_BASE = 'https://accounts.brillion.geappliances.com';
const TOKEN_URL = `${LOGIN_BASE}/oauth2/token`;

// Community-reverse-engineered from the GE SmartHQ mobile app; same values as gehome SDK.
const CLIENT_ID = '564c31616c4f7474434b307435412b4d2f6e7672';
const CLIENT_SECRET = '6476512b5246446d452f697154444941387052645938466e5671746e5847593d';
const REDIRECT_URI = 'brillion.4e617a766474657344444e562b5935566e51324a://oauth/redirect';

export interface SmartHQTokens {
  accessToken: string;
  refreshToken: string;
  expiresIn: number;
}
```

- [ ] **Step 2: Implement cookie jar helper**

The flow requires session cookies (JSESSIONID, region cookie) to persist across requests. Node's native `fetch` doesn't handle cookies automatically, so we need a minimal cookie jar.

```typescript
/** Minimal cookie jar — stores Set-Cookie values and replays them. */
class CookieJar {
  private cookies = new Map<string, string>();

  capture(headers: Headers): void {
    const raw = headers.getSetCookie?.() ?? [];
    for (const h of raw) {
      const [pair] = h.split(';');
      const eq = pair.indexOf('=');
      if (eq > 0) this.cookies.set(pair.slice(0, eq).trim(), pair.slice(eq + 1).trim());
    }
  }

  header(): string {
    return [...this.cookies.entries()].map(([k, v]) => `${k}=${v}`).join('; ');
  }
}
```

Note: `Headers.getSetCookie()` is available in Node 18.14+ (this project uses Node 18+). If the runtime doesn't support it, fall back to `headers.raw?.()['set-cookie']` — but the modern API should work.

- [ ] **Step 3: Implement `getAuthorizationCode` — the multi-step headless login**

```typescript
/**
 * Performs the headless OAuth login flow:
 * 1. GET /oauth2/auth to get the login form + session cookies
 * 2. POST /oauth2/g_authenticate with credentials
 * 3. Handle intermediate pages (MFA enrollment skip, terms acceptance)
 * 4. Return the authorization code from the final redirect
 */
async function getAuthorizationCode(email: string, password: string): Promise<string> {
  const jar = new CookieJar();

  // Set region cookie (US)
  jar.cookies.set('abgea_region', 'us-east-1');

  // Step 1: GET the login form
  const authParams = new URLSearchParams({
    client_id: CLIENT_ID,
    response_type: 'code',
    access_type: 'offline',
    redirect_uri: REDIRECT_URI,
  });
  const authRes = await fetch(`${LOGIN_BASE}/oauth2/auth?${authParams}`, {
    headers: { Cookie: jar.header() },
    redirect: 'manual',
  });
  jar.capture(authRes.headers);
  const authHtml = await authRes.text();

  // Extract hidden form fields from the login form
  const hiddenFields = extractHiddenFields(authHtml);

  // Step 2: POST credentials to g_authenticate
  const formData = new URLSearchParams({
    ...hiddenFields,
    username: email,
    password: password,
  });
  const loginRes = await fetch(`${LOGIN_BASE}/oauth2/g_authenticate`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      Cookie: jar.header(),
    },
    body: formData.toString(),
    redirect: 'manual',
  });
  jar.capture(loginRes.headers);

  // If redirect → extract code from Location header
  if (loginRes.status >= 300 && loginRes.status < 400) {
    return extractCodeFromRedirect(loginRes.headers.get('location')!);
  }

  // If 200 → handle intermediate page (MFA, terms, or app authorization)
  if (loginRes.status === 200) {
    const html = await loginRes.text();
    return handleIntermediatePage(html, jar);
  }

  throw new Error(`SmartHQ login failed: HTTP ${loginRes.status}`);
}
```

- [ ] **Step 4: Implement HTML parsing helpers**

```typescript
/** Extract hidden <input> fields from an HTML form. */
function extractHiddenFields(html: string): Record<string, string> {
  const fields: Record<string, string> = {};
  const regex = /<input[^>]+type=["']hidden["'][^>]*>/gi;
  let match: RegExpExecArray | null;
  while ((match = regex.exec(html)) !== null) {
    const tag = match[0];
    const name = tag.match(/name=["']([^"']+)["']/)?.[1];
    const value = tag.match(/value=["']([^"']*?)["']/)?.[1] ?? '';
    if (name) fields[name] = value;
  }
  return fields;
}

/** Extract the `code` query param from a redirect URL. */
function extractCodeFromRedirect(location: string): string {
  const url = new URL(location);
  const code = url.searchParams.get('code');
  if (!code) throw new Error(`No authorization code in redirect: ${location}`);
  return code;
}
```

- [ ] **Step 5: Implement intermediate page handlers (MFA skip, terms acceptance)**

```typescript
/** Handle intermediate pages that appear between login and the final redirect. */
async function handleIntermediatePage(html: string, jar: CookieJar): Promise<string> {
  // MFA enrollment skip
  if (html.includes('Add Multi-Factor Authentication') || html.includes('addMfaForm')) {
    const csrf = html.match(/name=["']_csrf["'][^>]*value=["']([^"']+)["']/)?.[1]
              ?? html.match(/value=["']([^"']+)["'][^>]*name=["']_csrf["']/)?.[1]
              ?? '';
    const skipRes = await fetch(`${LOGIN_BASE}/account/active/redirect`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        Cookie: jar.header(),
      },
      body: new URLSearchParams({ _csrf: csrf }).toString(),
      redirect: 'manual',
    });
    jar.capture(skipRes.headers);

    if (skipRes.status >= 300 && skipRes.status < 400) {
      // Follow the redirect chain to get the code
      return followRedirects(skipRes.headers.get('location')!, jar);
    }
    const nextHtml = await skipRes.text();
    return handleIntermediatePage(nextHtml, jar);
  }

  // Terms acceptance
  if (html.includes('Almost Finished') && html.includes('/oauth2/terms/accept')) {
    const csrf = html.match(/name=["']_csrf["'][^>]*value=["']([^"']+)["']/)?.[1]
              ?? html.match(/value=["']([^"']+)["'][^>]*name=["']_csrf["']/)?.[1]
              ?? '';
    const signature = html.match(/name=["']signature["'][^>]*value=["']([^"']+)["']/)?.[1] ?? '';
    const loginSig = html.match(/name=["']login_actions_signature["'][^>]*value=["']([^"']+)["']/)?.[1] ?? '';
    const isDev = html.match(/name=["']isDeveloper["'][^>]*value=["']([^"']+)["']/)?.[1] ?? '';

    const termsRes = await fetch(`${LOGIN_BASE}/oauth2/terms/accept`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'X-CSRF-TOKEN': csrf,
        Cookie: jar.header(),
      },
      body: new URLSearchParams({
        signature,
        login_actions_signature: loginSig,
        isDeveloper: isDev,
        developerTerms: 'on',
        connected_terms: 'on',
        _csrf: csrf,
      }).toString(),
      redirect: 'manual',
    });
    jar.capture(termsRes.headers);

    if (termsRes.status >= 300 && termsRes.status < 400) {
      return followRedirects(termsRes.headers.get('location')!, jar);
    }
    const nextHtml = await termsRes.text();
    return handleIntermediatePage(nextHtml, jar);
  }

  // App authorization page
  if (html.includes('authorized')) {
    const hiddenFields = extractHiddenFields(html);
    const codeRes = await fetch(`${LOGIN_BASE}/oauth2/code`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        Cookie: jar.header(),
      },
      body: new URLSearchParams({ ...hiddenFields, authorized: 'yes' }).toString(),
      redirect: 'manual',
    });
    if (codeRes.status >= 300 && codeRes.status < 400) {
      return extractCodeFromRedirect(codeRes.headers.get('location')!);
    }
  }

  // Check for error messages in the HTML
  const errorMatch = html.match(/id=["']alert_pane["'][^>]*>([\s\S]*?)<\//);
  const errorMsg = errorMatch?.[1]?.replace(/<[^>]*>/g, '').trim();
  throw new Error(`SmartHQ authentication failed: ${errorMsg || 'unknown error (check email/password)'}`);
}

/** Follow a redirect chain, returning the authorization code when we hit the redirect_uri. */
async function followRedirects(url: string, jar: CookieJar, maxHops = 10): Promise<string> {
  let currentUrl = url;
  for (let i = 0; i < maxHops; i++) {
    // If we've been redirected to the custom scheme, extract the code
    if (currentUrl.startsWith(REDIRECT_URI.split('://')[0])) {
      return extractCodeFromRedirect(currentUrl);
    }
    // If relative URL, resolve against LOGIN_BASE
    const resolved = currentUrl.startsWith('http') ? currentUrl : `${LOGIN_BASE}${currentUrl}`;
    const res = await fetch(resolved, {
      headers: { Cookie: jar.header() },
      redirect: 'manual',
    });
    jar.capture(res.headers);
    if (res.status >= 300 && res.status < 400) {
      currentUrl = res.headers.get('location')!;
      continue;
    }
    // If we got a 200, it might be another intermediate page
    if (res.status === 200) {
      const html = await res.text();
      return handleIntermediatePage(html, jar);
    }
    throw new Error(`Unexpected response during redirect chain: HTTP ${res.status}`);
  }
  throw new Error('Too many redirects during SmartHQ OAuth flow');
}
```

- [ ] **Step 6: Implement token exchange and refresh**

```typescript
/** Exchange an authorization code for access + refresh tokens. */
export async function exchangeCodeForTokens(code: string): Promise<SmartHQTokens> {
  const basicAuth = Buffer.from(`${CLIENT_ID}:${CLIENT_SECRET}`).toString('base64');
  const res = await fetch(TOKEN_URL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      Authorization: `Basic ${basicAuth}`,
    },
    body: new URLSearchParams({
      grant_type: 'authorization_code',
      code,
      client_id: CLIENT_ID,
      client_secret: CLIENT_SECRET,
      redirect_uri: REDIRECT_URI,
    }).toString(),
  });
  if (!res.ok) {
    const body = await res.text().catch(() => '');
    throw new Error(`SmartHQ token exchange failed: HTTP ${res.status} — ${body}`);
  }
  const json = await res.json() as Record<string, unknown>;
  return {
    accessToken: json.access_token as string,
    refreshToken: json.refresh_token as string,
    expiresIn: (json.expires_in as number) ?? 3600,
  };
}

/** Refresh an access token using a refresh token. Returns null if refresh fails. */
export async function refreshAccessToken(refreshToken: string): Promise<SmartHQTokens | null> {
  const basicAuth = Buffer.from(`${CLIENT_ID}:${CLIENT_SECRET}`).toString('base64');
  const res = await fetch(TOKEN_URL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      Authorization: `Basic ${basicAuth}`,
    },
    body: new URLSearchParams({
      grant_type: 'refresh_token',
      refresh_token: refreshToken,
      client_id: CLIENT_ID,
      client_secret: CLIENT_SECRET,
      redirect_uri: REDIRECT_URI,
    }).toString(),
  });
  if (!res.ok) return null;
  const json = await res.json() as Record<string, unknown>;
  return {
    accessToken: json.access_token as string,
    refreshToken: (json.refresh_token as string) ?? refreshToken,
    expiresIn: (json.expires_in as number) ?? 3600,
  };
}

/** Full login flow: get authorization code, then exchange for tokens. */
export async function loginWithCredentials(email: string, password: string): Promise<SmartHQTokens> {
  const code = await getAuthorizationCode(email, password);
  return exchangeCodeForTokens(code);
}
```

- [ ] **Step 7: Verify the file compiles**

Run: `cd server && npx tsc --noEmit src/smarthq/SmartHQAuth.ts`

If there are compile errors (e.g. `getSetCookie` not in the type definitions), fix them. A common fix is to cast `headers` or use `(headers as any).getSetCookie()` — or fall back to raw header access.

- [ ] **Step 8: Commit**

```bash
git add server/src/smarthq/SmartHQAuth.ts
git commit -m "feat(smarthq): add headless OAuth authorization_code flow

Implements the gehome SDK's browser-simulation auth flow in TypeScript:
GET login form → POST credentials → handle MFA/terms → exchange code for tokens.
Replaces the broken password grant which GE has deprecated."
```

---

### Task 2: Update SmartHQManager to use the new auth flow

**Files:**
- Modify: `server/src/smarthq/SmartHQManager.ts`

- [ ] **Step 1: Replace constants and imports**

Replace the top of the file. Remove the old `CLIENT_ID` constant and add the import:

Old (lines 1-7):
```typescript
import { EventEmitter } from 'events';
import type { SmartHQConfig, LaundryAppliance, LaundryMachineState } from './types.js';

const AUTH_URL = 'https://accounts.brillion.geappliances.com/oauth2/token';
const API_BASE = 'https://api.brillion.geappliances.com';
const CLIENT_ID = '564c31616c4f7768536a514b';
const POLL_INTERVAL = 30_000;
```

New:
```typescript
import { EventEmitter } from 'events';
import type { SmartHQConfig, LaundryAppliance, LaundryMachineState } from './types.js';
import { loginWithCredentials, refreshAccessToken } from './SmartHQAuth.js';

const API_BASE = 'https://api.brillion.geappliances.com';
const POLL_INTERVAL = 30_000;
```

- [ ] **Step 2: Replace the `login()` method**

Old (lines 58-79):
```typescript
  async login(): Promise<void> {
    const body = new URLSearchParams({
      grant_type: 'password',
      username: this.config.email,
      password: this.config.password,
      client_id: CLIENT_ID,
    });
    const res = await fetch(AUTH_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: body.toString(),
    });
    if (!res.ok) throw new Error(`SmartHQ login failed: ${res.status}`);
    const json = await res.json() as Record<string, unknown>;
    this.config.accessToken = json.access_token as string;
    this.config.refreshToken = json.refresh_token as string;
    this.config.tokenExpiresAt = Date.now() + ((json.expires_in as number ?? 3600) - 60) * 1000;
    this.config.enabled = true;
    this.emit('configChanged', this.config);
    await this.fetchAppliances();
    this.start();
  }
```

New:
```typescript
  async login(): Promise<void> {
    const tokens = await loginWithCredentials(this.config.email, this.config.password);
    this.config.accessToken = tokens.accessToken;
    this.config.refreshToken = tokens.refreshToken;
    this.config.tokenExpiresAt = Date.now() + (tokens.expiresIn - 60) * 1000;
    this.config.enabled = true;
    this.emit('configChanged', this.config);
    await this.fetchAppliances();
    this.start();
  }
```

- [ ] **Step 3: Replace the `refresh()` method**

Old (lines 89-107):
```typescript
  private async refresh(): Promise<void> {
    if (!this.config.refreshToken) throw new Error('No refresh token');
    const body = new URLSearchParams({
      grant_type: 'refresh_token',
      refresh_token: this.config.refreshToken,
      client_id: CLIENT_ID,
    });
    const res = await fetch(AUTH_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: body.toString(),
    });
    if (!res.ok) { this.config.accessToken = undefined; throw new Error('SmartHQ refresh failed'); }
    const json = await res.json() as Record<string, unknown>;
    this.config.accessToken = json.access_token as string;
    if (json.refresh_token) this.config.refreshToken = json.refresh_token as string;
    this.config.tokenExpiresAt = Date.now() + ((json.expires_in as number ?? 3600) - 60) * 1000;
    this.emit('configChanged', this.config);
  }
```

New:
```typescript
  private async refresh(): Promise<void> {
    if (!this.config.refreshToken) throw new Error('No refresh token');
    const tokens = await refreshAccessToken(this.config.refreshToken);
    if (!tokens) {
      this.config.accessToken = undefined;
      // Try full re-login if we still have credentials
      if (this.config.email && this.config.password) {
        console.log('SmartHQ: refresh failed, attempting full re-login...');
        await this.login();
        return;
      }
      throw new Error('SmartHQ refresh failed and no credentials for re-login');
    }
    this.config.accessToken = tokens.accessToken;
    this.config.refreshToken = tokens.refreshToken;
    this.config.tokenExpiresAt = Date.now() + (tokens.expiresIn - 60) * 1000;
    this.emit('configChanged', this.config);
  }
```

- [ ] **Step 4: Build the server to verify**

Run: `cd server && npm run build`
Expected: clean build, no errors.

- [ ] **Step 5: Commit**

```bash
git add server/src/smarthq/SmartHQManager.ts
git commit -m "refactor(smarthq): use headless OAuth flow instead of password grant

SmartHQManager.login() and refresh() now delegate to SmartHQAuth.
Refresh failure falls back to full re-login when credentials are available."
```

---

### Task 3: Update the test script

**Files:**
- Modify: `server/scripts/test-smarthq.mjs`

- [ ] **Step 1: Rewrite the test script to use the headless OAuth flow**

Replace the entire file:

```javascript
#!/usr/bin/env node
// One-shot proof-out for GE SmartHQ / Brillion API (headless OAuth flow).
//
// Usage:
//   GE_EMAIL='you@example.com' GE_PASSWORD='...' node server/scripts/test-smarthq.mjs
//
// Exits 0 on full end-to-end success. Prints every step so you can see where
// it fails. Does not write anything to disk; credentials are read from env
// vars only (so they don't land in shell history if you use a leading space).

const LOGIN_BASE = 'https://accounts.brillion.geappliances.com';
const TOKEN_URL = `${LOGIN_BASE}/oauth2/token`;
const API_BASE  = 'https://api.brillion.geappliances.com';

// Community-reverse-engineered from the GE SmartHQ mobile app; same values as gehome SDK.
const CLIENT_ID     = '564c31616c4f7474434b307435412b4d2f6e7672';
const CLIENT_SECRET = '6476512b5246446d452f697154444941387052645938466e5671746e5847593d';
const REDIRECT_URI  = 'brillion.4e617a766474657344444e562b5935566e51324a://oauth/redirect';

const email    = process.env.GE_EMAIL;
const password = process.env.GE_PASSWORD;

if (!email || !password) {
  console.error('Set GE_EMAIL and GE_PASSWORD env vars.');
  process.exit(2);
}

const log  = (step, msg) => console.log(`[${step}] ${msg}`);
const fail = (step, err) => { console.error(`[${step}] FAIL:`, err?.message ?? err); process.exit(1); };

// ── Minimal cookie jar ──────────────────────────────────────────────────────
class CookieJar {
  constructor() { this.cookies = new Map(); }
  capture(headers) {
    const raw = headers.getSetCookie?.() ?? [];
    for (const h of raw) {
      const [pair] = h.split(';');
      const eq = pair.indexOf('=');
      if (eq > 0) this.cookies.set(pair.slice(0, eq).trim(), pair.slice(eq + 1).trim());
    }
  }
  header() { return [...this.cookies.entries()].map(([k, v]) => `${k}=${v}`).join('; '); }
}

function extractHiddenFields(html) {
  const fields = {};
  const regex = /<input[^>]+type=["']hidden["'][^>]*>/gi;
  let match;
  while ((match = regex.exec(html)) !== null) {
    const tag = match[0];
    const name = tag.match(/name=["']([^"']+)["']/)?.[1];
    const value = tag.match(/value=["']([^"']*?)["']/)?.[1] ?? '';
    if (name) fields[name] = value;
  }
  return fields;
}

function extractCodeFromRedirect(location) {
  const url = new URL(location);
  const code = url.searchParams.get('code');
  if (!code) throw new Error(`No authorization code in redirect: ${location}`);
  return code;
}

// ── Step 1: Headless OAuth login ────────────────────────────────────────────
log('1/5', 'Starting headless OAuth flow');
const jar = new CookieJar();
jar.cookies.set('abgea_region', 'us-east-1');

// 1a: GET the login form
log('1/5', `GET ${LOGIN_BASE}/oauth2/auth`);
const authParams = new URLSearchParams({
  client_id: CLIENT_ID, response_type: 'code', access_type: 'offline', redirect_uri: REDIRECT_URI,
});
const authRes = await fetch(`${LOGIN_BASE}/oauth2/auth?${authParams}`, {
  headers: { Cookie: jar.header() }, redirect: 'manual',
});
jar.capture(authRes.headers);
if (authRes.status >= 400) fail('1/5', `GET /oauth2/auth returned HTTP ${authRes.status}`);
const authHtml = await authRes.text();
const hiddenFields = extractHiddenFields(authHtml);
log('1/5', `OK — login form loaded (${Object.keys(hiddenFields).length} hidden fields)`);

// 1b: POST credentials
log('2/5', `POST ${LOGIN_BASE}/oauth2/g_authenticate`);
const loginRes = await fetch(`${LOGIN_BASE}/oauth2/g_authenticate`, {
  method: 'POST',
  headers: { 'Content-Type': 'application/x-www-form-urlencoded', Cookie: jar.header() },
  body: new URLSearchParams({ ...hiddenFields, username: email, password }).toString(),
  redirect: 'manual',
});
jar.capture(loginRes.headers);

let authCode;
if (loginRes.status >= 300 && loginRes.status < 400) {
  const loc = loginRes.headers.get('location');
  authCode = extractCodeFromRedirect(loc);
  log('2/5', `OK — got auth code from redirect (${authCode.length} chars)`);
} else if (loginRes.status === 200) {
  const html = await loginRes.text();
  // Check for error
  const errorMatch = html.match(/id=["']alert_pane["'][^>]*>([\s\S]*?)<\//);
  const errorMsg = errorMatch?.[1]?.replace(/<[^>]*>/g, '').trim();
  if (errorMsg) fail('2/5', `Authentication error: ${errorMsg}`);
  // Handle intermediate pages (MFA skip, terms acceptance)
  log('2/5', 'Got 200 — handling intermediate page (MFA/terms)...');
  // Simplified: try following any redirect forms
  if (html.includes('Add Multi-Factor Authentication') || html.includes('addMfaForm')) {
    const csrf = html.match(/name=["']_csrf["'][^>]*value=["']([^"']+)["']/)?.[1] ?? '';
    const skipRes = await fetch(`${LOGIN_BASE}/account/active/redirect`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded', Cookie: jar.header() },
      body: new URLSearchParams({ _csrf: csrf }).toString(),
      redirect: 'manual',
    });
    jar.capture(skipRes.headers);
    if (skipRes.status >= 300 && skipRes.status < 400) {
      // Follow redirect chain
      let loc = skipRes.headers.get('location');
      for (let i = 0; i < 10 && loc; i++) {
        if (loc.startsWith('brillion.')) { authCode = extractCodeFromRedirect(loc); break; }
        const resolved = loc.startsWith('http') ? loc : `${LOGIN_BASE}${loc}`;
        const r = await fetch(resolved, { headers: { Cookie: jar.header() }, redirect: 'manual' });
        jar.capture(r.headers);
        loc = r.status >= 300 ? r.headers.get('location') : null;
      }
    }
  }
  if (!authCode) fail('2/5', 'Could not extract auth code from intermediate page');
  log('2/5', `OK — got auth code after intermediate page (${authCode.length} chars)`);
} else {
  fail('2/5', `Unexpected HTTP ${loginRes.status}`);
}

// ── Step 2: Exchange code for tokens ────────────────────────────────────────
log('3/5', `POST ${TOKEN_URL} (authorization_code grant)`);
const basicAuth = btoa(`${CLIENT_ID}:${CLIENT_SECRET}`);
const tokenRes = await fetch(TOKEN_URL, {
  method: 'POST',
  headers: {
    'Content-Type': 'application/x-www-form-urlencoded',
    Authorization: `Basic ${basicAuth}`,
  },
  body: new URLSearchParams({
    grant_type: 'authorization_code', code: authCode,
    client_id: CLIENT_ID, client_secret: CLIENT_SECRET, redirect_uri: REDIRECT_URI,
  }).toString(),
});
const tokenBody = await tokenRes.text();
if (!tokenRes.ok) fail('3/5', `HTTP ${tokenRes.status} — ${tokenBody}`);

let accessToken, refreshToken, expiresIn;
try {
  const json = JSON.parse(tokenBody);
  accessToken  = json.access_token;
  refreshToken = json.refresh_token;
  expiresIn    = json.expires_in;
} catch { fail('3/5', `non-JSON response: ${tokenBody}`); }
if (!accessToken) fail('3/5', `no access_token in response: ${tokenBody}`);
log('3/5', `OK — token acquired (${accessToken.length} chars, expires in ${expiresIn}s)`);

// ── Step 3: List appliances ─────────────────────────────────────────────────
const applianceUrl = `${API_BASE}/v1/appliance`;
log('4/5', `GET ${applianceUrl}`);
const appRes = await fetch(applianceUrl, {
  headers: { Authorization: `Bearer ${accessToken}`, Accept: 'application/json' },
});
if (!appRes.ok) fail('4/5', `HTTP ${appRes.status} — ${await appRes.text().catch(() => '')}`);
const appJson = await appRes.json();

const items = Array.isArray(appJson) ? appJson : (appJson?.items ?? []);
if (items.length === 0) fail('4/5', `no appliances returned — raw: ${JSON.stringify(appJson).slice(0, 1000)}`);
log('4/5', `OK — ${items.length} appliance(s) found:`);

for (const item of items) {
  const id   = item.jid ?? item.applianceId ?? item.id ?? '?';
  const name = item.name ?? item.nickname ?? '(unnamed)';
  const type = item.type ?? '(unknown type)';
  const online = item.online ?? item.connected ?? '?';
  console.log(`        • ${name}  type=${type}  id=${id}  online=${online}`);
}

// ── Step 4: Fetch ERD data for laundry appliances ───────────────────────────
const laundry = items.filter(i => {
  const t = (i.type ?? '').toLowerCase();
  return t.includes('washer') || t.includes('dryer');
});

if (laundry.length === 0) {
  log('5/5', 'No washer/dryer found — skipping ERD fetch. Other appliance types listed above.');
} else {
  for (const app of laundry) {
    const appId = app.jid ?? app.applianceId ?? app.id;
    const erdUrl = `${API_BASE}/v1/appliance/${appId}/erd`;
    log('5/5', `GET ${erdUrl}`);
    const erdRes = await fetch(erdUrl, {
      headers: { Authorization: `Bearer ${accessToken}`, Accept: 'application/json' },
    });
    if (!erdRes.ok) {
      console.error(`        WARN: HTTP ${erdRes.status} — ${await erdRes.text().catch(() => '')}`);
      continue;
    }
    const erdJson = await erdRes.json();
    const erdItems = Array.isArray(erdJson) ? erdJson : (erdJson?.items ?? []);

    const STATE_MAP = { 0: 'off', 1: 'standby', 2: 'running', 3: 'paused', 4: 'complete', 5: 'delayed', 6: 'delayed', 7: 'delayed', 8: 'error' };
    const parseHex = v => parseInt((v ?? '').replace('0x', ''), 16) || 0;

    let machineState = '?', remaining = '?';
    for (const e of erdItems) {
      const erd = (e.erd ?? e.key ?? '').toLowerCase();
      const val = e.value ?? '';
      if (erd === '0x2000') machineState = STATE_MAP[parseHex(val)] ?? `unknown(${val})`;
      if (erd === '0x2007') { const m = parseHex(val); remaining = m > 0 ? `${m} min` : 'none'; }
    }
    console.log(`        • ${app.name ?? app.nickname ?? appId}: state=${machineState}  remaining=${remaining}  (${erdItems.length} ERDs total)`);
  }
}

// ── Step 5: Refresh token round-trip ────────────────────────────────────────
if (refreshToken) {
  log('5/5', 'Testing refresh_token grant');
  const refRes = await fetch(TOKEN_URL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      Authorization: `Basic ${basicAuth}`,
    },
    body: new URLSearchParams({
      grant_type: 'refresh_token', refresh_token: refreshToken,
      client_id: CLIENT_ID, client_secret: CLIENT_SECRET, redirect_uri: REDIRECT_URI,
    }).toString(),
  });
  if (!refRes.ok) {
    console.error(`        WARN: refresh failed HTTP ${refRes.status} — ${await refRes.text().catch(() => '')}`);
  } else {
    const refJson = await refRes.json();
    log('5/5', `OK — refreshed token (${(refJson.access_token ?? '').length} chars)`);
  }
} else {
  log('5/5', 'No refresh_token returned — skipping refresh test');
}

console.log('\nSUCCESS — GE SmartHQ integration works end-to-end.');
```

- [ ] **Step 2: Run the test script**

Run: `GE_EMAIL='...' GE_PASSWORD='...' node server/scripts/test-smarthq.mjs`
Expected: All 5 steps pass, appliances listed, SUCCESS message.

- [ ] **Step 3: Commit**

```bash
git add server/scripts/test-smarthq.mjs
git commit -m "test(smarthq): rewrite test script to use headless OAuth flow

Replaces broken password grant with the authorization_code flow matching
the gehome SDK. Steps: form login → code exchange → list appliances → ERDs → refresh."
```

---

### Task 4: Build and end-to-end verification

- [ ] **Step 1: Full server build**

Run: `cd server && npm run build`
Expected: clean build, no errors.

- [ ] **Step 2: Run the test script end-to-end**

Run: `GE_EMAIL='...' GE_PASSWORD='...' node server/scripts/test-smarthq.mjs`
Expected: SUCCESS output. If it fails, debug and fix.

- [ ] **Step 3: Start the server and test via web UI**

Run: `cd server && npm start`
Then in the web UI, go to Settings → SmartHQ, enter credentials, click Sign In.
Expected: Status changes to "Linked", appliances appear.

- [ ] **Step 4: Final commit if any fixes were needed**

```bash
git add -p  # stage only relevant changes
git commit -m "fix(smarthq): address issues found during e2e testing"
```
