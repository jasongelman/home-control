import { EventEmitter } from 'events';
import type { HomeConnectConfig, DishwasherStatus, DishwasherOpState } from './types.js';

const BASE = 'https://api.home-connect.com';
const TOKEN_URL = `${BASE}/security/oauth/token`;
const AUTH_URL = `${BASE}/security/oauth/authorize`;
const SCOPE = 'IdentifyAppliance Dishwasher';
const POLL_INTERVAL = 60_000;

const OP_STATE_MAP: Record<string, DishwasherOpState> = {
  Inactive: 'inactive', Ready: 'ready', DelayedStart: 'delayedStart',
  Run: 'run', Pause: 'pause', ActionRequired: 'actionRequired',
  Finished: 'finished', Error: 'error', Aborting: 'aborting',
};

function programDisplayName(key: string): string {
  const parts = key.split('.');
  const last = parts[parts.length - 1] ?? key;
  // Insert space before uppercase letters and before trailing digits
  return last
    .replace(/([a-z])([A-Z])/g, '$1 $2')
    .replace(/([A-Za-z])(\d)/g, '$1 $2');
}

export class HomeConnectManager extends EventEmitter {
  private config: HomeConnectConfig;
  private dishwashers: DishwasherStatus[] = [];
  private pollTimer: ReturnType<typeof setInterval> | null = null;

  constructor(config: HomeConnectConfig) {
    super();
    this.config = config;
  }

  get isLinked(): boolean {
    return !!(this.config.accessToken && this.config.enabled);
  }

  getDishwashers(): DishwasherStatus[] {
    return this.dishwashers;
  }

  updateConfig(cfg: HomeConnectConfig): void {
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
      redirect_uri: `${redirectBase}/api/homeconnect/oauth/callback`,
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
      redirect_uri: `${redirectBase}/api/homeconnect/oauth/callback`,
      code,
    });

    const res = await fetch(TOKEN_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: body.toString(),
    });

    if (!res.ok) throw new Error(`Token exchange failed: ${res.status}`);
    const json = await res.json() as Record<string, unknown>;

    this.config.accessToken = json.access_token as string;
    this.config.refreshToken = json.refresh_token as string;
    this.config.tokenExpiresAt = Date.now() + ((json.expires_in as number ?? 86400) - 60) * 1000;
    this.config.enabled = true;

    this.emit('configChanged', this.config);
    await this.fetchAppliances();
    this.start();
  }

  unlink(): void {
    this.stop();
    this.config.accessToken = undefined;
    this.config.refreshToken = undefined;
    this.config.tokenExpiresAt = undefined;
    this.config.enabled = false;
    this.dishwashers = [];
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
    if (!res.ok) { this.config.accessToken = undefined; throw new Error('Refresh failed'); }
    const json = await res.json() as Record<string, unknown>;
    this.config.accessToken = json.access_token as string;
    if (json.refresh_token) this.config.refreshToken = json.refresh_token as string;
    this.config.tokenExpiresAt = Date.now() + ((json.expires_in as number ?? 86400) - 60) * 1000;
    this.emit('configChanged', this.config);
  }

  private async apiGet(path: string): Promise<unknown> {
    const token = await this.getToken();
    const res = await fetch(`${BASE}${path}`, {
      headers: { Authorization: `Bearer ${token}`, Accept: 'application/vnd.bsh.sdk.v1+json' },
    });
    if (!res.ok) throw new Error(`HC API ${path}: ${res.status}`);
    return res.json();
  }

  private async fetchAppliances(): Promise<void> {
    const json = await this.apiGet('/api/homeappliances') as Record<string, unknown>;
    const items = ((json.data as Record<string, unknown>)?.homeappliances as Record<string, unknown>[]) ?? [];

    const found: DishwasherStatus[] = [];
    for (const item of items) {
      if ((item.type as string) !== 'Dishwasher') continue;
      const haId = item.haId as string;
      const existing = this.dishwashers.find((d) => d.applianceId === haId);
      found.push(existing
        ? { ...existing, applianceName: item.name as string, connected: item.connected as boolean }
        : { applianceId: haId, applianceName: item.name as string ?? 'Dishwasher', connected: item.connected as boolean ?? false, operationState: 'unknown', doorState: 'unknown', remoteControlActive: false, remainingTime: null, progress: null, activeProgram: null, lastUpdated: Date.now() }
      );
    }
    this.dishwashers = found;
    await Promise.all(this.dishwashers.map((_, i) => this.fetchStatus(i)));
  }

  private async fetchStatus(idx: number): Promise<void> {
    const dw = this.dishwashers[idx];
    if (!dw?.applianceId) return;

    try {
      const statusJson = await this.apiGet(`/api/homeappliances/${dw.applianceId}/status`) as Record<string, unknown>;
      const items = ((statusJson.data as Record<string, unknown>)?.status as Record<string, unknown>[]) ?? [];
      const updated = { ...dw, lastUpdated: Date.now() };
      for (const item of items) {
        const key = item.key as string;
        const val = item.value as string;
        if (key === 'BSH.Common.Status.OperationState') {
          const suffix = val.split('.').pop() ?? '';
          updated.operationState = OP_STATE_MAP[suffix] ?? 'unknown';
        } else if (key === 'BSH.Common.Status.DoorState') {
          const suffix = val.split('.').pop()?.toLowerCase() ?? 'unknown';
          updated.doorState = (suffix as DishwasherStatus['doorState']);
        } else if (key === 'BSH.Common.Status.RemoteControlActive') {
          updated.remoteControlActive = item.value as boolean;
        }
      }

      const isActive = ['run', 'delayedStart', 'pause', 'actionRequired'].includes(updated.operationState);
      if (isActive) {
        try {
          const progJson = await this.apiGet(`/api/homeappliances/${dw.applianceId}/programs/active`) as Record<string, unknown>;
          const data = progJson.data as Record<string, unknown>;
          updated.activeProgram = programDisplayName(data.key as string ?? '');
          const opts = (data.options as Record<string, unknown>[]) ?? [];
          for (const opt of opts) {
            if (opt.key === 'BSH.Common.Option.RemainingProgramTime') updated.remainingTime = opt.value as number;
            if (opt.key === 'BSH.Common.Option.ProgramProgress') updated.progress = opt.value as number;
          }
        } catch { /* no active program */ }
      } else {
        updated.activeProgram = null;
        updated.remainingTime = null;
        updated.progress = null;
      }

      this.dishwashers[idx] = updated;
    } catch (err) {
      console.error('HomeConnect fetchStatus error:', (err as Error).message);
    }
  }

  private async poll(): Promise<void> {
    if (!this.isLinked) return;
    try {
      if (this.dishwashers.length === 0) await this.fetchAppliances();
      else await Promise.all(this.dishwashers.map((_, i) => this.fetchStatus(i)));
      this.emit('stateChange', this.getDishwashers());
    } catch (err) {
      console.error('HomeConnect poll error:', (err as Error).message);
    }
  }
}
