import type { ChargingStatus, ChargePointCharger, ChargePointSession, ChargePointSessionStats } from './types.js';

const DISCOVERY_URL = 'https://discovery.chargepoint.com/discovery/v3/globalconfig';
// Mimic the ChargePoint mobile app so DataDome bot protection doesn't block us.
// NOTE: DataDome blocks Node.js fetch on the login endpoint (requires browser-like TLS
// fingerprint or JS challenge). The iOS app connects directly — this server client may
// fail on login due to DataDome captcha challenges.
const USER_AGENT = 'ChargePoint/6.0.0 CFNetwork/1568.200.51 Darwin/24.1.0';
const ACCEPT_HEADERS = {
  'Accept': 'application/json',
  'Accept-Language': 'en-US,en;q=0.9',
};

interface Endpoints {
  ssoEndpoint: string;
  hcmEndpoint: string;
  accountsEndpoint: string;
  driverBffEndpoint: string;
  portalDomainEndpoint: string;
  webservicesEndpoint: string;
  region: string;
}

export interface ChargePointSessionInfo {
  token: string;
  tokenType: string; // "coulomb_sess" or "auth-session"
  userId: number;
  endpoints: Endpoints;
}

function authHeaders(session: ChargePointSessionInfo): Record<string, string> {
  if (session.tokenType === 'coulomb_sess') {
    return {
      'User-Agent': USER_AGENT,
      'Content-Type': 'application/json',
      'Cookie': `coulomb_sess=${session.token}`,
      'cp-session-type': 'CP_SESSION_TOKEN',
      'cp-session-token': session.token,
      'cp-region': session.endpoints.region,
    };
  }
  // Fallback: auth-session Bearer (works for profile, may not work for HCM)
  return {
    'User-Agent': USER_AGENT,
    'Content-Type': 'application/json',
    'Authorization': `Bearer ${session.token}`,
    'cp-region': session.endpoints.region,
  };
}

async function discoverEndpoints(username: string): Promise<Endpoints> {
  const res = await fetch(DISCOVERY_URL, {
    method: 'POST',
    headers: { 'User-Agent': USER_AGENT, 'Content-Type': 'application/json', ...ACCEPT_HEADERS },
    body: JSON.stringify({ username }),
  });

  if (!res.ok) {
    throw new Error(`ChargePoint discovery failed: ${res.status} ${res.statusText}`);
  }

  const data = await res.json() as Record<string, unknown>;
  const endpoints = (data.endPoints ?? data.endpoints) as Record<string, Record<string, string>> | undefined;

  // Discovery endpoints sometimes come back without a trailing slash. All URL
  // construction below uses naive concatenation, so normalize here.
  const getValue = (key: string): string => {
    const entry = endpoints?.[key];
    const v = (entry?.value ?? '') as string;
    if (!v || v.endsWith('/')) return v;
    return v + '/';
  };

  return {
    ssoEndpoint: getValue('sso_endpoint'),
    hcmEndpoint: getValue('hcpo_hcm_endpoint'),
    accountsEndpoint: getValue('accounts_endpoint'),
    driverBffEndpoint: getValue('internal_api_gateway_endpoint'),
    portalDomainEndpoint: getValue('portal_domain_endpoint'),
    webservicesEndpoint: getValue('webservices_endpoint'),
    region: (data.region as string) ?? 'NA',
  };
}

