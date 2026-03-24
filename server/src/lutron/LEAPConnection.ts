/**
 * LEAPConnection — high-level LEAP protocol handler.
 *
 * Builds on LEAPClient to handle:
 *  - Auto port detection (try 8081 plain → 8083 TLS)
 *  - Login (username / password)
 *  - Area + Zone enumeration
 *  - VirtualButton enumeration (scenes / keypads)
 *  - Real-time zone-status subscription
 *  - Outgoing commands (GoToLevel, button press/release)
 *  - Exponential-backoff reconnect
 *
 * Events emitted:
 *  'connected'     (ip: string)
 *  'disconnected'  (reason: string)
 *  'error'         (err: Error)
 *  'stateChange'   (zoneId: number, level: number)
 *  'zonesLoaded'   (zones: LEAPZone[])
 */
import { EventEmitter } from 'events';
import { LEAPClient } from './LEAPClient.js';
import { loadCert, hasCert } from './LEAPCertManager.js';
import type { ProcessorConfig } from './types.js';

// ── LEAP data model ─────────────────────────────────────────────────────────

export interface LEAPArea {
  href: string;
  id: number;
  name: string;
  isLeaf: boolean;
}

export type LEAPControlType = 'Dimmed' | 'Switched' | 'Shade' | 'Unknown';

export interface LEAPZone {
  href: string;
  id: number;
  name: string;
  controlType: LEAPControlType;
  areaId: number;
  areaName: string;
}

export interface LEAPVirtualButton {
  href: string;
  id: number;
  name: string;
  areaId: number;
  areaName: string;
}

// ── Connection class ────────────────────────────────────────────────────────

const RECONNECT_DELAYS = [5_000, 10_000, 20_000, 40_000, 60_000];

export class LEAPConnection extends EventEmitter {
  private client: LEAPClient | null = null;
  private reconnectTimer: NodeJS.Timeout | null = null;
  private reconnectAttempts = 0;
  private _isConnected = false;
  private _config: ProcessorConfig | null = null;

  // Cached topology
  private areas = new Map<number, LEAPArea>();
  private zones = new Map<number, LEAPZone>();
  private virtualButtons = new Map<number, LEAPVirtualButton>();
  private zoneStatusSubscribed = false;

  // ── Public API ────────────────────────────────────────────────────────────

  async connect(config: ProcessorConfig): Promise<void> {
    this._config = config;
    this.clearReconnectTimer();
    await this.attemptConnect(config);
  }

  async disconnect(): Promise<void> {
    this.clearReconnectTimer();
    this._isConnected = false;
    this.zoneStatusSubscribed = false;
    this.client?.disconnect();
    this.client = null;
  }

  get isConnected(): boolean {
    return this._isConnected;
  }

  getZones(): LEAPZone[] {
    return Array.from(this.zones.values());
  }

  getAreas(): LEAPArea[] {
    return Array.from(this.areas.values());
  }

  getVirtualButtons(): LEAPVirtualButton[] {
    return Array.from(this.virtualButtons.values());
  }

  getZone(id: number): LEAPZone | undefined {
    return this.zones.get(id);
  }

  /** Set zone output level (0–100). fadeTime in seconds. */
  async setLevel(zoneId: number, level: number, fadeTime = 1): Promise<void> {
    this.assertConnected();
    const fade = fadeDuration(fadeTime);
    await this.client!.send({
      CommuniqueType: 'CreateRequest',
      Header: { Url: `/zone/${zoneId}/commandprocessor` },
      Body: {
        Command: {
          CommandType: 'GoToLevel',
          Parameter: [{ Type: 'Level', Value: level }],
          ...(fade ? { FadeTime: fade } : {}),
        },
      },
    });
  }

  /** Press a virtual button (scene trigger). */
  async pressVirtualButton(buttonId: number): Promise<void> {
    this.assertConnected();
    await this.client!.send({
      CommuniqueType: 'CreateRequest',
      Header: { Url: `/virtualbutton/${buttonId}/commandprocessor` },
      Body: {
        Command: {
          CommandType: 'ButtonAction',
          ButtonAction: { ButtonEvent: { EventType: 'Press' } },
        },
      },
    });
  }

