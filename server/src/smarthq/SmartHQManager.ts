import { EventEmitter } from 'events';
import type { SmartHQConfig, LaundryAppliance, LaundryMachineState } from './types.js';

const AUTH_URL = 'https://accounts.brillion.geappliances.com/oauth2/token';
const API_BASE = 'https://api.brillion.geappliances.com';
const CLIENT_ID = '564c31616c4f7768536a514b';
const POLL_INTERVAL = 30_000;

// Machine state int → label
const STATE_MAP: Record<number, LaundryMachineState> = {
  0: 'off', 1: 'standby', 2: 'running', 3: 'paused',
  4: 'complete', 5: 'delayed', 6: 'delayed', 7: 'delayed', 8: 'error',
};

function parseHex(val: string): number {
  return parseInt(val.replace('0x', ''), 16);
}

export class SmartHQManager extends EventEmitter {
  private config: SmartHQConfig;
  private appliances: LaundryAppliance[] = [];
  private pollTimer: ReturnType<typeof setInterval> | null = null;

  constructor(config: SmartHQConfig) {
    super();
    this.config = config;
  }

  get isLinked(): boolean {
    return !!(this.config.accessToken && this.config.enabled);
  }

  getAppliances(): LaundryAppliance[] {
    return this.appliances;
  }

  updateConfig(cfg: SmartHQConfig): void {
    this.config = cfg;
    if (cfg.enabled && cfg.accessToken) {
      this.start();
    } else if (cfg.enabled && cfg.email && cfg.password) {
      void this.login();
    } else {
      this.stop();
    }
  }

  unlink(): void {
    this.stop();
    this.config.accessToken = undefined;
    this.config.refreshToken = undefined;
    this.config.enabled = false;
    this.appliances = [];
    this.emit('configChanged', this.config);
    this.emit('stateChange', []);
  }

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

  private async apiGet(path: string): Promise<unknown> {
    const token = await this.getToken();
    const res = await fetch(`${API_BASE}${path}`, {
      headers: { Authorization: `Bearer ${token}`, Accept: 'application/json' },
    });
    if (!res.ok) throw new Error(`SmartHQ API ${path}: ${res.status}`);
    return res.json();
  }

  private async fetchAppliances(): Promise<void> {
    const json = await this.apiGet('/v1/appliance');
    const items: Record<string, unknown>[] = Array.isArray(json)
      ? json as Record<string, unknown>[]
      : (((json as Record<string, unknown>).items as Record<string, unknown>[]) ?? []);

    this.appliances = items
      .filter((item) => {
        const type = ((item.type as string) ?? '').toLowerCase();
        return type.includes('washer') || type.includes('dryer');
      })
      .map((item) => ({
        applianceId: (item.jid ?? item.applianceId ?? item.id) as string,
        applianceName: (item.name ?? item.nickname ?? 'Appliance') as string,
        applianceType: ((item.type as string) ?? '').toLowerCase().includes('washer') ? 'Washer' : 'Dryer',
        online: !!(item.online ?? item.connected),
        machineState: 'off',
        remainingMinutes: null,
        cycleName: null,
        doorLocked: false,
        soilLevel: null, washTemp: null, spinSpeed: null,
        dryLevel: null, dryTemp: null,
        lastUpdated: Date.now(),
      }));

    await Promise.all(this.appliances.map((_, i) => this.fetchERDs(i)));
  }

  private async fetchERDs(idx: number): Promise<void> {
    const app = this.appliances[idx];
    if (!app?.applianceId) return;
    try {
      const json = await this.apiGet(`/v1/appliance/${app.applianceId}/erd`) as Record<string, unknown>;
      const items: Record<string, unknown>[] = Array.isArray(json)
        ? json as Record<string, unknown>[]
        : (((json as Record<string, unknown>).items as Record<string, unknown>[]) ?? []);

      const updated = { ...app, lastUpdated: Date.now() };
      for (const item of items) {
        const erd = (item.erd as string ?? '').toLowerCase();
        const val = item.value as string ?? '';
        switch (erd) {
          case '0x2000': updated.machineState = STATE_MAP[parseHex(val)] ?? 'off'; break;
          case '0x2007': { const m = parseHex(val); updated.remainingMinutes = m > 0 ? m : null; break; }
          case '0x200a': updated.doorLocked = parseHex(val) !== 0; break;
          case '0x2003': updated.cycleName = val || null; break;
          case '0x2010': updated.soilLevel = val || null; break;
          case '0x2011': updated.washTemp = val || null; break;
          case '0x2012': updated.spinSpeed = val || null; break;
          case '0x2013': updated.dryLevel = val || null; break;
          case '0x2014': updated.dryTemp = val || null; break;
        }
      }
      this.appliances[idx] = updated;
    } catch (err) {
      console.error('SmartHQ ERD fetch error:', (err as Error).message);
    }
  }

  start(): void {
    if (this.pollTimer) return;
    void this.poll();
    this.pollTimer = setInterval(() => { void this.poll(); }, POLL_INTERVAL);
  }

  stop(): void {
    if (this.pollTimer) { clearInterval(this.pollTimer); this.pollTimer = null; }
  }

  private async poll(): Promise<void> {
    if (!this.isLinked) return;
    try {
      if (this.appliances.length === 0) await this.fetchAppliances();
      else await Promise.all(this.appliances.map((_, i) => this.fetchERDs(i)));
      this.emit('stateChange', this.getAppliances());
    } catch (err) {
      console.error('SmartHQ poll error:', (err as Error).message);
    }
  }
}
