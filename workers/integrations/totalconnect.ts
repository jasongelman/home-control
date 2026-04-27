// Total Connect 2.0 (Resideo) — HTTP client for Cloudflare Workers.
//
// Ported from server/src/totalconnect/TotalConnectClient.ts. The on-the-wire
// protocol is identical; the only difference is RSA encryption uses the Web
// Crypto API (via nodejs_compat) instead of Node's `crypto.publicEncrypt`.

import { publicEncrypt, constants } from 'node:crypto';
import forge from 'node-forge';

// ── Types ────────────────────────────────────────────────────────────────────

export type PanelState =
  | 'disarmed'
  | 'armedAway'
  | 'armedHome'
  | 'armedNight'
  | 'alarming'
  | 'arming'
  | 'disarming'
  | 'unknown';

export const ArmType = {
  Away:        0,
  Stay:        1,
  StayInstant: 2,
  AwayInstant: 3,
  Night:       4,
} as const;
export type ArmType = typeof ArmType[keyof typeof ArmType];

export interface AlarmPanel {
  locationId: string;
  securityDeviceId: string;
  name: string;
  state: PanelState;
  rawArmingState: number;
  partitionIds: number[];
  lastUpdated: number;
}

export interface AlarmZone {
  zoneId: number;
  name: string;
  faulted: boolean;
  bypassed: boolean;
  lowBattery: boolean;
}

export interface AlarmConfig {
  username: string;
  password: string;
  userCode: string;
  enabled: boolean;
}

export interface TCSession {
  token: string;
  appId: string;
  appVersion: string;
  locations: Array<{
    locationId: string;
    securityDeviceId: string;
    name: string;
    partitionIds: number[];
  }>;
  expiresAt: number;
}

// ── Dry run: encrypt and build form body but don't send to TC2 ───────────────

export async function dryRunAuth(username: string, password: string): Promise<Record<string, unknown>> {
  const configRes = await fetch(APP_CONFIG_URL);
  const configData = await configRes.json() as {
    AppConfig?: Array<{ tc2APIKey?: string; tc2ClientId?: string }>;
  };
  const rsaKeyPem = configData.AppConfig?.[0]?.tc2APIKey ?? '';
  const clientId = configData.AppConfig?.[0]?.tc2ClientId ?? '';

  // Encrypt with forge (known-good PKCS1v1.5)
  const pemStr = rsaKeyPem.includes('BEGIN PUBLIC KEY')
    ? rsaKeyPem
    : `-----BEGIN PUBLIC KEY-----\n${rsaKeyPem.match(/.{1,64}/g)?.join('\n') ?? rsaKeyPem}\n-----END PUBLIC KEY-----`;
  const publicKey = forge.pki.publicKeyFromPem(pemStr);
  const encUsername = forge.util.encode64(publicKey.encrypt(username, 'RSAES-PKCS1-V1_5'));
  const encPassword = forge.util.encode64(publicKey.encrypt(password, 'RSAES-PKCS1-V1_5'));

  const body = new URLSearchParams({
    grant_type: 'password',
    client_id: clientId,
    username: encUsername,
    password: encPassword,
  }).toString();

  return {
    tokenUrl: TOKEN_URL,
    body: body,
    curlCommand: `curl -sS '${TOKEN_URL}' -X POST -H 'Content-Type: application/x-www-form-urlencoded' -d '${body}'`,
  };
}

// ── Full auth test (returns every intermediate value for debugging) ───────────

