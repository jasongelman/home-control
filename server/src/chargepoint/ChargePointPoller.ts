import { EventEmitter } from 'events';
import type { ChargePointCharger, ChargePointConfig, ChargePointSession } from './types.js';
import { login, getHomeChargers, setAmperage, getSessionHistory, type ChargePointSessionInfo } from './ChargePointClient.js';

const POLL_INTERVAL = 180_000; // 3 minutes
const TOKEN_TTL = 20 * 60 * 1000; // 20 minutes

interface AccountSession {
  session: ChargePointSessionInfo;
  expiry: number;
}

export class ChargePointPoller extends EventEmitter {
  private config: ChargePointConfig;
  private accountSessions: Map<number, AccountSession> = new Map();
  private chargers: Map<string, ChargePointCharger> = new Map();
  private pollTimer: ReturnType<typeof setInterval> | null = null;
  private _connected = false;

  constructor(config: ChargePointConfig) {
    super();
    this.config = config;
  }

  get isConnected(): boolean {
    return this._connected;
  }

  getChargers(): ChargePointCharger[] {
    return Array.from(this.chargers.values());
  }

  updateConfig(config: ChargePointConfig): void {
    this.config = config;
    this.accountSessions.clear();

    const hasValidAccounts = config.enabled && config.accounts.some(
      (a) => a.email && a.password,
    );

    if (hasValidAccounts) {
      if (!this.pollTimer) this.start();
      else void this.poll();
    } else {
      this.stop();
    }
  }

  start(): void {
    if (this.pollTimer) return;
    void this.poll();
    this.pollTimer = setInterval(() => { void this.poll(); }, POLL_INTERVAL);
  }

  stop(): void {
    if (this.pollTimer) {
      clearInterval(this.pollTimer);
      this.pollTimer = null;
    }
    this.accountSessions.clear();
    this._connected = false;
    this.chargers.clear();
  }

  async triggerSetAmperage(chargerId: string, amps: number): Promise<void> {
    const charger = this.chargers.get(chargerId);
    if (!charger) throw new Error(`Unknown charger: ${chargerId}`);

    const session = await this.getAccountSession(charger.accountIndex);
    await setAmperage(session, chargerId, amps);

    // Optimistic update
    this.chargers.set(chargerId, { ...charger, amperage: amps, lastUpdated: Date.now() });
    this.emit('stateChange', this.getChargers());
  }

  async getHistory(chargerId: string): Promise<ChargePointSession[]> {
    const charger = this.chargers.get(chargerId);
    if (!charger) throw new Error(`Unknown charger: ${chargerId}`);

    const session = await this.getAccountSession(charger.accountIndex);
    return getSessionHistory(session, chargerId);
  }

  private async getAccountSession(accountIndex: number): Promise<ChargePointSessionInfo> {
    const cached = this.accountSessions.get(accountIndex);
    if (cached && Date.now() < cached.expiry) return cached.session;

    const account = this.config.accounts[accountIndex];
    if (!account) throw new Error(`No account at index ${accountIndex}`);

    const session = await login(account.email, account.password);
    this.accountSessions.set(accountIndex, {
      session,
      expiry: Date.now() + TOKEN_TTL,
    });
    return session;
  }

  private async poll(): Promise<void> {
    if (!this.config.enabled) return;

    const validAccounts = this.config.accounts.filter((a) => a.email && a.password);
    if (validAccounts.length === 0) return;

    try {
      const allChargers: ChargePointCharger[] = [];

      for (let i = 0; i < this.config.accounts.length; i++) {
        const account = this.config.accounts[i];
        if (!account.email || !account.password) continue;

        try {
          const session = await this.getAccountSession(i);
          const chargers = await getHomeChargers(session, i, account.nickname);
          allChargers.push(...chargers);
        } catch (err) {
          // Invalidate session on auth errors
          this.accountSessions.delete(i);
          console.error(`ChargePoint account ${i} (${account.email}) poll error:`, (err as Error).message);
        }
      }

      let changed = false;
      for (const charger of allChargers) {
        const prev = this.chargers.get(charger.chargerId);
        if (!prev || prev.status !== charger.status || prev.amperage !== charger.amperage ||
            prev.powerKw !== charger.powerKw || prev.energyKwh !== charger.energyKwh) {
          changed = true;
        }
        this.chargers.set(charger.chargerId, charger);
      }

      if (!this._connected) {
        this._connected = true;
        this.emit('connected');
        this.emit('stateChange', this.getChargers());
      } else if (changed) {
        this.emit('stateChange', this.getChargers());
      }
    } catch (err) {
      const wasConnected = this._connected;
      this._connected = false;
      this.accountSessions.clear();
      if (wasConnected) this.emit('disconnected', (err as Error).message);
      this.emit('error', err as Error);
      console.error('ChargePoint poll error:', (err as Error).message);
    }
  }
}