  /** Release a virtual button. */
  async releaseVirtualButton(buttonId: number): Promise<void> {
    this.assertConnected();
    await this.client!.send({
      CommuniqueType: 'CreateRequest',
      Header: { Url: `/virtualbutton/${buttonId}/commandprocessor` },
      Body: {
        Command: {
          CommandType: 'ButtonAction',
          ButtonAction: { ButtonEvent: { EventType: 'Release' } },
        },
      },
    });
  }

  /** Query current level of a zone. */
  async queryZoneLevel(zoneId: number): Promise<number> {
    this.assertConnected();
    const resp = await this.client!.send({
      CommuniqueType: 'ReadRequest',
      Header: { Url: `/zone/${zoneId}/status` },
    });
    return (resp.Body?.ZoneStatus as { Level?: number })?.Level ?? 0;
  }

  // ── Internal: connection lifecycle ───────────────────────────────────────

  private async attemptConnect(config: ProcessorConfig): Promise<void> {
    // Determine ports to try
    const portsToTry: Array<{ port: number; tls: boolean }> =
      config.port && config.port !== 0
        ? [{ port: config.port, tls: true }]
        : [
            { port: 8081, tls: true },
            { port: 8083, tls: true },
          ];

    let lastErr: Error | undefined;
    for (const attempt of portsToTry) {
      try {
        await this.tryConnect(config, attempt.port, attempt.tls);
        return; // success
      } catch (err) {
        lastErr = err as Error;
        console.log(
          `  LEAP: port ${attempt.port} failed (${(err as Error).message}), trying next...`,
        );
      }
    }

    throw lastErr ?? new Error('Could not connect to processor');
  }

  private async tryConnect(
    config: ProcessorConfig,
    port: number,
    useTLS: boolean,
  ): Promise<void> {
    const cert = useTLS ? loadCert() : null;
    const hasMtls = !!(cert?.certPem && cert?.keyPem);

    console.log(
      `LEAP: connecting to ${config.ip}:${port} (TLS=${useTLS}, mTLS=${hasMtls})`,
    );

    const client = new LEAPClient(config.ip, port, useTLS, {
      cert: cert?.certPem,
      key: cert?.keyPem,
      ca: cert?.caCertPem,
    });
    client.on('disconnect', () => this.handleDisconnect());
    client.on('error', (err: Error) => this.emit('error', err));
    client.on('message', (msg: unknown) => this.handleUnsolicited(msg));

    await client.connect();
    this.client = client;

    // Authenticate — cert-based auth (mTLS) skips username/password login
    if (hasMtls) {
      console.log('LEAP: authenticated via client certificate');
    } else {
      await this.login(config.username, config.password);
      console.log('LEAP: authenticated via login');
    }

    // Load topology
    await this.loadAreas();
    await this.loadZones();
    await this.loadVirtualButtons();
    console.log(
      `LEAP: loaded ${this.areas.size} areas, ${this.zones.size} zones, ${this.virtualButtons.size} virtual buttons`,
    );

    // Subscribe to real-time zone updates
    await this.subscribeZoneStatus();

    this._isConnected = true;
    this.reconnectAttempts = 0;
    // Save the working port back to config
    config.port = port;
    this.emit('connected', config.ip);
  }

  // ── Internal: LEAP operations ─────────────────────────────────────────────

  private async login(username: string, password: string): Promise<void> {
    const resp = await this.client!.send({
      CommuniqueType: 'CreateRequest',
      Header: { Url: '/login' },
      Body: {
        Login: {
          ContextType: 'Application',
          LoginId: username,
          Password: password,
        },
      },
    });

    const status = resp.Header.StatusCode ?? '';
    if (!status.startsWith('200')) {
      throw new Error(`LEAP login rejected: ${status}`);
    }
  }

