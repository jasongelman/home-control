import { EventEmitter } from 'events';
import type { MyUplinkConfig, HeatPumpStatus, HeatPumpMode } from './types.js';

const BASE = 'https://api.myuplink.com';
const TOKEN_URL = `${BASE}/oauth/token`;
const AUTH_URL = `${BASE}/oauth/authorize`;
const SCOPE = 'READSYSTEM offline_access';
const POLL_INTERVAL = 60_000;

// Celsius to Fahrenheit
function cToF(c: number): number {
  return Math.round((c * 9) / 5 + 32);
}

// myUplink returns values in raw units (often 10× for temps)
function parsePoint(raw: number, factor = 10): number {
  return raw / factor;
}

// Nibe/myUplink parameter IDs
const PARAM = {
  OUTDOOR_TEMP: '40004',     // BT1 outdoor temp (×10 °C)
  SUPPLY_TEMP: '40008',      // BT2 supply/flow temp (×10 °C)
  RETURN_TEMP: '40012',      // BT3 return temp (×10 °C)
  SETPOINT: '43086',         // Heating setpoint (×10 °C)
  COMPRESSOR_FREQ: '43158',  // Compressor frequency (×10 Hz)
  PRIORITY: '49994',         // Priority: 20=off, 30=heat water, 40=heating, 50=cooling
};

function priorityToMode(val: number): HeatPumpMode {
  if (val === 20) return 'off';
  if (val === 30 || val === 40) return 'heating';
  if (val === 50) return 'cooling';
  return 'auto';
}

export class MyUplinkManager extends EventEmitter {
  private config: MyUplinkConfig;
  private heatPumps: HeatPumpStatus[] = [];
  private pollTimer: ReturnType<typeof setInterval> | null = null;

  constructor(config: MyUplinkConfig) {
    super();
    this.config = config;
  }

  get isLinked(): boolean {
    return !!(this.config.accessToken && this.config.enabled);
  }

  getHeatPumps(): HeatPumpStatus[] {
    return this.heatPumps;
  }

  updateConfig(cfg: MyUplinkConfig): void {
    this.config = cfg;
    if (cfg.enabled && cfg.accessToken) {
      this.start();
    } else {
      this.stop();
    }
  }

  getAuthUrl(redirectBase: string): string {
    const params = new URLSearchParams({
      client_id: this.config.clientId,
      redirect_uri: `${redirectBase}/api/myuplink/oauth/callback`,
      response_type: 'code',
      scope: SCOPE,
    });
    return `${AUTH_URL}?${params}`;
  }

  async handleCallback(code: string, redirectBase: string): Promise<void> {
    const body = new URLSearchParams({
      grant_type: 'authorization_code',
      client_id: this.config.clientId,
      client_secret: this.config.clientSecret,
      redirect_uri: `${redirectBase}/api/myuplink/oauth/callback`,
      code,
    });

    const res = await fetch(TOKEN_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: body.toString(),
    });

    if (!res.ok) throw new Error(`myUplink token exchange failed: ${res.status}`);
    const json = await res.json() as Record<string, unknown>;

    this.config.accessToken = json.access_token as string;
    this.config.refreshToken = json.refresh_token as string;
    this.config.tokenExpiresAt = Date.now() + ((json.expires_in as number ?? 3600) - 60) * 1000;
    this.config.enabled = true;

