import { Router, type Response } from 'express';
import { randomUUID } from 'crypto';
import type { DeviceStore } from '../state/DeviceStore.js';
import type { LEAPConnection } from '../lutron/LEAPConnection.js';
import { LEAPPairing, type PairingStatus } from '../lutron/LEAPPairing.js';
import { loadConfig, saveConfig } from '../config.js';
import type { AppConfig, DeviceConfig, Scene } from '../lutron/types.js';
import { zonesToDeviceConfigs } from '../lutron/leapUtils.js';
import {
  hasCert,
  saveCert,
  deleteCert,
  validateCertPair,
  parseCertInfo,
} from '../lutron/LEAPCertManager.js';
import type { MyQPoller } from '../myq/MyQPoller.js';
import type { TotalConnectPoller } from '../totalconnect/TotalConnectPoller.js';
import type { SunShadeAutomation } from '../automation/SunShadeAutomation.js';
import { getSunPosition } from '../utils/SunPosition.js';

export function createRoutes(
  deviceStore: DeviceStore,
  connection: LEAPConnection,
  myqPoller: MyQPoller,
  alarmPoller: TotalConnectPoller,
  sunAutomations: SunShadeAutomation[] = [],
): Router {
  const router = Router();

  // ── Status ────────────────────────────────────────────────────────────────

  router.get('/status', (_req, res) => {
    const config = loadConfig();
    res.json({
      connected: connection.isConnected,
      processorIp: config.processor.ip || null,
      processorPort: config.processor.port || null,
      deviceCount: deviceStore.getAllDevices().length,
    });
  });

  // ── Devices ───────────────────────────────────────────────────────────────

  router.get('/devices', (_req, res) => {
    res.json(deviceStore.getAllDevices());
  });

  router.get('/rooms', (_req, res) => {
    const rooms = deviceStore.getDevicesByRoom();
    const result: Record<string, ReturnType<DeviceStore['getAllDevices']>> = {};
    for (const [room, devices] of rooms) {
      result[room] = devices;
    }
    res.json(result);
  });

  router.get('/devices/:id', (req, res) => {
    const device = deviceStore.getDevice(parseInt(req.params.id, 10));
    if (!device) {
      res.status(404).json({ error: 'Device not found' });
      return;
    }
    res.json(device);
  });

  router.put('/devices/:id', async (req, res) => {
    const id = parseInt(req.params.id, 10);
    const { level, fadeTime } = req.body as { level: number; fadeTime?: number };

    if (typeof level !== 'number' || level < 0 || level > 100) {
      res.status(400).json({ error: 'Level must be 0–100' });
      return;
    }
    if (!connection.isConnected) {
      res.status(503).json({ error: 'Not connected to processor' });
      return;
    }

    try {
      await connection.setLevel(id, level, fadeTime);
      res.json({ ok: true, deviceId: id, level });
    } catch (err) {
      res.status(500).json({ error: String(err) });
    }
  });

  router.post('/devices/:id/press', async (req, res) => {
    const { component } = req.body as { component: number };
    if (!connection.isConnected) {
      res.status(503).json({ error: 'Not connected to processor' });
      return;
    }
    try {
      await connection.pressVirtualButton(component);
      res.json({ ok: true });
    } catch (err) {
      res.status(500).json({ error: String(err) });
    }
  });

  // ── LEAP topology (areas + zones + virtual buttons) ───────────────────────

  router.get('/topology', (_req, res) => {
    if (!connection.isConnected) {
      res.status(503).json({ error: 'Not connected to processor' });
      return;
    }
    res.json({
      areas: connection.getAreas(),
      zones: connection.getZones(),
      virtualButtons: connection.getVirtualButtons(),
    });
  });

  // ── Config ────────────────────────────────────────────────────────────────

  router.get('/config', (_req, res) => {
    const config = loadConfig();
    res.json({
      processor: {
        ip: config.processor.ip,
        port: config.processor.port,
        username: config.processor.username,
        // password omitted
      },
      devices: config.devices,
    });
  });

  router.put('/config', async (req, res) => {
    const config = loadConfig();
    const { processor } = req.body as Partial<AppConfig>;

    if (processor) {
      config.processor = { ...config.processor, ...processor };
    }
    saveConfig(config);

    if (config.processor.ip) {
      try {
        await connection.disconnect();
        await connection.connect(config.processor);
        // Save discovered port back
        saveConfig(config);
        res.json({ ok: true, connected: true });
      } catch (err) {
        res.json({ ok: true, connected: false, error: String(err) });
      }
    } else {
      res.json({ ok: true, connected: false });
    }
  });

  router.put('/config/devices', (req, res) => {
    const config = loadConfig();
    const { devices } = req.body as { devices: DeviceConfig[] };

    if (!Array.isArray(devices)) {
      res.status(400).json({ error: 'devices must be an array' });
      return;
    }

    config.devices = devices;
    saveConfig(config);
    deviceStore.loadFromConfig(devices);
    res.json({ ok: true, deviceCount: devices.length });
  });

  // ── Discovery (LEAP-native: reads zones from processor) ───────────────────

  router.post('/discover', async (_req, res) => {
    if (!connection.isConnected) {
      res.status(503).json({ error: 'Not connected to processor' });
      return;
    }

    const zones = connection.getZones();
    const areas = connection.getAreas();
    const vbuttons = connection.getVirtualButtons();

    // Persist discovered devices
    const devices = zonesToDeviceConfigs(zones, vbuttons);
    const config = loadConfig();
    config.devices = devices;
    saveConfig(config);
    deviceStore.loadFromConfig(devices);

    res.json({
      zones: zones.length,
      areas: areas.length,
      virtualButtons: vbuttons.length,
      devices: devices.length,
      topology: { areas, zones, virtualButtons: vbuttons },
    });
  });

  // ── Certificate management (mTLS for HomeWorks QS) ───────────────────────

  /** GET /api/cert — cert status */
  router.get('/cert', (_req, res) => {
    res.json({ present: hasCert() });
  });

  router.get('/cert/status', (_req, res) => {
    res.json({ present: hasCert() });
  });

  /** POST /api/cert — import a certificate (PEM strings in body) */
  router.post('/cert', async (req, res) => {
    const { certPem, keyPem, caCertPem } = req.body as {
      certPem?: string;
      keyPem?: string;
      caCertPem?: string;
    };

    if (!certPem || !keyPem) {
      res.status(400).json({ error: 'certPem and keyPem are required' });
      return;
    }

    try {
      validateCertPair(certPem, keyPem);
    } catch (err) {
      res.status(400).json({ error: `Invalid certificate: ${String(err)}` });
      return;
    }

    saveCert({ certPem, keyPem, caCertPem });
    const info = parseCertInfo(certPem);

    // Reconnect with the new certificate
    const config = loadConfig();
    if (config.processor.ip) {
      try {
        await connection.disconnect();
        await connection.connect(config.processor);
        saveConfig(config);
        res.json({ ok: true, connected: true, info });
      } catch (err) {
        res.json({ ok: true, connected: false, error: String(err), info });
      }
    } else {
      res.json({ ok: true, connected: false, info });
    }
  });

  /** DELETE /api/cert — remove stored certificate */
  router.delete('/cert', async (_req, res) => {
    deleteCert();
    await connection.disconnect();
    res.json({ ok: true });
  });

  // ── Pairing flow (button-press pairing like Caseta) ────────────────────

  let activePairing: LEAPPairing | null = null;

  /**
   * POST /api/pair — start certificate pairing.
   * Uses Server-Sent Events to stream pairing status back to the client.
   * The user must press the physical button on the processor within 60s.
   */
  router.post('/pair', async (req, res: Response) => {
    const config = loadConfig();
    if (!config.processor.ip) {
      res.status(400).json({ error: 'No processor IP configured. Set it first via PUT /api/config.' });
      return;
    }

    // Cancel any previous pairing attempt
    activePairing?.abort();

    // Set up SSE stream
    res.setHeader('Content-Type', 'text/event-stream');
    res.setHeader('Cache-Control', 'no-cache');
    res.setHeader('Connection', 'keep-alive');
    res.flushHeaders();

    const send = (status: PairingStatus) => {
      res.write(`data: ${JSON.stringify(status)}\n\n`);
    };

    activePairing = new LEAPPairing(config.processor.ip);
    activePairing.on('status', send);

    try {
      await activePairing.pair(60_000);

      // Reconnect with the new certificate
      send({ stage: 'done', message: 'Reconnecting with new certificate…' });
      try {
        await connection.disconnect();
        await connection.connect(config.processor);
        saveConfig(config);
        send({ stage: 'done', message: 'Connected! You can now discover your devices.' });
      } catch (err) {
        send({
          stage: 'error',
          message: 'Certificate saved but reconnection failed.',
          detail: String(err),
        });
      }
    } catch (err) {
      if (!res.writableEnded) {
        send({ stage: 'error', message: String(err) });
      }
    } finally {
      activePairing = null;
      res.end();
    }
  });

  /** DELETE /api/pair — abort in-progress pairing */
  router.delete('/pair', (_req, res) => {
    activePairing?.abort();
    activePairing = null;
    res.json({ ok: true });
  });

  // ── Scenes ──────────────────────────────────────────────────────────────────

  /** GET /api/scenes — list all scenes */
  router.get('/scenes', (_req, res) => {
    const config = loadConfig();
    res.json(config.scenes || []);
  });

  /** POST /api/scenes — create a new scene */
  router.post('/scenes', (req, res) => {
    const { name, icon, targets } = req.body as Partial<Scene>;
    if (!name || !icon || !Array.isArray(targets)) {
      res.status(400).json({ error: 'name, icon, and targets are required' });
      return;
    }

    const now = Date.now();
    const scene: Scene = {
      id: randomUUID(),
      name,
      icon,
      targets,
      createdAt: now,
      updatedAt: now,
    };

    const config = loadConfig();
    config.scenes = config.scenes || [];
    config.scenes.push(scene);
    saveConfig(config);
    res.json(scene);
  });

  /** PUT /api/scenes/:id — update a scene */
  router.put('/scenes/:id', (req, res) => {
    const config = loadConfig();
    const scenes = config.scenes || [];
    const idx = scenes.findIndex((s) => s.id === req.params.id);
    if (idx === -1) {
      res.status(404).json({ error: 'Scene not found' });
      return;
    }

    const { name, icon, targets } = req.body as Partial<Scene>;
    if (name !== undefined) scenes[idx].name = name;
    if (icon !== undefined) scenes[idx].icon = icon;
    if (targets !== undefined) scenes[idx].targets = targets;
    scenes[idx].updatedAt = Date.now();

    config.scenes = scenes;
    saveConfig(config);
    res.json(scenes[idx]);
  });

  /** DELETE /api/scenes/:id — delete a scene */
  router.delete('/scenes/:id', (req, res) => {
    const config = loadConfig();
    const scenes = config.scenes || [];
    const idx = scenes.findIndex((s) => s.id === req.params.id);
    if (idx === -1) {
      res.status(404).json({ error: 'Scene not found' });
      return;
    }

    scenes.splice(idx, 1);
    config.scenes = scenes;
    saveConfig(config);
    res.json({ ok: true });
  });

  /** POST /api/scenes/:id/activate — execute a scene */
  router.post('/scenes/:id/activate', async (req, res) => {
    const config = loadConfig();
    const scenes = config.scenes || [];
    const scene = scenes.find((s) => s.id === req.params.id);
    if (!scene) {
      res.status(404).json({ error: 'Scene not found' });
      return;
    }
    if (!connection.isConnected) {
      res.status(503).json({ error: 'Not connected to processor' });
      return;
    }

    const results = await Promise.allSettled(
      scene.targets.map((t) => connection.setLevel(t.deviceId, t.level, 2))
    );
    const failed = results.filter((r) => r.status === 'rejected').length;
    res.json({ ok: true, activated: scene.targets.length - failed, failed });
  });

  /** POST /api/scenes/capture — snapshot current non-zero device levels */
  router.post('/scenes/capture', (_req, res) => {
    const allDevices = deviceStore.getAllDevices();
    const targets = allDevices
      .filter((d) => d.level > 0 && (d.type === 'light' || d.type === 'shade'))
      .map((d) => ({ deviceId: d.integrationId, level: Math.round(d.level) }));
    res.json({ targets });
  });

  // ── MyQ / Garage ──────────────────────────────────────────────────────────

  /** GET /api/myq/status — MyQ connection status + discovered doors */
  router.get('/myq/status', (_req, res) => {
    res.json({
      connected: myqPoller.isConnected,
      doors: myqPoller.getDoors(),
    });
  });

  /** GET /api/myq/config — MyQ credentials (password omitted) */
  router.get('/myq/config', (_req, res) => {
    const config = loadConfig();
    const myq = config.myq ?? { email: '', password: '', enabled: false };
    res.json({ email: myq.email, enabled: myq.enabled });
  });

  /** PUT /api/myq/config — save MyQ credentials and restart poller */
  router.put('/myq/config', (req, res) => {
    const { email, password, enabled } = req.body as {
      email?: string;
      password?: string;
      enabled?: boolean;
    };

    const config = loadConfig();
    config.myq = {
      email: email ?? config.myq?.email ?? '',
      // Only overwrite password if a non-empty value is provided
      password: password || config.myq?.password || '',
      enabled: enabled ?? config.myq?.enabled ?? false,
    };
    saveConfig(config);
    myqPoller.updateConfig(config.myq);
    res.json({ ok: true });
  });

  /** PUT /api/myq/doors/:serial/action — open or close a door */
  router.put('/myq/doors/:serial/action', async (req, res) => {
    const { action } = req.body as { action?: 'open' | 'close' };
    if (action !== 'open' && action !== 'close') {
      res.status(400).json({ error: 'action must be "open" or "close"' });
      return;
    }
    if (!myqPoller.isConnected) {
      res.status(503).json({ error: 'MyQ not connected' });
      return;
    }
    try {
      await myqPoller.triggerAction(req.params.serial, action);
      res.json({ ok: true });
    } catch (err) {
      res.status(500).json({ error: String(err) });
    }
  });

  // ── Total Connect 2.0 / Alarm ─────────────────────────────────────────────

  /** GET /api/alarm/status — alarm connection status + panels */
  router.get('/alarm/status', (_req, res) => {
    res.json({
      connected: alarmPoller.isConnected,
      panels: alarmPoller.getPanels(),
    });
  });

  /** GET /api/alarm/config — alarm credentials (password/userCode omitted) */
  router.get('/alarm/config', (_req, res) => {
    const config = loadConfig();
    const tc = config.totalconnect ?? { username: '', password: '', userCode: '', enabled: false };
    res.json({ username: tc.username, enabled: tc.enabled });
  });

  /** PUT /api/alarm/config — save credentials and restart poller */
  router.put('/alarm/config', (req, res) => {
    const { username, password, userCode, enabled } = req.body as {
      username?: string;
      password?: string;
      userCode?: string;
      enabled?: boolean;
    };

    const config = loadConfig();
    config.totalconnect = {
      username: username ?? config.totalconnect?.username ?? '',
      password: password || config.totalconnect?.password || '',
      userCode: userCode || config.totalconnect?.userCode || '',
      enabled:  enabled ?? config.totalconnect?.enabled ?? false,
    };
    saveConfig(config);
    alarmPoller.updateConfig(config.totalconnect);
    res.json({ ok: true });
  });

  /** GET /api/alarm/zones/:locationId — zone list for a location */
  router.get('/alarm/zones/:locationId', (req, res) => {
    if (!alarmPoller.isConnected) {
      res.status(503).json({ error: 'Alarm not connected' });
      return;
    }
    res.json(alarmPoller.getZones(req.params.locationId));
  });

  // ── Automations ───────────────────────────────────────────────────────────

  /** GET /api/automations/status — sun position + per-automation state */
  router.get('/automations/status', (_req, res) => {
    const config = loadConfig();
    const loc = config.automations?.[0]?.location ?? { lat: 40.93, lon: -73.75 };
    const sunPosition = getSunPosition(new Date(), loc.lat, loc.lon);
    res.json({
      sunPosition,
      automations: sunAutomations.map((a) => a.getStatus()),
    });
  });

  return router;
}