  private async loadAreas(): Promise<void> {
    const resp = await this.client!.send({
      CommuniqueType: 'ReadRequest',
      Header: { Url: '/area' },
    });

    const raw = (resp.Body?.Areas ?? []) as Array<Record<string, unknown>>;
    this.areas.clear();
    for (const a of raw) {
      const id = hrefToId(a.href as string);
      this.areas.set(id, {
        href: a.href as string,
        id,
        name: (a.Name as string) ?? `Area ${id}`,
        isLeaf: (a.IsLeaf as boolean) ?? true,
      });
    }
  }

  private async loadZones(): Promise<void> {
    this.zones.clear();

    // Try bulk read first (works on Caseta/RA2), fall back to individual queries (QSX)
    try {
      const resp = await this.client!.send({
        CommuniqueType: 'ReadRequest',
        Header: { Url: '/zone' },
      });
      const raw = (resp.Body?.Zones ?? []) as Array<Record<string, unknown>>;
      if (raw.length > 0) {
        for (const z of raw) {
          this.addZoneFromPayload(z);
        }
        this.emit('zonesLoaded', Array.from(this.zones.values()));
        return;
      }
    } catch {
      // /zone not supported (QSX returns 405) — fall through to zone/status discovery
    }

    // QSX path: subscribe to zone/status to discover zone IDs, then fetch each zone
    console.log('LEAP: /zone bulk read not available, discovering zones from status subscription...');
    const statusResp = await this.client!.send({
      CommuniqueType: 'SubscribeRequest',
      Header: { Url: '/zone/status' },
    });

    const statuses = (statusResp.Body?.ZoneStatuses ?? []) as Array<Record<string, unknown>>;
    const zoneIds = statuses
      .map((zs) => hrefToId((zs.Zone as { href?: string })?.href ?? ''))
      .filter((id) => id > 0);

    console.log(`LEAP: found ${zoneIds.length} zones from status, fetching details...`);

    // Fetch zone details in parallel (batches of 10 to avoid overwhelming)
    for (let i = 0; i < zoneIds.length; i += 10) {
      const batch = zoneIds.slice(i, i + 10);
      const results = await Promise.allSettled(
        batch.map((id) =>
          this.client!.send({
            CommuniqueType: 'ReadRequest',
            Header: { Url: `/zone/${id}` },
          }),
        ),
      );
      for (const result of results) {
        if (result.status === 'fulfilled' && result.value.Body?.Zone) {
          this.addZoneFromPayload(result.value.Body.Zone as Record<string, unknown>);
        }
      }
    }

    // Already subscribed — mark so subscribeZoneStatus() doesn't duplicate
    this.zoneStatusSubscribed = true;

    // Emit initial levels from the subscription response
    for (const zs of statuses) {
      this.emitZoneStatus(zs);
    }

    this.emit('zonesLoaded', Array.from(this.zones.values()));
  }

  private addZoneFromPayload(z: Record<string, unknown>): void {
    const id = hrefToId(z.href as string);
    const areaHref = (z.AssociatedArea as { href?: string } | undefined)?.href ?? '';
    const areaId = hrefToId(areaHref);
    const area = this.areas.get(areaId);
    this.zones.set(id, {
      href: z.href as string,
      id,
      name: (z.Name as string) ?? `Zone ${id}`,
      controlType: parseControlType(z.ControlType as string),
      areaId,
      areaName: area?.name ?? 'Unassigned',
    });
  }