export async function login(email: string, password: string): Promise<ChargePointSessionInfo> {
  const endpoints = await discoverEndpoints(email);

  const loginUrl = `${endpoints.ssoEndpoint}v1/user/login`;
  const res = await fetch(loginUrl, {
    method: 'POST',
    headers: { 'User-Agent': USER_AGENT, 'Content-Type': 'application/json', ...ACCEPT_HEADERS },
    body: JSON.stringify({ username: email, password }),
    redirect: 'manual',
  });

  if (!res.ok && res.status !== 302) {
    const text = await res.text().catch(() => '');
    throw new Error(`ChargePoint login failed: ${res.status}${text ? ` — ${text}` : ''}`);
  }

  // Extract session token from Set-Cookie header.
  // ChargePoint uses either "coulomb_sess" (legacy) or "auth-session" (current JWT).
  const setCookie = res.headers.get('set-cookie') ?? '';
  let token: string;
  let tokenType: string;

  const coulombMatch = setCookie.match(/coulomb_sess=([^;]+)/);
  const authSessionMatch = setCookie.match(/auth-session=([^;]+)/);

  if (coulombMatch) {
    token = coulombMatch[1];
    tokenType = 'coulomb_sess';
  } else if (authSessionMatch) {
    token = authSessionMatch[1];
    tokenType = 'auth-session';
  } else {
    throw new Error(`ChargePoint login: no session cookie in response. Set-Cookie: ${setCookie.slice(0, 200)}`);
  }

  // If we got auth-session JWT, exchange it for coulomb_sess via portal endpoint.
  // The HCM endpoints only accept coulomb_sess cookie auth.
  if (tokenType === 'auth-session' && endpoints.portalDomainEndpoint) {
    const portalBase = endpoints.portalDomainEndpoint.endsWith('/')
      ? endpoints.portalDomainEndpoint
      : endpoints.portalDomainEndpoint + '/';
    const exchangeUrl = `${portalBase}index.php/nghelper/getSession`;
    try {
      const exchangeRes = await fetch(exchangeUrl, {
        headers: {
          'User-Agent': USER_AGENT,
          'Cookie': `auth-session=${token}`,
        },
      });
      const exchangeCookie = exchangeRes.headers.get('set-cookie') ?? '';
      const coulombExchange = exchangeCookie.match(/coulomb_sess=([^;]+)/);
      if (coulombExchange) {
        token = decodeURIComponent(coulombExchange[1]);
        tokenType = 'coulomb_sess';
      }
    } catch (err) {
      console.warn('ChargePoint: token exchange failed:', (err as Error).message);
    }
  }

  // Get user ID from account endpoint
  const accountUrl = `${endpoints.accountsEndpoint}v1/driver/profile/user`;
  const profileHeaders: Record<string, string> = {
    'User-Agent': USER_AGENT,
    'cp-region': endpoints.region,
  };
  if (tokenType === 'coulomb_sess') {
    profileHeaders['Cookie'] = `coulomb_sess=${token}`;
    profileHeaders['cp-session-type'] = 'CP_SESSION_TOKEN';
    profileHeaders['cp-session-token'] = token;
  } else {
    profileHeaders['Authorization'] = `Bearer ${token}`;
  }

  const accountRes = await fetch(accountUrl, { headers: profileHeaders });

  if (!accountRes.ok) {
    throw new Error(`ChargePoint account fetch failed: ${accountRes.status}`);
  }

  const accountData = await accountRes.json() as {
    user?: { user_id?: number; userId?: number };
    user_id?: number;
    userId?: number;
  };
  const userId = accountData.user?.userId ?? accountData.user?.user_id ?? accountData.userId ?? accountData.user_id;
  if (!userId) {
    throw new Error('ChargePoint: no user_id in account response');
  }

  // Refresh token from response cookies if present
  const refreshCookie = accountRes.headers.get('set-cookie') ?? '';
  const coulombRefresh = refreshCookie.match(/coulomb_sess=([^;]+)/);
  if (coulombRefresh) {
    token = decodeURIComponent(coulombRefresh[1]);
    tokenType = 'coulomb_sess';
  }

  return { token, tokenType, userId, endpoints };
}

function parseChargingStatus(raw: string): ChargingStatus {
  // Exact match on known values first — substring matching wrongly maps
  // "NOT_CHARGING" to 'charging' because it contains "charging".
  switch (raw.toUpperCase()) {
    case 'CHARGING':
    case 'IN_USE':
      return 'charging';
    case 'NOT_CHARGING':
    case 'PAUSED':
    case 'SCHEDULED':
    case 'WAITING_FOR_VEHICLE':
      return 'pluggedIn';
    case 'FULLY_CHARGED':
    case 'COMPLETE':
    case 'DONE':
      return 'complete';
    case 'AVAILABLE':
    case 'IDLE':
    case '':
      return 'idle';
  }
  // Substring fallback for unknown variants we haven't seen yet.
  const lower = raw.toLowerCase();
  if (lower.includes('error') || lower.includes('fault')) return 'error';
  if (lower.includes('fully') || lower.includes('complete')) return 'complete';
  if (lower.includes('plugged') || lower.includes('connected')) return 'pluggedIn';
  if (lower.includes('charging')) return 'charging';
  if (lower.includes('available') || lower.includes('idle')) return 'idle';
  return 'unknown';
}

/** Format a schedule start time ("HH:mm" or ISO) into a friendly time string. */
function formatScheduleTime(raw: string | undefined): string | null {
  if (!raw) return null;
  const m = raw.match(/^(\d{1,2}):(\d{2})/);
  if (m) {
    let h = Number(m[1]);
    const ampm = h >= 12 ? 'PM' : 'AM';
    h = h % 12 || 12;
    return `${h}:${m[2]} ${ampm}`;
  }
  return raw;
}

/**
 * Charging schedule for a home charger — same host/auth as the `/status` call:
 * GET {hcm}api/v1/schedule/charger/{id}/schedule →
 * `{ scheduleEnabled, defaultSchedule: { weekdays|weekends: { startTime "HH:mm" } } }`.
 * Returns whether a schedule is enabled and the start time for today's day-type.
 */