export async function testTc2Auth(username: string, password: string): Promise<Record<string, unknown>> {
  const result: Record<string, unknown> = {};

  // Step 1: config
  const configRes = await fetch(APP_CONFIG_URL);
  result.configStatus = configRes.status;
  const configData = await configRes.json() as {
    version?: string; RevisionNumber?: string;
    brandInfo?: Array<{ BrandName?: string; AppID?: number | string }>;
    AppConfig?: Array<{ tc2APIKey?: string; tc2ClientId?: string }>;
  };
  const appConfig = configData.AppConfig?.[0];
  const brandEntry = configData.brandInfo?.find((b) => b.BrandName === 'totalconnect')
    ?? configData.brandInfo?.[0];
  const rsaKeyPem = appConfig?.tc2APIKey ?? '';
  const clientId = appConfig?.tc2ClientId ?? '';
  result.clientId = clientId;
  result.appId = brandEntry?.AppID;

  // Test three encryption methods
  const methods: Record<string, string[]> = {};

  // Method A: node-forge (pure JS, battle-tested PKCS1v1.5)
  try {
    const pemStr = rsaKeyPem.includes('BEGIN PUBLIC KEY')
      ? rsaKeyPem
      : `-----BEGIN PUBLIC KEY-----\n${rsaKeyPem.match(/.{1,64}/g)?.join('\n') ?? rsaKeyPem}\n-----END PUBLIC KEY-----`;
    const publicKey = forge.pki.publicKeyFromPem(pemStr);
    const encU = forge.util.encode64(publicKey.encrypt(username, 'RSAES-PKCS1-V1_5'));
    const encP = forge.util.encode64(publicKey.encrypt(password, 'RSAES-PKCS1-V1_5'));
    methods.forge = [encU, encP];
    result.forgeOk = true;
  } catch (err) {
    result.forgeOk = false;
    result.forgeError = (err as Error).message;
  }

  // Method B: node:crypto publicEncrypt
  try {
    const pemStr = rsaKeyPem.includes('BEGIN PUBLIC KEY')
      ? rsaKeyPem
      : `-----BEGIN PUBLIC KEY-----\n${rsaKeyPem.match(/.{1,64}/g)?.join('\n') ?? rsaKeyPem}\n-----END PUBLIC KEY-----`;
    const encU = publicEncrypt(
      { key: pemStr, padding: constants.RSA_PKCS1_PADDING },
      Buffer.from(username, 'utf8'),
    ).toString('base64');
    const encP = publicEncrypt(
      { key: pemStr, padding: constants.RSA_PKCS1_PADDING },
      Buffer.from(password, 'utf8'),
    ).toString('base64');
    methods.nodeCrypto = [encU, encP];
    result.nodeCryptoOk = true;
  } catch (err) {
    result.nodeCryptoOk = false;
    result.nodeCryptoError = (err as Error).message;
  }

  // Try each method against the token endpoint
  for (const [name, [encUsername, encPassword]] of Object.entries(methods)) {
    const body = new URLSearchParams({
      grant_type: 'password',
      client_id: clientId,
      username: encUsername,
      password: encPassword,
    }).toString();

    const tokenRes = await fetch(TOKEN_URL, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: body,
    });

    const tokenText = await tokenRes.text();
    result[`${name}_status`] = tokenRes.status;
    result[`${name}_response`] = tokenText;
  }

  return result;
}

// ── Diagnostic ───────────────────────────────────────────────────────────────

