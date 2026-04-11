import { publicEncrypt, constants } from 'crypto';
import type { AlarmZone, PanelState } from './types.js';
import { ArmType } from './types.js';

const APP_CONFIG_URL = 'https://totalconnect2.com/application.config.json';
const TOKEN_URL      = 'https://rs.alarmnet.com/TC2API.Auth/token';
const API_BASE       = 'https://rs.alarmnet.com/TC2API.TCResource/';

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

// ── Auth ──────────────────────────────────────────────────────────────────────

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

  // Top-level AppConfig holds the RSA key + client id; brandInfo holds per-brand AppID.
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
  // tc2APIKey is returned as raw base64 SPKI; wrap as PEM for node's crypto.
  const pem = rsaKeyPem.includes('BEGIN PUBLIC KEY')
    ? rsaKeyPem
    : `-----BEGIN PUBLIC KEY-----\n${rsaKeyPem.match(/.{1,64}/g)?.join('\n') ?? rsaKeyPem}\n-----END PUBLIC KEY-----`;

  const encrypt = (plaintext: string): string => {
    const encrypted = publicEncrypt(
      { key: pem, padding: constants.RSA_PKCS1_PADDING },
      Buffer.from(plaintext, 'utf8'),
    );
    return encrypted.toString('base64');
  };

  const encUsername = encrypt(username);
  const encPassword = encrypt(password);

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
    // Prefer top-level SecurityDeviceID; fall back to the security-class entry
    // in DeviceList (DeviceClassID === 1 is the security panel).
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
    expiresAt: Date.now() + 25 * 60 * 1000, // 25 min (TC2 tokens ~30 min)
  };
}

// ── Status ────────────────────────────────────────────────────────────────────

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
      faulted:    (status & 0x02) !== 0,   // bit 1 = faulted/open
      bypassed:   (status & 0x01) !== 0,   // bit 0 = bypassed
      lowBattery: (status & 0x08) !== 0,   // bit 3 = low battery
    };
  });

  return { armingState, zones };
}

// ── Control ───────────────────────────────────────────────────────────────────

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

  // ResultCode 0 or 4500 = success; check if response body indicates failure
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

// ── Helpers ───────────────────────────────────────────────────────────────────

export function mapArmingState(raw: number): PanelState {
  switch (raw) {
    // Disarmed
    case 10200: // Disarmed
    case 10211: // Disarmed + perimeter
    case 10214: // Disarmed + night mode off
      return 'disarmed';

    // Armed Away
    case 10201: // Armed Away
    case 10202: // Armed Away Instant
    case 10205: // Armed Away + fault
    case 10206: // Armed Away + alt fault
      return 'armedAway';

    // Armed Home / Stay
    case 10203: // Armed Stay
    case 10204: // Armed Stay Instant
    case 10209: // Armed Stay + fault
    case 10210: // Armed Stay + alt fault
      return 'armedHome';

    // Armed Night
    case 10218: // Armed Night
    case 10219:
    case 10220:
    case 10221:
      return 'armedNight';

    // Alarming
    case 10207: // Police alarm
    case 10208: // Alarm
    case 10212: // Fire alarm
    case 10213: // CO alarm
    case 10215: // Generic alarm
    case 10216:
    case 10217:
      return 'alarming';

    // Transitioning
    case 10307:
      return 'arming';
    case 10308:
      return 'disarming';

    default:
      return 'unknown';
  }
}
