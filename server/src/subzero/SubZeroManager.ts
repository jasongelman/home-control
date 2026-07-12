import { EventEmitter } from 'events';
import crypto from 'crypto';
// Real-time uses Node's built-in WebSocket (Node 22+) speaking the SignalR JSON
// protocol directly — the negotiate returns a receive-only Azure SignalR token,
// so a full @microsoft/signalr client isn't needed.
import type {
  SubZeroConfig, SubZeroRefrigerator, WolfOven, WolfCooktop,
  RefrigeratorMode, OvenMode,
} from './types.js';

// Azure B2C endpoints (production)
const B2C_BASE = 'https://login.subzero-wolf.com/subzerob2cprd.onmicrosoft.com/b2c_1a_signup_signin/oauth2/v2.0';
const B2C_CLIENT_ID = '6eefabd0-49a3-4b92-b329-81b9f638e940';

// Azure APIM gateway
const API_BASE = 'https://prod.iot.subzero.com';
// Default subscription key (consumer app); the real key may differ per endpoint
const DEFAULT_SUB_KEY = '0e85d3216b604e51a711f147c09e228a';
// Sent as app_version/app_platform headers on command POSTs (matches the Owner's app).
const APP_VERSION = '4.6.0';
// All known APIM subscription keys — different API products may require different keys
const ALL_SUB_KEYS = [
  '0e85d3216b604e51a711f147c09e228a',
  '16ca8ba0ad3f4eddaffcf8520454c2c9',
  '180fd5156a734e69b355970c9615403c',
  '25126214b7b7408283baefaec38010de',
  'a93bb184cbf944c7af266d5fa2680652',
  'e88bf0b60baf441583f822fa9ba9c895',
];
let directMethodSubKey: string | undefined;

// The SignalR/"modern" APIM product key — required for /signal-r/negotiateUser
// (a different product than the consumerapp key). Confirmed by live probe.
const SIGNALR_SUB_KEY = 'e88bf0b60baf441583f822fa9ba9c895';
const RS = '\x1e'; // SignalR JSON protocol record separator

const POLL_INTERVAL = 60_000;

/** Decode a JWT payload and extract the Sub-Zero userId (extension_sitecoreUserId claim). */
function extractUserId(jwt: string): string | undefined {
  const parts = jwt.split('.');
  if (parts.length < 2) return undefined;
  try {
    const payload = JSON.parse(Buffer.from(parts[1], 'base64url').toString());
    return payload.extension_sitecoreUserId ?? payload.oid ?? payload.sub;
  } catch {
    return undefined;
  }
}

// ── Mode mapping helpers ────────────────────────────────────────────────────

function parseRefrigeratorMode(val: unknown): RefrigeratorMode {
  if (typeof val === 'string') {
    const lower = val.toLowerCase();
    if (lower.includes('vacation')) return 'vacation';
    if (lower.includes('sabbath')) return 'sabbath';
    if (lower.includes('night')) return 'night';
    if (lower.includes('normal')) return 'normal';
  }
  return 'unknown';
}

function parseOvenMode(val: unknown): OvenMode {
  if (typeof val === 'string') {
    const lower = val.toLowerCase().replace(/[\s-]/g, '_');
    const known: OvenMode[] = [
      'off', 'bake', 'broil', 'convection', 'convection_roast',
      'roast', 'warm', 'proof', 'dehydrate', 'stone',
      'gourmet', 'gourmet_plus', 'self_clean', 'sous_vide',
      'steam', 'convection_steam', 'convection_humid',
    ];
    for (const m of known) {
      if (lower.includes(m)) return m;
    }
  }
  return 'unknown';
}

// ── SubZeroManager ──────────────────────────────────────────────────────────

export class SubZeroManager extends EventEmitter {
  private config: SubZeroConfig;
  private refrigerators: SubZeroRefrigerator[] = [];
  private ovens: WolfOven[] = [];
  private cooktops: WolfCooktop[] = [];
  private pollTimer: ReturnType<typeof setInterval> | null = null;
  private codeVerifier: string | null = null;
  private ws: WebSocket | null = null;
  private wsReconnectTimer: ReturnType<typeof setTimeout> | null = null;
  // Live property state from SignalR, keyed by deviceId
  private deviceProperties: Map<string, Record<string, unknown>> = new Map();
  // Device metadata (id, name, model, online) from the device list
  private deviceMeta: Map<string, { name: string; model: string; online: boolean; category: string }> = new Map();

  constructor(config: SubZeroConfig) {
    super();
    this.config = config;
  }

  get isLinked(): boolean {
    return !!(this.config.accessToken && this.config.enabled);
  }

  getRefrigerators(): SubZeroRefrigerator[] { return this.refrigerators; }
  getOvens(): WolfOven[] { return this.ovens; }
  getCooktops(): WolfCooktop[] { return this.cooktops; }