export async function diagnoseTc2Auth(): Promise<Record<string, unknown>> {
  const result: Record<string, unknown> = {};

  // Step 1: config fetch
  try {
    const configRes = await fetch(APP_CONFIG_URL);
    result.configStatus = configRes.status;
    const configData = await configRes.json() as Record<string, unknown>;
    const appConfig = (configData.AppConfig as Array<Record<string, unknown>>)?.[0];
    const brandEntry = (configData.brandInfo as Array<Record<string, unknown>>)?.find(
      (b) => b.BrandName === 'totalconnect',
    ) ?? (configData.brandInfo as Array<Record<string, unknown>>)?.[0];

    result.hasRsaKey = !!appConfig?.tc2APIKey;
    result.rsaKeyLength = typeof appConfig?.tc2APIKey === 'string' ? appConfig.tc2APIKey.length : 0;
    result.rsaKeyPrefix = typeof appConfig?.tc2APIKey === 'string' ? appConfig.tc2APIKey.substring(0, 30) + '...' : null;
    result.clientId = appConfig?.tc2ClientId ?? null;
    result.appId = brandEntry?.AppID ?? null;
    result.appVersion = configData.version ?? configData.RevisionNumber ?? null;
  } catch (err) {
    result.configError = (err as Error).message;
  }

  // Step 2: RSA encrypt test
  try {
    const rsaKey = result.rsaKeyPrefix ? 'present' : 'missing';
    result.rsaAvailable = rsaKey;
    result.RSA_PKCS1_PADDING_VALUE = constants.RSA_PKCS1_PADDING;
    result.RSA_PKCS1_OAEP_PADDING_VALUE = constants.RSA_PKCS1_OAEP_PADDING;

    // Try encrypting a test string with node:crypto
    const configRes = await fetch(APP_CONFIG_URL);
    const configData = await configRes.json() as { AppConfig?: Array<{ tc2APIKey?: string }> };
    const rsaKeyPem = configData.AppConfig?.[0]?.tc2APIKey;
    if (rsaKeyPem) {
      const pem = rsaKeyPem.includes('BEGIN PUBLIC KEY')
        ? rsaKeyPem
        : `-----BEGIN PUBLIC KEY-----\n${rsaKeyPem.match(/.{1,64}/g)?.join('\n') ?? rsaKeyPem}\n-----END PUBLIC KEY-----`;
      const encrypted = publicEncrypt(
        { key: pem, padding: constants.RSA_PKCS1_PADDING },
        Buffer.from('test', 'utf8'),
      );
      result.nodeCryptoEncryptedLength = encrypted.length;
      result.nodeCryptoEncryptWorks = true;

      // Also try Web Crypto PKCS1v1.5 for comparison
      try {
        const wcEncrypted = await rsaEncryptPkcs1v15WebCrypto(rsaKeyPem, 'test');
        result.webCryptoEncryptedLength = wcEncrypted.length;
        result.webCryptoBase64Length = btoa(String.fromCharCode(...wcEncrypted)).length;
        result.webCryptoEncryptWorks = true;
      } catch (wcErr) {
        result.webCryptoEncryptWorks = false;
        result.webCryptoEncryptError = (wcErr as Error).message;
      }
    }
  } catch (err) {
    result.nodeCryptoEncryptWorks = false;
    result.nodeCryptoEncryptError = (err as Error).message;
  }

  return result;
}

// ── Constants ────────────────────────────────────────────────────────────────

const APP_CONFIG_URL = 'https://totalconnect2.com/application.config.json';
const TOKEN_URL      = 'https://rs.alarmnet.com/TC2API.Auth/token';
const API_BASE       = 'https://rs.alarmnet.com/TC2API.TCResource/';

// ── Auth ─────────────────────────────────────────────────────────────────────