  private async loadVirtualButtons(): Promise<void> {
    try {
      const resp = await this.client!.send({
        CommuniqueType: 'ReadRequest',
        Header: { Url: '/virtualbutton' },
      });

      const raw = (resp.Body?.VirtualButtons ?? []) as Array<Record<string, unknown>>;
      this.virtualButtons.clear();
      for (const b of raw) {
        const id = hrefToId(b.href as string);
        const areaHref = (b.AssociatedArea as { href?: string } | undefined)?.href ?? '';
        const areaId = hrefToId(areaHref);
        const area = this.areas.get(areaId);
        // Only include programmed buttons (not all virtual buttons)
        if (b.IsProgrammed === false) continue;
        this.virtualButtons.set(id, {
          href: b.href as string,
          id,
          name: (b.Name as string) ?? `Button ${id}`,
          areaId,
          areaName: area?.name ?? 'Unassigned',
        });
      }
    } catch {
      // Virtual buttons are optional — some processors don't have them
    }
  }

  private async subscribeZoneStatus(): Promise<void> {
    if (this.zoneStatusSubscribed) return; // Already subscribed during loadZones (QSX path)

    const resp = await this.client!.send({
      CommuniqueType: 'SubscribeRequest',
      Header: { Url: '/zone/status' },
    });

    // The SubscribeResponse includes initial zone levels
    const statuses = (
      resp.Body?.ZoneStatuses ?? []
    ) as Array<Record<string, unknown>>;
    for (const zs of statuses) {
      this.emitZoneStatus(zs);
    }
    this.zoneStatusSubscribed = true;
  }

  // ── Internal: unsolicited messages ────────────────────────────────────────

  private handleUnsolicited(msg: unknown): void {
    const m = msg as {
      Header?: { MessageBodyType?: string };
      Body?: Record<string, unknown>;
    };
    const bodyType = m.Header?.MessageBodyType ?? '';

    if (bodyType === 'MultipleZoneStatus' || bodyType === 'OneZoneStatus') {
      const statuses = (
        m.Body?.ZoneStatuses ??
        (m.Body?.ZoneStatus ? [m.Body.ZoneStatus] : [])
      ) as Array<Record<string, unknown>>;
      for (const zs of statuses) {
        this.emitZoneStatus(zs);
      }
    }
  }

  private emitZoneStatus(zs: Record<string, unknown>): void {
    const zoneHref = (zs.Zone as { href?: string } | undefined)?.href ?? '';
    const zoneId = hrefToId(zoneHref);
    const level = (zs.Level as number | undefined) ?? 0;
    if (zoneId > 0) {
      this.emit('stateChange', zoneId, level);
    }
  }

  // ── Internal: reconnect ───────────────────────────────────────────────────

  private handleDisconnect(): void {
    if (!this._isConnected) return; // already in reconnect loop
    this._isConnected = false;
    this.emit('disconnected', 'Connection lost');
    this.scheduleReconnect();
  }

  private scheduleReconnect(): void {
    if (!this._config) return;
    const delay =
      RECONNECT_DELAYS[Math.min(this.reconnectAttempts, RECONNECT_DELAYS.length - 1)];
    this.reconnectAttempts++;
    console.log(
      `LEAP: reconnecting in ${delay / 1000}s (attempt ${this.reconnectAttempts})...`,
    );
    this.reconnectTimer = setTimeout(async () => {
      try {
        await this.attemptConnect(this._config!);
      } catch {
        this.scheduleReconnect();
      }
    }, delay);
  }

  private clearReconnectTimer(): void {
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
  }

  private assertConnected(): void {
    if (!this._isConnected || !this.client?.isConnected) {
      throw new Error('Not connected to processor');
    }
  }
}

// ── Utilities ────────────────────────────────────────────────────────────────

function hrefToId(href: string): number {
  if (!href) return 0;
  const parts = href.split('/');
  return parseInt(parts[parts.length - 1], 10) || 0;
}

function parseControlType(ct: string): LEAPControlType {
  if (ct === 'Dimmed') return 'Dimmed';
  if (ct === 'Switched') return 'Switched';
  if (ct === 'Shade') return 'Shade';
  return 'Unknown';
}

/** Convert seconds to Lutron HH:MM:SS fade duration string. */
function fadeDuration(seconds: number): string | undefined {
  if (seconds <= 0) return undefined;
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = seconds % 60;
  return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`;
}
