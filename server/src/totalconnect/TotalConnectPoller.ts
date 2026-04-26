import { EventEmitter } from 'events';
import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';
import type { TotalConnectConfig, AlarmPanel, AlarmZone, PanelState } from './types.js';
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

const __dirname = dirname(fileURLToPath(import.meta.url));
const TOPOLOGY_PATH = join(__dirname, '..', '..', 'data', 'alarm-topology.json');

interface CachedTopology {
  panels: Array<{
    locationId: string;
    securityDeviceId: string;
    name: string;
    partitionIds: number[];
  }>;
  zones: Record<string, Array<{ zoneId: number; name: string }>>;
  savedAt: number;
}

export class TotalConnectPoller extends EventEmitter {
  private config: TotalConnectConfig;
  private session: TCSession | null = null;
  private sessionExpiry = 0;
  private panels: Map<string, AlarmPanel> = new Map();  // keyed by locationId
  private zones: Map<string, AlarmZone[]> = new Map();  // keyed by locationId
  private pollTimer: ReturnType<typeof setInterval> | null = null;
  private _connected = false;
  private consecutiveFailures = 0;
  private _authFailed = false;

  constructor(config: TotalConnectConfig) {
    super();
    this.config = config;
    this.loadTopologyCache();
  }

  // ── Topology cache (server/data/alarm-topology.json, gitignored) ────────────
  //
  // The alarm setup (locations, panel name, zone names) changes rarely. We
  // persist it so that:
  //   1. After server restart, getPanels() and getZones() return *named*
  //      entries immediately, with state='unknown' until the first poll
  //      completes. This means iOS/web don't have to wait on a TC2 round-trip
  //      to render the UI.
  //   2. We don't need to re-fetch sessiondetails every restart — the cached
  //      locationId / securityDeviceId / partitionIds are reused.
  //
  // The cache is rewritten on every successful poll where topology changes
  // (zone added/removed/renamed, new location, etc).

  private loadTopologyCache(): void {
    if (!existsSync(TOPOLOGY_PATH)) return;
    try {
      const raw = readFileSync(TOPOLOGY_PATH, 'utf-8');
      const cache = JSON.parse(raw) as CachedTopology;

      for (const p of cache.panels) {
        this.panels.set(p.locationId, {
          locationId:       p.locationId,
          securityDeviceId: p.securityDeviceId,
          name:             p.name,
          state:            'unknown' as PanelState,
          rawArmingState:   0,
          partitionIds:     p.partitionIds,
          lastUpdated:      0,
        });
      }
      for (const [locId, zs] of Object.entries(cache.zones)) {
        this.zones.set(locId, zs.map((z) => ({
          zoneId:     z.zoneId,
          name:       z.name,
          faulted:    false,
          bypassed:   false,
          lowBattery: false,
        })));
      }
    } catch (err) {
      console.warn('TC2: failed to load topology cache:', (err as Error).message);
    }
  }

  private saveTopologyCache(): void {
    try {
      mkdirSync(dirname(TOPOLOGY_PATH), { recursive: true });
      const cache: CachedTopology = {
        panels: Array.from(this.panels.values()).map((p) => ({
          locationId:       p.locationId,
          securityDeviceId: p.securityDeviceId,
          name:             p.name,
          partitionIds:     p.partitionIds,
        })),
        zones: Object.fromEntries(
          Array.from(this.zones.entries()).map(([locId, zs]) => [
            locId,
            zs.map((z) => ({ zoneId: z.zoneId, name: z.name })),
          ]),
        ),
        savedAt: Date.now(),
      };
      writeFileSync(TOPOLOGY_PATH, JSON.stringify(cache, null, 2), 'utf-8');
    } catch (err) {
      console.warn('TC2: failed to save topology cache:', (err as Error).message);
    }
  }

  get isConnected(): boolean {
    return this._connected;
  }

  get authFailed(): boolean {
    return this._authFailed;
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
    this.consecutiveFailures = 0;
    this._authFailed = false;

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
    // Drop cached topology when the user signs out — credentials and topology
    // are paired; we should not retain one without the other.
    try { if (existsSync(TOPOLOGY_PATH)) writeFileSync(TOPOLOGY_PATH, '{"panels":[],"zones":{},"savedAt":0}', 'utf-8'); } catch { /* ignore */ }
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

      let stateChanged = false;
      let topologyChanged = false;
      for (const loc of session.locations) {
        const { armingState, zones } = await getPanelStatus(session, loc.locationId);
        const state = mapArmingState(armingState);

        const prev = this.panels.get(loc.locationId);
        if (!prev || prev.state !== state || prev.rawArmingState !== armingState) {
          stateChanged = true;
        }
        if (!prev
          || prev.name !== loc.name
          || prev.securityDeviceId !== loc.securityDeviceId
          || !arraysEqual(prev.partitionIds, loc.partitionIds)) {
          topologyChanged = true;
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
        if (zoneStateChanged(prevZones, zones)) stateChanged = true;
        if (zoneTopologyChanged(prevZones, zones)) topologyChanged = true;
        this.zones.set(loc.locationId, zones);
      }

      if (topologyChanged) this.saveTopologyCache();

      if (!this._connected) {
        this._connected = true;
        this._authFailed = false;
        this.consecutiveFailures = 0;
        this.emit('connected');
        this.emit('stateChange', this.getPanels(), Object.fromEntries(this.zones));
      } else if (stateChanged || topologyChanged) {
        this.consecutiveFailures = 0;
        this.emit('stateChange', this.getPanels(), Object.fromEntries(this.zones));
      }
    } catch (err) {
      const wasConnected = this._connected;
      this._connected = false;
      this.session = null;
      this.sessionExpiry = 0;
      this.consecutiveFailures++;

      if (this.consecutiveFailures >= 2) {
        this._authFailed = true;
        console.error(`TC2: auth failed after ${this.consecutiveFailures} attempts — stopping poll. Update credentials to retry.`);
        if (this.pollTimer) {
          clearInterval(this.pollTimer);
          this.pollTimer = null;
        }
      }

      if (wasConnected) this.emit('disconnected', (err as Error).message);
      this.emit('error', err as Error);
      console.error('TC2 poll error:', (err as Error).message);
    }
  }
}

function zoneStateChanged(prev: AlarmZone[], next: AlarmZone[]): boolean {
  if (prev.length !== next.length) return true;
  return next.some((z, i) =>
    z.faulted    !== prev[i]?.faulted ||
    z.bypassed   !== prev[i]?.bypassed ||
    z.lowBattery !== prev[i]?.lowBattery,
  );
}

function zoneTopologyChanged(prev: AlarmZone[], next: AlarmZone[]): boolean {
  if (prev.length !== next.length) return true;
  return next.some((z, i) => z.zoneId !== prev[i]?.zoneId || z.name !== prev[i]?.name);
}

function arraysEqual<T>(a: readonly T[], b: readonly T[]): boolean {
  if (a.length !== b.length) return false;
  return a.every((v, i) => v === b[i]);
}