export async function authenticate(username: string, password: string): Promise<TCSession> {
  // Step 1: fetch RSA public key + client config
  const configRes = await fetch(APP_CONFIG_URL);
  if (!configRes.ok) throw new Error(`TC2 config fetch failed: ${configRes.status}`);

  const configData = await configRes.json() as {
    version?: string;
    RevisionNumber?: string;
    brandInfo?: Array<{ BrandName?: string; AppID?: number | string }>;
    AppConfig?: Array<{ tc2APIKey?: string; tc2ClientId?: string }>;
  };

  const appConfig = configData.AppConfig?.[0];
  const brandEntry = configData.brandInfo?.find((b) => b.BrandName === 'totalconnect')
    ?? configData.brandInfo?.[0];

  const rsaKeyPem = appConfig?.tc2APIKey;
  const clientId  = appConfig?.tc2ClientId;
  const appId     = brandEntry?.AppID != null ? String(brandEntry.AppID) : '';
  const appVersion = configData.version ?? configData.RevisionNumber ?? '5.0.0';

  if (!rsaKeyPem || !clientId) {
    throw new Error('TC2: missing RSA key or clientId in app config');
  }

  // Step 2: RSA-PKCS1v15-encrypt credentials.
  // Use pure Web Crypto implementation because Workers' nodejs_compat may
  // silently use OAEP padding instead of PKCS1v1.5, which TC2 requires.
  const encUsernameBytes = await rsaEncryptPkcs1v15WebCrypto(rsaKeyPem, username);
  const encPasswordBytes = await rsaEncryptPkcs1v15WebCrypto(rsaKeyPem, password);
  const encUsername = btoa(String.fromCharCode(...encUsernameBytes));
  const encPassword = btoa(String.fromCharCode(...encPasswordBytes));

  // Step 3: OAuth2 password grant
  const tokenRes = await fetch(TOKEN_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'password',
      client_id:  clientId,
      username:   encUsername,
      password:   encPassword,
    }).toString(),
  });

  if (!tokenRes.ok) {
    const text = await tokenRes.text().catch(() => '');
    throw new Error(`TC2 token request failed: ${tokenRes.status}${text ? ` — ${text}` : ''}`);
  }

  const tokenData = await tokenRes.json() as { access_token?: string };
  const token = tokenData.access_token;
  if (!token) throw new Error('TC2: no access_token in response');

  // Step 4: fetch session details (locations + security devices)
  const sessionRes = await fetch(
    `${API_BASE}api/v3/authentication/sessiondetails?appId=${encodeURIComponent(appId)}&appVersion=${encodeURIComponent(appVersion)}`,
    { headers: { Authorization: `Bearer ${token}` } },
  );

  if (!sessionRes.ok) {
    throw new Error(`TC2 session details failed: ${sessionRes.status}`);
  }

  const sessionData = await sessionRes.json() as {
    SessionDetailsResult?: {
      Locations?: Array<{
        LocationID?: number | string;
        LocationName?: string;
        SecurityDeviceID?: number | string;
        DeviceList?: Array<{ DeviceID?: number | string; DeviceClassID?: number | string }>;
        PartitionIDs?: number[];
      }>;
    };
  };

  const rawLocations = sessionData.SessionDetailsResult?.Locations ?? [];
  const locations = rawLocations.map((loc) => {
    let deviceId: string = loc.SecurityDeviceID != null ? String(loc.SecurityDeviceID) : '';
    if (!deviceId && loc.DeviceList) {
      const sec = loc.DeviceList.find((d) => Number(d.DeviceClassID) === 1) ?? loc.DeviceList[0];
      if (sec?.DeviceID != null) deviceId = String(sec.DeviceID);
    }
    return {
      locationId:       String(loc.LocationID ?? ''),
      securityDeviceId: deviceId,
      name:             loc.LocationName ?? 'Home',
      partitionIds:     loc.PartitionIDs ?? [1],
    };
  }).filter((l) => l.locationId && l.securityDeviceId);

  if (locations.length === 0) {
    throw new Error('TC2: no locations with security devices found');
  }

  return {
    token,
    appId,
    appVersion,
    locations,
    expiresAt: Date.now() + 25 * 60 * 1000,
  };
}

// ── Status ───────────────────────────────────────────────────────────────────

export async function getPanelStatus(
  session: TCSession,
  locationId: string,
): Promise<{ armingState: number; zones: AlarmZone[] }> {
  const res = await fetch(
    `${API_BASE}api/v3/locations/${locationId}/partitions/fullStatus`,
    { headers: { Authorization: `Bearer ${session.token}` } },
  );

  if (res.status === 401) throw new Error('TC2: session expired');
  if (!res.ok) throw new Error(`TC2 panel status failed: ${res.status}`);

  const data = await res.json() as {
    PanelStatus?: {
      Partitions?: Array<{ ArmingState?: number }>;
      Zones?: Array<{
        ZoneID?: number;
        ZoneDescription?: string;
        ZoneStatus?: number;
      }>;
    };
  };

  const armingState = data.PanelStatus?.Partitions?.[0]?.ArmingState ?? 0;

  const zones: AlarmZone[] = (data.PanelStatus?.Zones ?? []).map((z) => {
    const status = z.ZoneStatus ?? 0;
    return {
      zoneId:     z.ZoneID ?? 0,
      name:       z.ZoneDescription ?? `Zone ${z.ZoneID ?? '?'}`,
      faulted:    (status & 0x02) !== 0,
      bypassed:   (status & 0x01) !== 0,
      lowBattery: (status & 0x08) !== 0,
    };
  });

  return { armingState, zones };
}