  updateConfig(cfg: SubZeroConfig): void {
    this.config = cfg;
    if (cfg.enabled && cfg.accessToken) {
      this.start();
    } else {
      this.stop();
    }
  }

  unlink(): void {
    this.stop();
    this.config.accessToken = undefined;
    this.config.refreshToken = undefined;
    this.config.tokenExpiresAt = undefined;
    this.config.enabled = false;
    this.refrigerators = [];
    this.ovens = [];
    this.cooktops = [];
    this.emit('configChanged', this.config);
    this.emit('stateChange');
  }

  // ── OAuth2 Authorization Code + PKCE ────────────────────────────────────

  getAuthUrl(redirectBase: string): string {
    this.codeVerifier = crypto.randomBytes(32).toString('base64url');
    const codeChallenge = crypto
      .createHash('sha256')
      .update(this.codeVerifier)
      .digest('base64url');

    const params = new URLSearchParams({
      client_id: B2C_CLIENT_ID,
      response_type: 'code',
      redirect_uri: `${redirectBase}/api/subzero/oauth/callback`,
      scope: `${B2C_CLIENT_ID} openid offline_access`,
      response_mode: 'query',
      code_challenge: codeChallenge,
      code_challenge_method: 'S256',
    });
    return `${B2C_BASE}/authorize?${params}`;
  }

  async handleCallback(code: string, redirectBase: string): Promise<void> {
    if (!this.codeVerifier) throw new Error('No code verifier — call getAuthUrl first');

    const body = new URLSearchParams({
      grant_type: 'authorization_code',
      client_id: B2C_CLIENT_ID,
      code,
      redirect_uri: `${redirectBase}/api/subzero/oauth/callback`,
      code_verifier: this.codeVerifier,
      scope: `${B2C_CLIENT_ID} openid offline_access`,
    });

    const res = await fetch(`${B2C_BASE}/token`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: body.toString(),
    });
    if (!res.ok) {
      const text = await res.text();
      throw new Error(`SubZero B2C token exchange failed: ${res.status} ${text}`);
    }

    const json = await res.json() as Record<string, unknown>;
    this.config.accessToken = json.access_token as string;
    this.config.refreshToken = json.refresh_token as string | undefined;
    this.config.tokenExpiresAt = Date.now() + ((json.expires_in as number ?? 3600) - 60) * 1000;
    this.config.userId = extractUserId(this.config.accessToken) ?? this.config.userId;
    this.config.enabled = true;
    this.codeVerifier = null;
    this.emit('configChanged', this.config);