async function fetchSchedule(
  session: ChargePointSessionInfo,
  chargerId: string,
): Promise<{ enabled: boolean; startTime: string | null }> {
  try {
    const url = `${session.endpoints.hcmEndpoint}api/v1/schedule/charger/${chargerId}/schedule`;
    const res = await fetch(url, { headers: authHeaders(session) });
    if (!res.ok) return { enabled: false, startTime: null };
    const json = await res.json() as {
      scheduleEnabled?: boolean;
      defaultSchedule?: { weekdays?: { startTime?: string }; weekends?: { startTime?: string } };
    };
    const enabled = json.scheduleEnabled ?? false;
    // Pick the start time that applies to today (weekday vs weekend).
    const day = new Date().getDay(); // 0=Sun ... 6=Sat
    const isWeekend = day === 0 || day === 6;
    const slot = isWeekend ? json.defaultSchedule?.weekends : json.defaultSchedule?.weekdays;
    return { enabled, startTime: slot?.startTime ?? null };
  } catch {
    return { enabled: false, startTime: null };
  }
}

export async function getHomeChargers(
  session: ChargePointSessionInfo,
  accountIndex: number,
  nickname: string,
): Promise<ChargePointCharger[]> {
  const url = `${session.endpoints.hcmEndpoint}api/v1/configuration/users/${session.userId}/chargers`;
  const res = await fetch(url, { headers: authHeaders(session) });

  if (!res.ok) {
    throw new Error(`ChargePoint charger list failed: ${res.status}`);
  }

  const raw = await res.json() as Array<{ id: number | string }> | { data: Array<{ id: number | string }> };
  const items = Array.isArray(raw) ? raw : (raw.data ?? []);
  const chargerIds = items.map((item) => String(item.id));

  // Fetch status for each charger
  const chargers: ChargePointCharger[] = [];
  for (const chargerId of chargerIds) {
    try {
      const charger = await getChargerStatus(session, chargerId, accountIndex, nickname);
      chargers.push(charger);
    } catch (err) {
      console.error(`ChargePoint: failed to get status for charger ${chargerId}:`, (err as Error).message);
    }
  }

  return chargers;
}

export async function getChargerStatus(
  session: ChargePointSessionInfo,
  chargerId: string,
  accountIndex: number,
  nickname: string,
): Promise<ChargePointCharger> {
  const url = `${session.endpoints.hcmEndpoint}api/v1/configuration/users/${session.userId}/chargers/${chargerId}/status`;
  const res = await fetch(url, { headers: authHeaders(session) });

  if (!res.ok) {
    throw new Error(`ChargePoint charger status failed: ${res.status}`);
  }

  // ChargePoint flipped this endpoint from snake_case to camelCase. Read the
  // new keys first, fall back to the old ones for resilience.
  const data = await res.json() as {
    chargingStatus?: string;
    charging_status?: string;
    isPluggedIn?: boolean;
    is_plugged_in?: boolean;
    chargeAmperageSettings?: {
      chargeLimit?: number;
      amperageLimit?: number;
      chargeAmperageLimit?: number;
      possibleChargeLimit?: number[];
      possibleAmperageLimits?: number[];
      inProgress?: number;
    };
    amperage_limit?: number;
    possible_amperage_limits?: number[];
    power_kw?: number;
    powerKw?: number;
    energy_kwh?: number;
    energyKwh?: number;
    isDuringScheduledTime?: boolean;
    is_during_scheduled_time?: boolean;
    isConnected?: boolean;
    is_connected?: boolean;
  };

  const amps = data.chargeAmperageSettings;
  const possibleAmps = amps?.possibleChargeLimit ?? amps?.possibleAmperageLimits ?? data.possible_amperage_limits ?? [];
  const maxAmperage = possibleAmps.length > 0 ? Math.max(...possibleAmps) : 40;
  const amperage = amps?.chargeLimit ?? amps?.amperageLimit ?? amps?.chargeAmperageLimit ?? data.amperage_limit ?? 0;

  // Live state comes straight from this endpoint — the ChargePoint app itself
  // polls exactly this `/status` call (confirmed by intercepting it). Beyond
  // `chargingStatus` is authoritative — this is the app's own `/status` endpoint and
  // it drives the app's "Charging" / "Charging complete" text — so we trust it for the
  // terminal states and use `isPluggedIn` + the schedule only to distinguish
  // plugged-and-waiting ("Scheduled") from plain plugged-in.
  //
  // NOTE: `isDuringScheduledTime` means "inside a scheduled *window*", NOT "actively
  // charging" — a completed charge still sits inside the window, so using it to infer
  // charging mislabels "Charging complete" as "Charging". Kept for diagnostics only.
  const isPlugged = data.isPluggedIn ?? data.is_plugged_in ?? false;
  const isDuringScheduled = data.isDuringScheduledTime ?? data.is_during_scheduled_time ?? false;
  const isConnected = data.isConnected ?? data.is_connected ?? true;
  const base = parseChargingStatus(data.chargingStatus ?? data.charging_status ?? '');

  // TEMP diagnostic — confirm exact chargingStatus values for charging vs. complete.
  console.log(`ChargePoint: status ${chargerId} chargingStatus=${data.chargingStatus ?? data.charging_status ?? ''} plugged=${isPlugged} duringScheduled=${isDuringScheduled} connected=${isConnected}`);

  let status: ChargingStatus;
  let scheduledFor: string | null = null;
  if (!isConnected) {
    status = 'error';
  } else if (base === 'charging') {
    status = 'charging';
  } else if (base === 'complete') {
    status = 'complete';
  } else if (base === 'error') {
    status = 'error';
  } else if (isPlugged) {
    const schedule = await fetchSchedule(session, chargerId);
    if (schedule.enabled && schedule.startTime) {
      status = 'scheduled';
      scheduledFor = formatScheduleTime(schedule.startTime);
    } else {
      status = 'pluggedIn';
    }
  } else {
    status = 'idle';
  }

  // power_kw / energy_kwh are not returned by this endpoint in the new API shape —
  // instantaneous telemetry would need the panda WebSocket.
  return {
    chargerId,
    accountIndex,
    nickname,
    status,
    isPluggedIn: isPlugged,
    scheduledFor,
    powerKw: data.powerKw ?? data.power_kw ?? null,
    energyKwh: data.energyKwh ?? data.energy_kwh ?? null,
    amperage,
    maxAmperage,
    lastUpdated: Date.now(),
  };
}

