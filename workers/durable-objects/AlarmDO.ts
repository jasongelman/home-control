// AlarmDO — Durable Object for Resideo Total Connect 2.0 alarm integration.
//
// Owns: TC2 session, config (credentials), topology (panel/zone names), and
// live state (armed/disarmed, zone faults). Polls TC2 every 30s using
// storage.setAlarm(). On state change, calls the Broadcaster DO to push an
// SSE event to all connected clients.

import {
  authenticate,
  getPanelStatus,
  arm,
  disarm,
  mapArmingState,
  diagnoseTc2Auth,
  testTc2Auth,
  ArmType,
  type TCSession,
  type AlarmPanel,
  type AlarmZone,
  type PanelState,
} from '../integrations/totalconnect.js';

const POLL_INTERVAL = 30_000; // 30s

// ── Stored state shapes ──────────────────────────────────────────────────────

interface StoredConfig {
  username: string;
  password: string;
  userCode: string;
  enabled: boolean;
}

interface StoredTopology {
  panels: Array<{
    locationId: string;
    securityDeviceId: string;
    name: string;
    partitionIds: number[];
  }>;
  zones: Record<string, Array<{ zoneId: number; name: string }>>;
}

interface StoredState {
  panels: AlarmPanel[];
  zones: Record<string, AlarmZone[]>;
  lastPoll: number;
}

// ── Env bindings ─────────────────────────────────────────────────────────────

export interface AlarmDOEnv {
  BROADCASTER: DurableObjectNamespace;
}

// ── Durable Object class ─────────────────────────────────────────────────────

export class AlarmDO {
  private state: DurableObjectState;
  private env: AlarmDOEnv;

  // In-memory caches (hydrated from storage on first wake)
  private config: StoredConfig | null = null;
  private session: TCSession | null = null;
  private panels: Map<string, AlarmPanel> = new Map();
  private zones: Map<string, AlarmZone[]> = new Map();
  private hydrated = false;
  private consecutiveAuthFailures = 0;

  constructor(state: DurableObjectState, env: AlarmDOEnv) {
    this.state = state;
    this.env = env;
  }

  // ── HTTP dispatch ──────────────────────────────────────────────────────────

  async fetch(request: Request): Promise<Response> {
    await this.hydrate();

    const url = new URL(request.url);
    const path = url.pathname;

    try {
      if (request.method === 'GET' && path === '/status') {
        return Response.json(this.getStatusSnapshot());
      }

      if (request.method === 'POST' && path === '/action') {
        const body = await request.json() as { action: string; locationId?: string };
        await this.triggerAction(body.action, body.locationId);
        return Response.json({ ok: true });
      }

      if (request.method === 'POST' && path === '/config') {
        const body = await request.json() as StoredConfig;
        await this.updateConfig(body);
        return Response.json({ ok: true });
      }

      if (request.method === 'GET' && path === '/config') {
        return Response.json({
          enabled: this.config?.enabled ?? false,
          hasCredentials: !!(this.config?.username && this.config?.password),
        });
      }

      // Emergency stop: disable polling and clear alarms
      if (request.method === 'POST' && path === '/disable') {
        if (this.config) {
          this.config.enabled = false;
          await this.state.storage.put('config', this.config);
        }
        await this.state.storage.deleteAlarm();
        this.session = null;
        this.consecutiveAuthFailures = 0;
        return Response.json({ ok: true, message: 'polling disabled, alarms cleared' });
      }

      // Debug: diagnose TC2 auth plumbing
      if (request.method === 'GET' && path === '/diag') {
        const diag = await diagnoseTc2Auth();
        return Response.json(diag);
      }

      // Debug: generate the encrypted form body without sending to TC2
      if (request.method === 'POST' && path === '/dry-run') {
        if (!this.config?.username || !this.config?.password) {
          return Response.json({ error: 'no credentials configured' }, { status: 400 });
        }
        const { dryRunAuth } = await import('../integrations/totalconnect.js');
        const result = await dryRunAuth(this.config.username, this.config.password);
        return Response.json(result);
      }

      // Debug: full auth test — uses body creds if provided, else stored creds
      if (request.method === 'POST' && path === '/test-auth') {
        let username: string;
        let password: string;
        let source: string;
        try {
          const body = await request.json() as { username?: string; password?: string };
          if (body.username && body.password) {
            username = body.username;
            password = body.password;
            source = 'request_body';
          } else {
            throw new Error('use stored');
          }
        } catch {
          if (!this.config?.username || !this.config?.password) {
            return Response.json({ error: 'no credentials configured' }, { status: 400 });
          }
          username = this.config.username;
          password = this.config.password;
          source = 'do_storage';
        }
        const result = await testTc2Auth(username, password);
        result.credentialSource = source;
        result.storedUsername = this.config?.username ?? null;
        result.storedPasswordLength = this.config?.password?.length ?? 0;
        return Response.json(result);
      }

      // Debug: force a poll and return the result or error directly
      if (request.method === 'POST' && path === '/poll') {
        try {
          await this.poll();
          return Response.json({ ok: true, ...this.getStatusSnapshot() });
        } catch (err) {
          return Response.json({
            ok: false,
            error: err instanceof Error ? err.message : String(err),
            stack: err instanceof Error ? err.stack : undefined,
          }, { status: 500 });
        }
      }

      return Response.json({ error: 'not_found' }, { status: 404 });
    } catch (err) {
      const message = err instanceof Error ? err.message : 'unknown error';
      console.error('AlarmDO error:', message);
      return Response.json({ error: message }, { status: 500 });
    }
  }