    await this.fetchAppliances();
    this.start();
  }

  // ── Token management ────────────────────────────────────────────────────

  private async getToken(): Promise<string> {
    if (this.config.accessToken && this.config.tokenExpiresAt && Date.now() < this.config.tokenExpiresAt) {
      return this.config.accessToken;
    }
    if (this.config.refreshToken) {
      await this.refreshAccessToken();
      return this.config.accessToken!;
    }
    throw new Error('SubZero: no valid token and no refresh token');
  }

  private async refreshAccessToken(): Promise<void> {
    const body = new URLSearchParams({
      grant_type: 'refresh_token',
      client_id: B2C_CLIENT_ID,
      refresh_token: this.config.refreshToken!,
      scope: `${B2C_CLIENT_ID} openid offline_access`,
    });

    const res = await fetch(`${B2C_BASE}/token`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: body.toString(),
    });
    if (!res.ok) {
      console.error('SubZero: token refresh failed', res.status);
      this.unlink();
      return;
    }

    const json = await res.json() as Record<string, unknown>;
    this.config.accessToken = json.access_token as string;
    if (json.refresh_token) this.config.refreshToken = json.refresh_token as string;
    this.config.tokenExpiresAt = Date.now() + ((json.expires_in as number ?? 3600) - 60) * 1000;
    this.emit('configChanged', this.config);
  }

  // ── API helpers ─────────────────────────────────────────────────────────

  private get subKey(): string {
    return this.config.subscriptionKey ?? DEFAULT_SUB_KEY;
  }

  private async apiGet(path: string): Promise<unknown> {
    const token = await this.getToken();
    const uid = this.config.userId;
    const headers: Record<string, string> = {
      'Authorization': `Bearer ${token}`,
      'Ocp-Apim-Subscription-Key': this.subKey,
      'Accept': 'application/json',
    };
    if (uid) headers['userId'] = uid;
    const res = await fetch(`${API_BASE}${path}`, { headers });
    if (res.status === 401) {
      // Try refresh once
      await this.refreshAccessToken();
      const token2 = this.config.accessToken;
      if (!token2) throw new Error('SubZero: refresh failed');
      const headers2: Record<string, string> = {
        'Authorization': `Bearer ${token2}`,
        'Ocp-Apim-Subscription-Key': this.subKey,
        'Accept': 'application/json',
      };
      if (this.config.userId) headers2['userId'] = this.config.userId;
      const res2 = await fetch(`${API_BASE}${path}`, { headers: headers2 });
      if (!res2.ok) throw new Error(`SubZero API ${path}: ${res2.status}`);
      return res2.json();
    }
    if (!res.ok) {
      const text = await res.text().catch(() => '');
      console.error(`SubZero API ${path}: ${res.status}`, text.slice(0, 300));
      throw new Error(`SubZero API ${path}: ${res.status}`);
    }
    return res.json();
  }

  private async apiPost(path: string, body: unknown): Promise<unknown> {
    const token = await this.getToken();
    const uid = this.config.userId;
    const isDirectMethod = path.includes('directmethod');

    // For directmethod endpoints, discover the correct subscription key
    if (isDirectMethod && !directMethodSubKey) {
      console.log('SubZero: discovering subscription key for directmethod API...');
      for (const key of ALL_SUB_KEYS) {
        const hdrs: Record<string, string> = {
          'Authorization': `Bearer ${token}`,
          'Ocp-Apim-Subscription-Key': key,
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        };
        if (uid) hdrs['userId'] = uid;
        const r = await fetch(`${API_BASE}${path}`, { method: 'POST', headers: hdrs, body: JSON.stringify(body) });
        const t = await r.text().catch(() => '');
        console.log(`  key ${key.slice(0, 8)}... => HTTP ${r.status} ${t.slice(0, 200)}`);
        if (r.status !== 404 && r.status !== 401 && r.status !== 403) {
          directMethodSubKey = key;
          if (r.ok) return JSON.parse(t || '{}');
          throw new Error(`SubZero POST ${path}: ${r.status} ${t.slice(0, 200)}`);
        }
      }
      console.error('SubZero: no subscription key works for', path);
      throw new Error(`SubZero POST ${path}: no valid subscription key found`);
    }

    const subKey = isDirectMethod ? (directMethodSubKey ?? this.subKey) : this.subKey;
    const headers: Record<string, string> = {
      'Authorization': `Bearer ${token}`,
      'Ocp-Apim-Subscription-Key': subKey,
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
    if (uid) headers['userId'] = uid;
    const res = await fetch(`${API_BASE}${path}`, {
      method: 'POST',
      headers,
      body: JSON.stringify(body),
    });
    if (!res.ok) {
      const text = await res.text().catch(() => '');
      console.error(`SubZero POST ${path}: ${res.status}`, text.slice(0, 300));
      throw new Error(`SubZero POST ${path}: ${res.status}`);
    }
    return res.json().catch(() => ({}));
  }

  // ── Appliance discovery & status ────────────────────────────────────────

  private async fetchAppliances(): Promise<void> {
    try {
      // Extract userId from token if not already stored
      if (!this.config.userId && this.config.accessToken) {
        this.config.userId = extractUserId(this.config.accessToken);
      }
      const raw = await this.apiGet('/consumerapp/user/devices') as unknown;
      // Defensive: response may be array or { data: [...] } or { devices: [...] }
      let items: Array<Record<string, unknown>>;
      if (Array.isArray(raw)) {
        items = raw;
      } else if (raw && typeof raw === 'object') {
        const obj = raw as Record<string, unknown>;
        items = (Array.isArray(obj.data) ? obj.data :
                 Array.isArray(obj.devices) ? obj.devices : []) as Array<Record<string, unknown>>;
      } else {
        console.error('SubZero: unexpected devices response', JSON.stringify(raw).slice(0, 500));
        items = [];
      }

      const fridges: SubZeroRefrigerator[] = [];
      const ovensArr: WolfOven[] = [];
      const cooktopsArr: WolfCooktop[] = [];

      for (const item of items) {
        const id = String(item.deviceId ?? item.id ?? item.applianceId ?? '');
        const name = String(item.name ?? item.applianceName ?? item.nickname ?? 'Unknown');
        const model = String(item.model ?? item.modelNumber ?? '');
        const online = Boolean(item.online ?? item.isOnline ?? true);
        const category = String(item.category ?? item.applianceCategory ?? item.type ?? '').toLowerCase();
        const props = (item.properties ?? item.status ?? {}) as Record<string, unknown>;
        console.log(`SubZero device '${name}' (${id}): category=${category}, propKeys=${Object.keys(props).sort().join(',')}`);

        // Store device metadata for SignalR property merge
        this.deviceMeta.set(id, { name, model, online, category });

        // Classify by category/type keywords or appliance name
        const nameLower = name.toLowerCase();
        if (category.includes('refriger') || category.includes('freezer') || category.includes('preservation') || category.includes('wine')) {
          fridges.push(this.buildRefrigerator(id, name, model, online, item));
        } else if (category.includes('oven') || category.includes('range') || category.includes('steam')
                   || nameLower.includes('oven') || nameLower.includes('range')) {
          ovensArr.push(this.buildOven(id, name, model, online, item));
        } else if (category.includes('cooktop') || category.includes('induction') || category.includes('rangetop')
                   || nameLower.includes('cooktop')) {
          cooktopsArr.push(this.buildCooktop(id, name, model, online, item));
        } else {
          // Try model number patterns: Sub-Zero models often start with BI, IC, CL, IW; Wolf with SO, DO, DF, IR, CT
          const modelUpper = model.toUpperCase();
          if (/^(BI|IC|CL|IW|DET|IT|ICI|UC|DEU)/.test(modelUpper)) {
            fridges.push(this.buildRefrigerator(id, name, model, online, item));
          } else if (/^(SO|DO|DF|CSO|E|MDD|OG)/.test(modelUpper)) {
            ovensArr.push(this.buildOven(id, name, model, online, item));
          } else if (/^(CT|IR|IC|CG)/.test(modelUpper) && !category.includes('refrig')) {
            cooktopsArr.push(this.buildCooktop(id, name, model, online, item));
          } else {
            // Default to refrigerator if brand is Sub-Zero, oven if Wolf
            const brand = String(item.brand ?? item.applianceBrand ?? '').toLowerCase();
            if (brand.includes('wolf')) {
              ovensArr.push(this.buildOven(id, name, model, online, item));
            } else {
              fridges.push(this.buildRefrigerator(id, name, model, online, item));
            }
          }
        }
      }

      this.refrigerators = fridges;
      this.ovens = ovensArr;
      this.cooktops = cooktopsArr;
      this.emit('stateChange');
    } catch (err) {
      console.error('SubZero: fetchAppliances failed', err);
    }
  }

  /** Derive fridge mode from the boolean state flags (no single mode field). */
  private refrigeratorModeFromProps(props: Record<string, unknown>): RefrigeratorMode {
    if (props.sabbath_on) return 'sabbath';
    if (props.short_vacation_on || props.long_vacation_on) return 'vacation';
    if (props.night_mode) return 'night';
    if (props.mode != null) return parseRefrigeratorMode(props.mode);
    return 'normal';
  }

  /** Seconds remaining on the oven's active kitchen timer, else null. */
  private ovenTimerRemaining(props: Record<string, unknown>): number | null {
    const end = props.kitchen_timer_end_time;
    if (props.kitchen_timer_active && typeof end === 'string') {
      const secs = Math.round((new Date(end).getTime() - Date.now()) / 1000);
      return secs > 0 ? secs : 0;
    }
    return this.numOrNull(props.timerRemaining ?? props.timer_remaining);
  }

  private buildRefrigerator(id: string, name: string, model: string, online: boolean, raw: Record<string, unknown>): SubZeroRefrigerator {
    const props = (raw.properties ?? raw.status ?? {}) as Record<string, unknown>;
    return {
      applianceId: id,
      applianceName: name,
      model,
      online,
      // Sub-Zero fridges report SETPOINTS only over the cloud, not measured temps.
      fridgeTemp: null,
      freezerTemp: null,
      fridgeSetpoint: this.numOrNull(props.ref_set_temp ?? props.fridgeSetpoint ?? props.fridge_setpoint),
      freezerSetpoint: this.numOrNull(props.frz_set_temp ?? props.freezerSetpoint ?? props.freezer_setpoint),
      crisperSetpoint: this.numOrNull(props.crisp_set_temp ?? props.crisperSetpoint ?? props.crisper_setpoint),
      fridgeDoorOpen: Boolean(props.ref_door_ajar ?? props.fridgeDoorOpen ?? props.door_ajar ?? false),
      freezerDoorOpen: Boolean(props.frz_door_ajar ?? props.freezerDoorOpen ?? props.freezer_door_open ?? false),
      iceMakerOn: Boolean(props.ice_maker_on ?? props.iceMakerOn ?? false),
      maxIceOn: Boolean(props.max_ice_on ?? props.maxIceOn ?? false),
      mode: this.refrigeratorModeFromProps(props),
      nightMode: Boolean(props.night_mode ?? props.nightMode ?? false),
      lightOn: this.numOrNull(props.accent_light_level) != null
        ? Number(props.accent_light_level) > 0
        : Boolean(props.light_on ?? props.lightOn ?? false),
      waterFilterPct: this.numOrNull(props.water_filter_pct_remaining ?? props.waterFilterPct),
      airPurificationPct: this.numOrNull(props.air_filter_pct_remaining ?? props.air_purification_pct),
      humidityControl: props.humidity_control != null ? String(props.humidity_control) : null,
      lastUpdated: Date.now(),
    };
  }

  private buildOven(id: string, name: string, model: string, online: boolean, raw: Record<string, unknown>): WolfOven {
    const props = (raw.properties ?? raw.status ?? {}) as Record<string, unknown>;
    return {
      applianceId: id,
      applianceName: name,
      model,
      online,
      // Dual-cavity ovens expose cav_/cav2_ prefixes; we surface the primary
      // cavity here (cav2_* is captured in state but not yet modeled in WolfOven).
      unitOn: Boolean(props.cav_unit_on ?? props.unit_on ?? props.unitOn ?? false),
      currentTemp: this.numOrNull(props.cav_temp ?? props.currentTemp ?? props.oven_current_temp),
      targetTemp: this.numOrNull(props.cav_set_temp ?? props.targetTemp ?? props.oven_target_temp),
      cookMode: (props.cav_cook_mode === 0 || props.cav_cook_mode === '0')
        ? 'off'
        : parseOvenMode(typeof props.cav_cook_mode === 'string' ? props.cav_cook_mode
            : (props.cook_mode ?? props.cookMode ?? 'off')),
      probeTemp: this.numOrNull(props.cav_probe_temp ?? props.probe_temp),
      probeTargetTemp: this.numOrNull(props.cav_probe_set_temp ?? props.probe_target_temp),
      timerRemaining: this.ovenTimerRemaining(props),
      remoteReady: Boolean(props.cav_remote_ready ?? props.remote_ready ?? props.remoteReady ?? false),
      lightOn: Boolean(props.cav_light_on ?? props.light_on ?? props.lightOn ?? false),
      lastUpdated: Date.now(),
    };
  }

  private buildCooktop(id: string, name: string, model: string, online: boolean, raw: Record<string, unknown>): WolfCooktop {
    const props = (raw.properties ?? raw.status ?? {}) as Record<string, unknown>;
    return {
      applianceId: id,
      applianceName: name,
      model,
      online,
      cooktopOn: Boolean(props.cooktopOn ?? props.cooktop_on ?? false),
      lockOn: Boolean(props.lockOn ?? props.cooktop_lock_on ?? false),
      lastUpdated: Date.now(),
    };
  }

  private numOrNull(v: unknown): number | null {
    if (v === null || v === undefined) return null;
    const n = Number(v);
    return Number.isFinite(n) ? n : null;
  }

  // ── Commands ────────────────────────────────────────────────────────────

  // Command protocol (reverse-engineered from the Owner's app v4.6.0 via blutter, live-validated):
  //   POST /consumerapp/device/{deviceId}/directmethod/executeAPICmd
  //   body { req_id: <uuid>, pload: { cmd: "get" } | { cmd: "set", params: {..} } | ... }
  // Response for cmd:get is the flat property snapshot (same shape as a SignalR type-1 pload).
  private async sendDirectMethod(deviceId: string, pload: Record<string, unknown>): Promise<Record<string, unknown>> {
    const doPost = async (token: string): Promise<Response> => {
      const headers: Record<string, string> = {
        'Authorization': `Bearer ${token}`,
        'Ocp-Apim-Subscription-Key': this.subKey,
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'app_version': APP_VERSION,
        'app_platform': 'android',
      };
      if (this.config.userId) headers['userId'] = this.config.userId;
      const body = JSON.stringify({ req_id: crypto.randomUUID(), pload });
      return fetch(`${API_BASE}/consumerapp/device/${deviceId}/directmethod/executeAPICmd`, {
        method: 'POST',
        headers,
        body,
      });
    };

    let res = await doPost(await this.getToken());
    if (res.status === 401) {
      await this.refreshAccessToken();
      if (!this.config.accessToken) throw new Error('SubZero: refresh failed');
      res = await doPost(this.config.accessToken);
    }
    if (!res.ok) {
      const text = await res.text().catch(() => '');
      console.error(`SubZero directmethod ${deviceId}: ${res.status}`, text.slice(0, 300));
      throw new Error(`SubZero directmethod ${deviceId}: ${res.status}`);
    }
    const text = await res.text();
    try { return JSON.parse(text) as Record<string, unknown>; } catch { return {}; }
  }

  /**
   * On-demand full snapshot ({cmd:"get"}) — merges into device state and emits.
   * Closes the cold-start gap: our SignalR connection is receive-only and only
   * gets a full snapshot when someone else triggers one, so we pull one ourselves.
   */
  async refreshSnapshot(deviceId: string): Promise<void> {
    const props = await this.sendDirectMethod(deviceId, { cmd: 'get' });
    if (!props || typeof props !== 'object') return;
    const existing = this.deviceProperties.get(deviceId) ?? {};
    this.deviceProperties.set(deviceId, { ...existing, ...props });
    const meta = this.deviceMeta.get(deviceId);
    const model = (props as Record<string, unknown>).appliance_model;
    if (meta && typeof model === 'string' && model) meta.model = model;
    this.rebuildAppliances();
    this.emit('stateChange');
  }

  /** Pull a fresh snapshot for every known device (used at connect to seed live state). */
  async refreshAllSnapshots(): Promise<void> {
    const ids = [...this.deviceMeta.keys()];
    await Promise.allSettled(ids.map((id) => this.refreshSnapshot(id)));
  }

  /** Write one or more properties ({cmd:"set", params}), then re-read to reflect the change. */
  async setProperty(applianceId: string, propertyName: string, value: unknown): Promise<void> {
    await this.sendDirectMethod(applianceId, { cmd: 'set', params: { [propertyName]: value } });
    await this.refreshSnapshot(applianceId).catch(() => { /* state will also arrive via SignalR delta */ });
  }

  // Property names below are the device's own — confirmed live for the refrigerator;
  // oven/cooktop names follow the cav_* scheme seen in SignalR ploads.
  async setFridgeTemp(applianceId: string, temp: number): Promise<void> {
    await this.setProperty(applianceId, 'ref_set_temp', temp);
  }

  async setFreezerTemp(applianceId: string, temp: number): Promise<void> {
    await this.setProperty(applianceId, 'frz_set_temp', temp);
  }

  async setCrisperTemp(applianceId: string, temp: number): Promise<void> {
    await this.setProperty(applianceId, 'crisp_set_temp', temp);
  }

  async setIceMaker(applianceId: string, on: boolean): Promise<void> {
    await this.setProperty(applianceId, 'ice_maker_on', on);
  }

  async setMaxIce(applianceId: string, on: boolean): Promise<void> {
    await this.setProperty(applianceId, 'max_ice_on', on);
  }

  async setNightMode(applianceId: string, on: boolean): Promise<void> {
    await this.setProperty(applianceId, 'night_mode', on ? 1 : 0);
  }

  async setHumidityControl(applianceId: string, level: number): Promise<void> {
    await this.setProperty(applianceId, 'humidity_control', level);
  }

  async toggleLight(applianceId: string, on: boolean): Promise<void> {
    await this.setProperty(applianceId, 'light_on', on);
  }

  async toggleOvenLight(applianceId: string, on: boolean): Promise<void> {
    await this.setProperty(applianceId, 'cav_light_on', on);
  }

  // ── Polling ─────────────────────────────────────────────────────────────

  // ── Endpoint probe (discover actual APIM paths) ─────────────────────

  async probeEndpoints(): Promise<string[]> {
    const log: string[] = [];
    const token = await this.getToken();
    const uid = this.config.userId;

    const tryReq = async (method: string, path: string, key: string, body?: unknown): Promise<{ status: number; body: string }> => {
      const headers: Record<string, string> = {
        'Authorization': `Bearer ${token}`,
        'Ocp-Apim-Subscription-Key': key,
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      };
      if (uid) headers['userId'] = uid;
      const opts: RequestInit = { method, headers };
      if (body) opts.body = JSON.stringify(body);
      try {
        const res = await fetch(`${API_BASE}${path}`, opts);
        const text = await res.text().catch(() => '');
        return { status: res.status, body: text.slice(0, 300) };
      } catch (err) {
        return { status: 0, body: `ERR: ${(err as Error).message}` };
      }
    };

    // SignalR negotiate path variations
    const signalrPaths = [
      '/api-signalr/negotiateUser',
      '/api-signalr/negotiate',
      '/api-signalr',
      '/signalr/negotiate',
      '/signalr/negotiateUser',
      '/api/signalr/negotiate',
      '/api/signalr/negotiateUser',
      '/negotiate',
      '/negotiateUser',
      '/api/negotiate',
      '/api/negotiateUser',
      '/api-signalr/client/negotiate',
      '/consumerapp/signalr/negotiate',
    ];

    const emit = (msg: string) => { log.push(msg); console.log(msg); };

    emit('SubZero: ═══ ENDPOINT PROBE: SignalR negotiate ═══');
    for (const path of signalrPaths) {
      const r = await tryReq('POST', path, ALL_SUB_KEYS[0]);
      if (r.status !== 404) {
        emit(`  ⚠️  POST ${path} => ${r.status} ${r.body.slice(0, 150)}`);
        if (r.status !== 200) {
          for (const key of ALL_SUB_KEYS.slice(1)) {
            const r2 = await tryReq('POST', path, key);
            if (r2.status !== 404) {
              emit(`      key ${key.slice(0, 8)}... => ${r2.status} ${r2.body.slice(0, 100)}`);
            }
          }
        }
      } else {
        emit(`     POST ${path} => 404`);
      }
    }

    // Also try GET on main negotiate paths
    for (const path of ['/api-signalr/negotiateUser', '/api-signalr/negotiate', '/negotiate']) {
      const r = await tryReq('GET', path, ALL_SUB_KEYS[0]);
      if (r.status !== 404) {
        emit(`  ⚠️  GET  ${path} => ${r.status} ${r.body.slice(0, 150)}`);
      }
    }

    // Direct method path variations
    const firstDeviceId = Array.from(this.deviceMeta.keys())[0] ?? '';
    const cmdBody = firstDeviceId ? {
      deviceId: firstDeviceId,
      commandName: 'getProperty',
      commandPayload: { propertyName: 'unit_on' },
    } : {};

    const directMethodPaths = [
      '/directmethod/executeAPICmd',
      '/api/directmethod/executeAPICmd',
      '/api-directmethod/executeAPICmd',
      '/api-iot/directmethod/executeAPICmd',
      '/iot/directmethod/executeAPICmd',
      '/directmethod',
      '/api-directmethod',
      '/commands/executeAPICmd',
      '/consumerapp/directmethod/executeAPICmd',
      '/api/commands/execute',
      '/api/device/command',
      '/api/appliance/command',
      '/api/device/setProperty',
    ];

    emit('SubZero: ═══ ENDPOINT PROBE: Direct Method ═══');
    for (const path of directMethodPaths) {
      const r = await tryReq('POST', path, ALL_SUB_KEYS[0], cmdBody);
      if (r.status !== 404) {
        emit(`  ⚠️  POST ${path} => ${r.status} ${r.body.slice(0, 150)}`);
        for (const key of ALL_SUB_KEYS.slice(1)) {
          const r2 = await tryReq('POST', path, key, cmdBody);
          if (r2.status !== 404) {
            emit(`      key ${key.slice(0, 8)}... => ${r2.status} ${r2.body.slice(0, 100)}`);
          }
        }
      } else {
        emit(`     POST ${path} => 404`);
      }
    }

    // OPTIONS/HEAD on base paths to detect valid API prefixes
    emit('SubZero: ═══ ENDPOINT PROBE: Base path detection ═══');
    for (const bp of ['/api-signalr', '/directmethod', '/api-directmethod', '/api-iot', '/signalr', '/api']) {
      for (const m of ['OPTIONS', 'GET'] as const) {
        const r = await tryReq(m, bp, ALL_SUB_KEYS[0]);
        if (r.status !== 404) {
          emit(`  ⚠️  ${m.padEnd(7)} ${bp} => ${r.status} ${r.body.slice(0, 100)}`);
        }
      }
    }

    emit('SubZero: ═══ ENDPOINT PROBE complete ═══');
    return log;
  }

  // ── SignalR real-time connection ──────────────────────────────────────

  private async connectSignalR(): Promise<void> {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) return;

    const token = await this.getToken();
    const uid = this.config.userId ?? '';

    // Negotiate: POST /signal-r/negotiateUser (hyphenated) with the SignalR
    // product key → { url, accessToken } for the Azure SignalR service.
    let negData: { url?: string; accessToken?: string };
    try {
      const res = await fetch(`${API_BASE}/signal-r/negotiateUser`, {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${token}`,
          'Ocp-Apim-Subscription-Key': SIGNALR_SUB_KEY,
          'Content-Type': 'application/json',
          'userId': uid,
        },
        body: '{}',
      });
      if (!res.ok) {
        console.error('SubZero SignalR: negotiate failed', res.status, (await res.text()).slice(0, 150));
        return;
      }
      negData = await res.json() as { url?: string; accessToken?: string };
    } catch (err) {
      console.error('SubZero SignalR: negotiate error', err);
      return;
    }

    if (!negData.url || !negData.accessToken) {
      console.error('SubZero SignalR: negotiate response missing url/accessToken');
      return;
    }

    const wsUrl = negData.url.replace(/^http/, 'ws') + `&access_token=${encodeURIComponent(negData.accessToken)}`;
    const ws = new WebSocket(wsUrl);
    let handshaken = false;

    ws.addEventListener('open', () => {
      ws.send(JSON.stringify({ protocol: 'json', version: 1 }) + RS);
    });

    ws.addEventListener('message', (ev: MessageEvent) => {
      const raw = typeof ev.data === 'string' ? ev.data : Buffer.from(ev.data as ArrayBuffer).toString('utf8');
      for (const part of raw.split(RS)) {
        if (!part) continue;
        let m: Record<string, unknown>;
        try { m = JSON.parse(part) as Record<string, unknown>; } catch { continue; }
        if (!handshaken) {
          handshaken = true;
          if (m.error) {
            console.error('SubZero SignalR: handshake error', m.error);
          } else {
            console.log('SubZero SignalR: connected to connectedappliances hub');
            // Receive-only connection won't get an initial snapshot until someone
            // else triggers one — pull a full snapshot for every device now.
            void this.refreshAllSnapshots();
          }
          continue;
        }
        if (m.type === 6) { ws.send(JSON.stringify({ type: 6 }) + RS); continue; } // ping → pong
        if (m.type === 1 && m.target === 'ConnectedApplianceMessage' && Array.isArray(m.arguments)) {
          this.handleApplianceMessage(m.arguments[0]);
        }
      }
    });

    ws.addEventListener('error', (ev: Event) => {
      console.error('SubZero SignalR: ws error', (ev as ErrorEvent).message ?? '');
    });

    ws.addEventListener('close', () => {
      this.ws = null;
      // Auto-reconnect while linked (negotiate token is short-lived, so re-negotiate).
      if (this.config.enabled && !this.wsReconnectTimer) {
        this.wsReconnectTimer = setTimeout(() => {
          this.wsReconnectTimer = null;
          void this.connectSignalR();
        }, 5000);
      }
    });

    this.ws = ws;
  }

  /**
   * Handle a ConnectedApplianceMessage hub push. The payload is triple-nested
   * JSON: arg string → { DeviceId, Payload } → Payload string → { "api.async_channel" }
   * → channel string → { type, pload }. type 1 = full snapshot, type 2 = delta.
   */
  private handleApplianceMessage(argStr: unknown): void {
    if (typeof argStr !== 'string') return;
    try {
      const env = JSON.parse(argStr) as { DeviceId?: string; Payload?: string };
      const deviceId = String(env.DeviceId ?? '');
      if (!deviceId || typeof env.Payload !== 'string') return;

      const payload = JSON.parse(env.Payload) as Record<string, unknown>;
      const chanStr = payload['api.async_channel'];
      if (typeof chanStr !== 'string') return;
      const chan = JSON.parse(chanStr) as { type?: number; pload?: Record<string, unknown> };
      const pload = chan.pload ?? {};

      let props: Record<string, unknown>;
      if (chan.type === 1) {
        props = pload; // full snapshot
      } else if (chan.type === 2) {
        props = (pload.props as Record<string, unknown>) ?? {}; // delta
      } else {
        return;
      }

      const existing = this.deviceProperties.get(deviceId) ?? {};
      this.deviceProperties.set(deviceId, { ...existing, ...props });

      // A full snapshot carries model/serial — enrich metadata for classification.
      if (chan.type === 1) {
        const meta = this.deviceMeta.get(deviceId);
        if (meta && typeof pload.appliance_model === 'string' && pload.appliance_model) {
          meta.model = pload.appliance_model;
        }
      }

      this.rebuildAppliances();
      this.emit('stateChange');
    } catch {
      /* malformed message — ignore */
    }
  }

  private async disconnectSignalR(): Promise<void> {
    if (this.wsReconnectTimer) { clearTimeout(this.wsReconnectTimer); this.wsReconnectTimer = null; }
    if (this.ws) {
      try { this.ws.close(); } catch { /* noop */ }
      this.ws = null;
    }
  }

  /** Rebuild appliance objects from device metadata + SignalR property state */
  private rebuildAppliances(): void {
    const fridges: SubZeroRefrigerator[] = [];
    const ovensArr: WolfOven[] = [];

    for (const [id, meta] of this.deviceMeta) {
      const props = this.deviceProperties.get(id) ?? {};
      const raw = { properties: props } as Record<string, unknown>;
      const nameLower = meta.name.toLowerCase();
      const cat = meta.category;

      if (cat.includes('refriger') || cat.includes('freezer') || cat.includes('wine')
          || cat.includes('preservation') || cat.includes('beverage')) {
        fridges.push(this.buildRefrigerator(id, meta.name, meta.model, meta.online, raw));
      } else if (cat.includes('oven') || cat.includes('range') || cat.includes('steam')
                 || nameLower.includes('oven') || nameLower.includes('range')) {
        ovensArr.push(this.buildOven(id, meta.name, meta.model, meta.online, raw));
      } else {
        // Default classification by name
        if (nameLower.includes('oven') || nameLower.includes('range') || nameLower.includes('cooktop')) {
          ovensArr.push(this.buildOven(id, meta.name, meta.model, meta.online, raw));
        } else {
          fridges.push(this.buildRefrigerator(id, meta.name, meta.model, meta.online, raw));
        }
      }
    }

    this.refrigerators = fridges;
    this.ovens = ovensArr;
  }

  // ── Polling ─────────────────────────────────────────────────────────────

  start(): void {
    this.stop();
    void this.fetchAppliances().then(() => this.connectSignalR());
    this.pollTimer = setInterval(() => void this.fetchAppliances(), POLL_INTERVAL);
  }

  stop(): void {
    if (this.pollTimer) {
      clearInterval(this.pollTimer);
      this.pollTimer = null;
    }
    void this.disconnectSignalR();
  }
}