// ── Control ──────────────────────────────────────────────────────────────────

export async function arm(
  session: TCSession,
  locationId: string,
  securityDeviceId: string,
  armType: ArmType,
  userCode: string,
  partitionIds: number[],
): Promise<void> {
  const res = await fetch(
    `${API_BASE}api/v3/locations/${locationId}/devices/${securityDeviceId}/partitions/arm`,
    {
      method: 'PUT',
      headers: {
        Authorization:  `Bearer ${session.token}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        armType:    armType,
        userCode:   parseInt(userCode, 10),
        partitions: partitionIds,
      }),
    },
  );

  if (res.status === 401) throw new Error('TC2: session expired');
  if (!res.ok) {
    const text = await res.text().catch(() => '');
    throw new Error(`TC2 arm failed: ${res.status}${text ? ` — ${text}` : ''}`);
  }

  const data = await res.json().catch(() => ({})) as { ResultCode?: number; ResultData?: string };
  if (data.ResultCode !== undefined && data.ResultCode !== 0 && data.ResultCode !== 4500) {
    throw new Error(`TC2 arm rejected: code ${data.ResultCode} — ${data.ResultData ?? ''}`);
  }
}

export async function disarm(
  session: TCSession,
  locationId: string,
  securityDeviceId: string,
  userCode: string,
  partitionIds: number[],
): Promise<void> {
  const res = await fetch(
    `${API_BASE}api/v3/locations/${locationId}/devices/${securityDeviceId}/partitions/disArm`,
    {
      method: 'PUT',
      headers: {
        Authorization:  `Bearer ${session.token}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        userCode:   parseInt(userCode, 10),
        partitions: partitionIds,
      }),
    },
  );

  if (res.status === 401) throw new Error('TC2: session expired');
  if (!res.ok) {
    const text = await res.text().catch(() => '');
    throw new Error(`TC2 disarm failed: ${res.status}${text ? ` — ${text}` : ''}`);
  }

  const data = await res.json().catch(() => ({})) as { ResultCode?: number; ResultData?: string };
  if (data.ResultCode !== undefined && data.ResultCode !== 0 && data.ResultCode !== 4500) {
    throw new Error(`TC2 disarm rejected: code ${data.ResultCode} — ${data.ResultData ?? ''}`);
  }
}

// ── RSA PKCS1v1.5 via Web Crypto ─────────────────────────────────────────────
//
// Workers' nodejs_compat may silently use OAEP instead of PKCS1v1.5 when
// publicEncrypt is called with RSA_PKCS1_PADDING. TC2 requires PKCS1v1.5.
//
// Web Crypto doesn't natively support PKCS1v1.5 for encryption, but we can
// do it manually: apply PKCS1v1.5 type 2 padding ourselves, then use a raw
// RSA exponentiation via subtle.encrypt with RSA-OAEP + already-padded data.
//
// Actually, the trick is simpler: import the key as RSAES-PKCS1-v1_5... which
// Web Crypto doesn't support for encrypt. So we do it the hard way: parse the
// SPKI key, extract n and e, apply PKCS#1 v1.5 type 2 padding, then do modpow.

async function rsaEncryptPkcs1v15WebCrypto(
  spkiBase64: string,
  plaintext: string,
): Promise<Uint8Array> {
  // Parse SPKI to extract RSA n and e
  const spkiDer = base64ToBytes(spkiBase64);
  const { n, e } = parseSpkiRsa(spkiDer);

  const k = n.length; // key size in bytes (256 for 2048-bit)
  const msg = new TextEncoder().encode(plaintext);

  if (msg.length > k - 11) {
    throw new Error('Message too long for RSA PKCS1v1.5');
  }

  // PKCS#1 v1.5 type 2 padding: 0x00 || 0x02 || PS || 0x00 || M
  // PS = random non-zero bytes, length = k - mLen - 3
  const psLen = k - msg.length - 3;
  const ps = new Uint8Array(psLen);
  crypto.getRandomValues(ps);
  // Ensure no zero bytes in PS
  for (let i = 0; i < ps.length; i++) {
    while (ps[i] === 0) {
      crypto.getRandomValues(ps.subarray(i, i + 1));
    }
  }

  const em = new Uint8Array(k);
  em[0] = 0x00;
  em[1] = 0x02;
  em.set(ps, 2);
  em[2 + psLen] = 0x00;
  em.set(msg, 3 + psLen);

  // RSA: c = m^e mod n (big-integer modular exponentiation)
  const mBig = bytesToBigInt(em);
  const nBig = bytesToBigInt(n);
  const eBig = bytesToBigInt(e);
  const cBig = modPow(mBig, eBig, nBig);

  return bigIntToBytes(cBig, k);
}