  // ── Alarm handler (polling loop) ───────────────────────────────────────────

  async alarm(): Promise<void> {
    await this.hydrate();
    if (!this.config?.enabled || !this.config.username || !this.config.password) return;

    try {
      await this.poll();
      this.consecutiveAuthFailures = 0;
    } catch (err) {
      const msg = (err as Error).message;
      console.error('AlarmDO poll error:', msg);
      this.session = null;

      // Back off on auth failures to avoid account lockout
      if (msg.includes('Authentication Failed') || msg.includes('locked')) {
        this.consecutiveAuthFailures++;
        // Exponential backoff: 1min, 2min, 4min, 8min, ... capped at 30min
        const backoffMs = Math.min(60_000 * Math.pow(2, this.consecutiveAuthFailures - 1), 30 * 60_000);
        console.error(`AlarmDO: auth failure #${this.consecutiveAuthFailures}, backing off ${backoffMs / 1000}s`);
        this.state.storage.setAlarm(Date.now() + backoffMs);
        return; // skip the normal reschedule
      }
    }

    this.scheduleNextPoll();
  }

  // ── Internal methods ───────────────────────────────────────────────────────

  private async hydrate(): Promise<void> {
    if (this.hydrated) return;
    this.hydrated = true;

    const [config, topology, storedState, session] = await Promise.all([
      this.state.storage.get<StoredConfig>('config'),
      this.state.storage.get<StoredTopology>('topology'),
      this.state.storage.get<StoredState>('state'),
      this.state.storage.get<TCSession>('session'),
    ]);

    this.config = config ?? null;
    this.session = session && session.expiresAt > Date.now() ? session : null;

    // Restore panels/zones from stored state (preferred) or topology cache
    if (storedState) {
      for (const p of storedState.panels) this.panels.set(p.locationId, p);
      for (const [locId, zs] of Object.entries(storedState.zones)) this.zones.set(locId, zs);
    } else if (topology) {
      for (const p of topology.panels) {
        this.panels.set(p.locationId, {
          locationId: p.locationId,
          securityDeviceId: p.securityDeviceId,
          name: p.name,
          state: 'unknown' as PanelState,
          rawArmingState: 0,
          partitionIds: p.partitionIds,
          lastUpdated: 0,
        });
      }
      for (const [locId, zs] of Object.entries(topology.zones)) {
        this.zones.set(locId, zs.map((z) => ({
          zoneId: z.zoneId,
          name: z.name,
          faulted: false,
          bypassed: false,
          lowBattery: false,
        })));
      }
    }
  }

  private getStatusSnapshot(): {
    connected: boolean;
    panels: AlarmPanel[];
    zones: Record<string, AlarmZone[]>;
  } {
    return {
      connected: this.session !== null,
      panels: Array.from(this.panels.values()),
      zones: Object.fromEntries(this.zones),
    };
  }

