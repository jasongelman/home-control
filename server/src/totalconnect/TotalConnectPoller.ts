import { EventEmitter } from 'events';
import type { TotalConnectConfig, AlarmPanel, AlarmZone } from './types.js';
import {
  authenticate,
  getPanelStatus,
  arm,
  disarm,
  mapArmingState,
  type TCSession,
} from './TotalConnectClient.js';
import { ArmType } from './types.js';

const POLL_INTERVAL = 30_000;          // 30s — matches TC2 app polling
const TOKEN_TTL     = 25 * 60 * 1000; // 25 min (tokens expire at ~30 min)

export class TotalConnectPoller extends EventEmitter {
  private config: TotalConnectConfig;
  private session: TCSession | null = null;
  private sessionExpiry = 0;
  private panels: Map<string, AlarmPanel> = new Map();  // keyed by locationId
  private zones: Map<string, AlarmZone[]> = new Map();  // keyed by locationId
  private pollTimer: ReturnType<typeof setInterval> | null = null;
  private _connected = false;

  constructor(config: TotalConnectConfig) {
    super();
    this.config = config;
  }

  get isConnected(): boolean {
    return this._connected;
  }

  getPanels(): AlarmPanel[] {
    return Array.from(this.panels.values());
  }

  getZones(locationId: string): AlarmZone[] {
    return this.zones.get(locationId) ?? [];
  }

  updateConfig(config: TotalConnectConfig): void {
    this.config = config;
    this.session = null;
    this.sessionExpiry = 0;

    if (config.enabled && config.username && config.password) {
      if (!this.pollTimer) this.start();
      else void this.poll();
    } else {
      this.stop();
    }
  }

  start(): void {
    if (this.pollTimer) return;
    void this.poll(); // immediate first poll
    this.pollTimer = setInterval(() => { void this.poll(); }, POLL_INTERVAL);
  }

  stop(): void {
    if (this.pollTimer) {
      clearInterval(this.pollTimer);
      this.pollTimer = null;
    }
    this.session = null;
    this._connected = false;
    this.panels.clear();
    this.zones.clear();
  }

  async triggerAction(
    locationId: string,
    action: 'armAway' | 'armHome' | 'armNight' | 'disarm',
  ): Promise<void> {
    const session = await this.getSession();
    const location = session.locations.find((l) => l.locationId === locationId);
    if (!location) throw new Error(`TC2: location ${locationId} not found in session`);

    const { userCode } = this.config;

    if (action === 'disarm') {
      await disarm(session, locationId, location.securityDeviceId, userCode, location.partitionIds);
    } else {
      const armType =
        action === 'armAway'  ? ArmType.Away  :
        action === 'armHome'  ? ArmType.Stay  :
        /* armNight */          ArmType.Night;
      await arm(session, locationId, location.securityDeviceId, armType, userCode, location.partitionIds);
    }

    // Optimistic state update while TC2 processes the command
    const panel = this.panels.get(locationId);
    if (panel) {
      const optimisticState = action === 'disarm' ? 'disarming' : 'arming';
      this.panels.set(locationId, {
        ...panel,
        state: optimisticState,
        lastUpdated: Date.now(),
      });
      this.emit('stateChange', this.getPanels(), Object.fromEntries(this.zones));
    }

    // Poll soon to get the real state
    setTimeout(() => { void this.poll(); }, 3_000);
  }

  private async getSession(): Promise<TCSession> {
    if (this.session && Date.now() < this.sessionExpiry) return this.session;
    const session = await authenticate(this.config.username, this.config.password);
    this.session = session;
    this.sessionExpiry = session.expiresAt;
    return session;
  }

  private async poll(): Promise<void> {
    if (!this.config.enabled || !this.config.username || !this.config.password) return;

    try {
      const session = await this.getSession();

      let changed = false;
      for (const loc of session.locations) {
        const { armingState, zones } = await getPanelStatus(session, loc.locationId);
        const state = mapArmingState(armingState);

        const prev = this.panels.get(loc.locationId);
        if (!prev || prev.state !== state || prev.rawArmingState !== armingState) {
          changed = true;
        }

        this.panels.set(loc.locationId, {
          locationId:       loc.locationId,
          securityDeviceId: loc.securityDeviceId,
          name:             loc.name,
          state,
          rawArmingState:   armingState,
          partitionIds:     loc.partitionIds,
          lastUpdated:      Date.now(),
        });

        const prevZones = this.zones.get(loc.locationId) ?? [];
        if (zonesChanged(prevZones, zones)) changed = true;
        this.zones.set(loc.locationId, zones);
      }

      if (!this._connected) {
        this._connected = true;
        this.emit('connected');
        this.emit('stateChange', this.getPanels(), Object.fromEntries(this.zones));
      } else if (changed) {
        this.emit('stateChange', this.getPanels(), Object.fromEntries(this.zones));
      }
    } catch (err) {
      const wasConnected = this._connected;
      this._connected = false;
      this.session = null;
      this.sessionExpiry = 0;
      if (wasConnected) this.emit('disconnected', (err as Error).message);
      this.emit('error', err as Error);
      console.error('TC2 poll error:', (err as Error).message);
    }
  }
}

function zonesChanged(prev: AlarmZone[], next: AlarmZone[]): boolean {
  if (prev.length !== next.length) return true;
  return next.some((z, i) =>
    z.faulted    !== prev[i]?.faulted ||
    z.bypassed   !== prev[i]?.bypassed ||
    z.lowBattery !== prev[i]?.lowBattery,
  );
}