    this.emit('configChanged', this.config);
    await this.fetchSystems();
    this.start();
  }

  unlink(): void {
    this.stop();
    this.config.accessToken = undefined;
    this.config.refreshToken = undefined;
    this.config.tokenExpiresAt = undefined;
    this.config.enabled = false;
    this.heatPumps = [];
    this.emit('configChanged', this.config);
    this.emit('stateChange', []);
  }

  start(): void {
    if (this.pollTimer) return;
    void this.poll();
    this.pollTimer = setInterval(() => { void this.poll(); }, POLL_INTERVAL);
  }

  stop(): void {
    if (this.pollTimer) { clearInterval(this.pollTimer); this.pollTimer = null; }
  }

  private async getToken(): Promise<string> {
    if (!this.config.accessToken) throw new Error('Not linked');
    if (this.config.tokenExpiresAt && Date.now() > this.config.tokenExpiresAt) {
      await this.refresh();
    }
    return this.config.accessToken!;
  }

  private async refresh(): Promise<void> {
    if (!this.config.refreshToken) throw new Error('No refresh token');
    const body = new URLSearchParams({
      grant_type: 'refresh_token',
      client_id: this.config.clientId,
      client_secret: this.config.clientSecret,
      refresh_token: this.config.refreshToken,
    });
    const res = await fetch(TOKEN_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: body.toString(),
    });
    if (!res.ok) { this.config.accessToken = undefined; throw new Error('myUplink refresh failed'); }
    const json = await res.json() as Record<string, unknown>;
    this.config.accessToken = json.access_token as string;
    if (json.refresh_token) this.config.refreshToken = json.refresh_token as string;
    this.config.tokenExpiresAt = Date.now() + ((json.expires_in as number ?? 3600) - 60) * 1000;
    this.emit('configChanged', this.config);
  }

  private async apiGet(path: string): Promise<unknown> {
    const token = await this.getToken();
    const res = await fetch(`${BASE}${path}`, {
      headers: { Authorization: `Bearer ${token}`, Accept: 'application/json' },
    });
    if (!res.ok) throw new Error(`myUplink API ${path}: ${res.status}`);
    return res.json();
  }

  private async fetchSystems(): Promise<void> {
    const json = await this.apiGet('/v2/systems/me') as Record<string, unknown>;
    const systems = (json.systems as Record<string, unknown>[]) ?? [];

    const found: HeatPumpStatus[] = [];
    for (const system of systems) {
      const systemId = system.systemId as string;
      const devices = (system.devices as Record<string, unknown>[]) ?? [];
      for (const device of devices) {
        const deviceId = device.id as string;
        found.push({
          systemId,
          deviceId,
          deviceName: (device.product as Record<string, unknown>)?.name as string ?? 'Heat Pump',
          connected: (device.connectionState as string) === 'Connected',
          outdoorTemp: null,
          supplyTemp: null,
          returnTemp: null,
          setpointTemp: null,
          mode: 'unknown',
          compressorFreq: null,
          lastUpdated: Date.now(),
        });
      }
    }
    this.heatPumps = found;
    await Promise.all(this.heatPumps.map((_, i) => this.fetchPoints(i)));
  }

  private async fetchPoints(idx: number): Promise<void> {
    const hp = this.heatPumps[idx];
    if (!hp?.deviceId) return;

    try {
      const paramIds = Object.values(PARAM).join(',');
      const json = await this.apiGet(`/v2/devices/${hp.deviceId}/points?parameters=${paramIds}`) as Record<string, unknown>;
      const points: Record<string, unknown>[] = Array.isArray(json)
        ? json as Record<string, unknown>[]
        : ((json as Record<string, unknown>).parameterValues as Record<string, unknown>[]) ?? [];

      const updated = { ...hp, lastUpdated: Date.now() };
      for (const pt of points) {
        const pid = String(pt.parameterId ?? pt.parameterName ?? '');
        const raw = pt.value as number ?? 0;
        switch (pid) {
          case PARAM.OUTDOOR_TEMP:   updated.outdoorTemp = cToF(parsePoint(raw)); break;
          case PARAM.SUPPLY_TEMP:    updated.supplyTemp = cToF(parsePoint(raw)); break;
          case PARAM.RETURN_TEMP:    updated.returnTemp = cToF(parsePoint(raw)); break;
          case PARAM.SETPOINT:       updated.setpointTemp = cToF(parsePoint(raw)); break;
          case PARAM.COMPRESSOR_FREQ: updated.compressorFreq = parsePoint(raw); break;
          case PARAM.PRIORITY:       updated.mode = priorityToMode(raw) as HeatPumpMode; break;
        }
      }
      this.heatPumps[idx] = updated;
    } catch (err) {
      console.error('myUplink fetchPoints error:', (err as Error).message);
    }
  }

  private async poll(): Promise<void> {
    if (!this.isLinked) return;
    try {
      if (this.heatPumps.length === 0) await this.fetchSystems();
      else await Promise.all(this.heatPumps.map((_, i) => this.fetchPoints(i)));
      this.emit('stateChange', this.getHeatPumps());
    } catch (err) {
      console.error('myUplink poll error:', (err as Error).message);
    }
  }
}