  private async getSession(): Promise<TCSession> {
    if (this.session && Date.now() < this.session.expiresAt) return this.session;
    if (!this.config) throw new Error('AlarmDO: no config');

    const session = await authenticate(this.config.username, this.config.password);
    this.session = session;
    await this.state.storage.put('session', session);
    return session;
  }

  private async poll(): Promise<void> {
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
        || JSON.stringify(prev.partitionIds) !== JSON.stringify(loc.partitionIds)) {
        topologyChanged = true;
      }

      this.panels.set(loc.locationId, {
        locationId: loc.locationId,
        securityDeviceId: loc.securityDeviceId,
        name: loc.name,
        state,
        rawArmingState: armingState,
        partitionIds: loc.partitionIds,
        lastUpdated: Date.now(),
      });

      const prevZones = this.zones.get(loc.locationId) ?? [];
      if (zonesChanged(prevZones, zones)) stateChanged = true;
      if (zoneTopologyChanged(prevZones, zones)) topologyChanged = true;
      this.zones.set(loc.locationId, zones);
    }

    // Persist state
    const snapshot: StoredState = {
      panels: Array.from(this.panels.values()),
      zones: Object.fromEntries(this.zones),
      lastPoll: Date.now(),
    };
    await this.state.storage.put('state', snapshot);

    if (topologyChanged) {
      const topology: StoredTopology = {
        panels: Array.from(this.panels.values()).map((p) => ({
          locationId: p.locationId,
          securityDeviceId: p.securityDeviceId,
          name: p.name,
          partitionIds: p.partitionIds,
        })),
        zones: Object.fromEntries(
          Array.from(this.zones.entries()).map(([locId, zs]) => [
            locId,
            zs.map((z) => ({ zoneId: z.zoneId, name: z.name })),
          ]),
        ),
      };
      await this.state.storage.put('topology', topology);
    }

    if (stateChanged || topologyChanged) {
      await this.broadcast();
    }
  }

  private async triggerAction(action: string, locationId?: string): Promise<void> {
    if (!this.config) throw new Error('AlarmDO: not configured');

    const session = await this.getSession();

    // Default to first location if not specified
    const locId = locationId ?? session.locations[0]?.locationId;
    const location = session.locations.find((l) => l.locationId === locId);
    if (!location) throw new Error(`AlarmDO: location ${locId} not found`);

    if (action === 'disarm') {
      await disarm(session, locId, location.securityDeviceId, this.config.userCode, location.partitionIds);
    } else {
      const armType =
        action === 'armAway'  ? ArmType.Away  :
        action === 'armHome'  ? ArmType.Stay  :
        /* armNight */          ArmType.Night;
      await arm(session, locId, location.securityDeviceId, armType, this.config.userCode, location.partitionIds);
    }

    // Optimistic state update
    const panel = this.panels.get(locId);
    if (panel) {
      const optimisticState: PanelState = action === 'disarm' ? 'disarming' : 'arming';
      this.panels.set(locId, { ...panel, state: optimisticState, lastUpdated: Date.now() });
      await this.broadcast();
    }

    // Schedule a fast re-poll to pick up the real state
    this.state.storage.setAlarm(Date.now() + 3_000);
  }

  private async updateConfig(config: StoredConfig): Promise<void> {
    this.config = config;
    await this.state.storage.put('config', config);

    // Clear session so next poll re-authenticates with new credentials
    this.session = null;
    await this.state.storage.delete('session');

    if (config.enabled && config.username && config.password) {
      // Kick off polling immediately
      this.state.storage.setAlarm(Date.now() + 100);
    }
  }

  private scheduleNextPoll(): void {
    this.state.storage.setAlarm(Date.now() + POLL_INTERVAL);
  }

  private async broadcast(): Promise<void> {
    const id = this.env.BROADCASTER.idFromName('global');
    const stub = this.env.BROADCASTER.get(id);
    const event = {
      integration: 'alarm',
      state: this.getStatusSnapshot(),
    };
    await stub.fetch(new Request('http://internal/broadcast', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(event),
    }));
  }
}

// ── Helpers ──────────────────────────────────────────────────────────────────

function zonesChanged(prev: AlarmZone[], next: AlarmZone[]): boolean {
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