export async function setAmperage(
  session: ChargePointSessionInfo,
  chargerId: string,
  amps: number,
): Promise<void> {
  const url = `${session.endpoints.hcmEndpoint}api/v1/configuration/chargers/${chargerId}/charge-amperage-limit`;
  const res = await fetch(url, {
    method: 'PUT',
    headers: authHeaders(session),
    body: JSON.stringify({ chargeAmperageLimit: amps }),
  });

  if (!res.ok) {
    throw new Error(`ChargePoint set amperage failed: ${res.status}`);
  }
}

/**
 * Pick the live/most-recent session for a charger from the account-wide
 * charging-activities feed. Returns null when unplugged (caller clears stats).
 * Matches by chargerId (device_id); falls back to the account's most-recent
 * activity when nothing matches (single-charger accounts sometimes report a
 * different device_id than the configuration `id`).
 */
export function pickLiveSession(
  sessions: ChargePointSession[],
  chargerId: string,
  isPluggedIn: boolean,
): ChargePointSessionStats | null {
  if (!isPluggedIn) return null;

  let candidates = sessions.filter((s) => s.chargerId === chargerId);
  if (candidates.length === 0) candidates = sessions;
  if (candidates.length === 0) return null;

  const latest = candidates.reduce((a, b) => (b.startTime > a.startTime ? b : a));
  const endTime = latest.endTime;
  const durationMs = (endTime ?? Date.now()) - latest.startTime;

  return {
    energyKwh: latest.energyKwh,
    cost: latest.cost,
    milesAdded: latest.milesAdded,
    startTime: latest.startTime,
    endTime,
    durationSeconds: Math.max(0, Math.round(durationMs / 1000)),
  };
}

export async function getSessionHistory(
  session: ChargePointSessionInfo,
  _chargerId: string,
): Promise<ChargePointSession[]> {
  // The driver-bff endpoint provides session data for the account
  // For now, we use the charging activity endpoint
  const url = `${session.endpoints.driverBffEndpoint}driver-bff/v1/user/${session.userId}/charging-activities`;
  const res = await fetch(url, { headers: authHeaders(session) });

  if (!res.ok) {
    // Session history may not be available — return empty gracefully
    console.warn(`ChargePoint session history fetch returned ${res.status}`);
    return [];
  }

  const data = await res.json() as {
    charging_activities?: Array<{
      session_id?: number;
      device_id?: number | string;
      start_time?: number | string;
      end_time?: number | string;
      energy_kwh?: number;
      total_amount?: number;
      miles_added?: number;
    }>;
  };

  return (data.charging_activities ?? []).map((s) => ({
    sessionId: String(s.session_id ?? ''),
    chargerId: String(s.device_id ?? ''),
    startTime: typeof s.start_time === 'number' ? s.start_time : new Date(s.start_time ?? 0).getTime(),
    endTime: s.end_time ? (typeof s.end_time === 'number' ? s.end_time : new Date(s.end_time).getTime()) : null,
    energyKwh: s.energy_kwh ?? 0,
    cost: s.total_amount ?? null,
    milesAdded: s.miles_added ?? null,
  }));
}