function base64ToBytes(b64: string): Uint8Array {
  const clean = b64.replace(/[\s\-]/g, '').replace(/-----[^-]+-----/g, '');
  const binary = atob(clean);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function parseSpkiRsa(der: Uint8Array): { n: Uint8Array; e: Uint8Array } {
  // Minimal ASN.1 DER parser for RSA SPKI
  // SPKI = SEQUENCE { algorithm AlgorithmIdentifier, subjectPublicKey BIT STRING }
  // subjectPublicKey contents = SEQUENCE { n INTEGER, e INTEGER }
  let offset = 0;

  function readTag(): { tag: number; length: number; start: number } {
    const tag = der[offset++];
    let length = der[offset++];
    if (length & 0x80) {
      const numBytes = length & 0x7f;
      length = 0;
      for (let i = 0; i < numBytes; i++) {
        length = (length << 8) | der[offset++];
      }
    }
    return { tag, length, start: offset };
  }

  // Outer SEQUENCE
  readTag(); // tag=0x30

  // AlgorithmIdentifier SEQUENCE — skip it
  const algId = readTag();
  offset = algId.start + algId.length;

  // BIT STRING containing the RSA public key
  readTag(); // BIT STRING wrapper
  if (der[offset] === 0x00) offset++; // skip unused-bits byte

  // Inner SEQUENCE { n INTEGER, e INTEGER }
  readTag(); // inner SEQUENCE

  // n INTEGER
  const nTag = readTag();
  let nStart = nTag.start;
  let nLen = nTag.length;
  // Skip leading zero byte if present (ASN.1 sign byte)
  if (der[nStart] === 0x00) { nStart++; nLen--; }
  const n = der.slice(nStart, nStart + nLen);

  offset = nTag.start + nTag.length;

  // e INTEGER
  const eTag = readTag();
  const e = der.slice(eTag.start, eTag.start + eTag.length);

  return { n, e };
}

function bytesToBigInt(bytes: Uint8Array): bigint {
  let result = 0n;
  for (const b of bytes) {
    result = (result << 8n) | BigInt(b);
  }
  return result;
}

function bigIntToBytes(value: bigint, length: number): Uint8Array {
  const bytes = new Uint8Array(length);
  for (let i = length - 1; i >= 0; i--) {
    bytes[i] = Number(value & 0xffn);
    value >>= 8n;
  }
  return bytes;
}

function modPow(base: bigint, exp: bigint, mod: bigint): bigint {
  let result = 1n;
  base = base % mod;
  while (exp > 0n) {
    if (exp & 1n) {
      result = (result * base) % mod;
    }
    exp >>= 1n;
    base = (base * base) % mod;
  }
  return result;
}

// ── Helpers ──────────────────────────────────────────────────────────────────

export function mapArmingState(raw: number): PanelState {
  switch (raw) {
    case 10200: case 10211: case 10214:
      return 'disarmed';
    case 10201: case 10202: case 10205: case 10206:
      return 'armedAway';
    case 10203: case 10204: case 10209: case 10210:
      return 'armedHome';
    case 10218: case 10219: case 10220: case 10221:
      return 'armedNight';
    case 10207: case 10208: case 10212: case 10213: case 10215: case 10216: case 10217:
      return 'alarming';
    case 10307:
      return 'arming';
    case 10308:
      return 'disarming';
    default:
      return 'unknown';
  }
}
