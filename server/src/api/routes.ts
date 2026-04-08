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
import type { HomeConnectManager } from '../homeconnect/HomeConnectManager.js';
import type { SmartHQManager } from '../smarthq/SmartHQManager.js';
import type { MyUplinkManager } from '../myuplink/MyUplinkManager.js';
import type { TotalConnectPoller } from '../totalconnect/TotalConnectPoller.js';
import type { SunShadeAutomation } from '../automation/SunShadeAutomation.js';
import { getSunPosition } from '../utils/SunPosition.js';
import { handleChat, type ChatRequest } from './chat.js';

export function createRoutes(
  deviceStore: DeviceStore,
  connection: LEAPConnection,
  myqPoller: MyQPoller,
  alarmPoller: TotalConnectPoller,
  sunAutomations: SunShadeAutomation[] = [],
  homeConnect?: HomeConnectManager,
  smartHQ?: SmartHQManager,
  myUplink?: MyUplinkManager,
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

  // ── HomeConnect / Dishwasher ───────────────────────────────────────────────

  router.get('/homeconnect/status', (_req, res) => {
    res.json({ linked: homeConnect?.isLinked ?? false, dishwashers: homeConnect?.getDishwashers() ?? [] });
  });

  router.get('/homeconnect/config', (_req, res) => {
    const config = loadConfig();
    const hc = config.homeConnect ?? { clientId: '', clientSecret: '', enabled: false };
    res.json({ clientId: hc.clientId, enabled: hc.enabled });
  });

  router.put('/homeconnect/config', (req, res) => {
    const { clientId, clientSecret, enabled } = req.body as { clientId?: string; clientSecret?: string; enabled?: boolean };
    const config = loadConfig();
    config.homeConnect = {
      ...(config.homeConnect ?? { clientId: '', clientSecret: '', enabled: false }),
      ...(clientId !== undefined && { clientId }),
      ...(clientSecret !== undefined && { clientSecret }),
      ...(enabled !== undefined && { enabled }),
    };
    saveConfig(config);
    homeConnect?.updateConfig(config.homeConnect);
    res.json({ ok: true });
  });

  router.get('/homeconnect/oauth/start', (req, res) => {
    if (!homeConnect) { res.status(503).json({ error: 'HomeConnect not available' }); return; }
    const redirectBase = `${req.protocol}://${req.get('host')}`;
    res.redirect(homeConnect.getAuthUrl(redirectBase));
  });

  router.get('/homeconnect/oauth/callback', async (req, res) => {
    const { code } = req.query as { code?: string };
    if (!code || !homeConnect) { res.status(400).send('Missing code or HomeConnect not configured'); return; }
    try {
      const redirectBase = `${req.protocol}://${req.get('host')}`;
      await homeConnect.handleCallback(code, redirectBase);
      res.send('<script>window.close()</script><p>HomeConnect linked! You can close this tab.</p>');
    } catch (err) {
      res.status(500).send(`OAuth error: ${String(err)}`);
    }
  });

  router.post('/homeconnect/unlink', (_req, res) => {
    homeConnect?.unlink();
    res.json({ ok: true });
  });

  // ── GE SmartHQ / Laundry ─────────────────────────────────────────────────

  router.get('/smarthq/status', (_req, res) => {
    res.json({ linked: smartHQ?.isLinked ?? false, appliances: smartHQ?.getAppliances() ?? [] });
  });

  router.get('/smarthq/config', (_req, res) => {
    const config = loadConfig();
    const hq = config.smartHQ ?? { email: '', password: '', enabled: false };
    res.json({ email: hq.email, enabled: hq.enabled });
  });

  router.put('/smarthq/config', (req, res) => {
    const { email, password, enabled } = req.body as { email?: string; password?: string; enabled?: boolean };
    const config = loadConfig();
    config.smartHQ = {
      email: email ?? config.smartHQ?.email ?? '',
      password: password || config.smartHQ?.password || '',
      enabled: enabled ?? config.smartHQ?.enabled ?? false,
    };
    saveConfig(config);
    smartHQ?.updateConfig(config.smartHQ);
    res.json({ ok: true });
  });

  router.post('/smarthq/login', async (req, res) => {
    if (!smartHQ) { res.status(503).json({ error: 'SmartHQ not available' }); return; }
    const { email, password } = req.body as { email?: string; password?: string };
    if (!email || !password) { res.status(400).json({ error: 'email and password required' }); return; }
    const config = loadConfig();
    config.smartHQ = { ...config.smartHQ, email, password, enabled: true } as typeof config.smartHQ;
    saveConfig(config);
    smartHQ.updateConfig(config.smartHQ!);
    try {
      await smartHQ.login();
      res.json({ ok: true });
    } catch (err) {
      res.status(500).json({ error: String(err) });
    }
  });

  router.post('/smarthq/unlink', (_req, res) => {
    smartHQ?.unlink();
    res.json({ ok: true });
  });

  // ── myUplink / Heat Pump ──────────────────────────────────────────────────

  router.get('/myuplink/status', (_req, res) => {
    res.json({ linked: myUplink?.isLinked ?? false, heatPumps: myUplink?.getHeatPumps() ?? [] });
  });

  router.get('/myuplink/config', (_req, res) => {
    const config = loadConfig();
    const mu = config.myUplink ?? { clientId: '', clientSecret: '', enabled: false };
    res.json({ clientId: mu.clientId, enabled: mu.enabled });
  });

  router.put('/myuplink/config', (req, res) => {
    const { clientId, clientSecret, enabled } = req.body as { clientId?: string; clientSecret?: string; enabled?: boolean };
    const config = loadConfig();
    config.myUplink = {
      ...(config.myUplink ?? { clientId: '', clientSecret: '', enabled: false }),
      ...(clientId !== undefined && { clientId }),
      ...(clientSecret !== undefined && { clientSecret }),
      ...(enabled !== undefined && { enabled }),
    };
    saveConfig(config);
    myUplink?.updateConfig(config.myUplink);
    res.json({ ok: true });
  });

  router.get('/myuplink/oauth/start', (req, res) => {
    if (!myUplink) { res.status(503).json({ error: 'myUplink not available' }); return; }
    const redirectBase = `${req.protocol}://${req.get('host')}`;
    res.redirect(myUplink.getAuthUrl(redirectBase));
  });

  router.get('/myuplink/oauth/callback', async (req, res) => {
    const { code } = req.query as { code?: string };
    if (!code || !myUplink) { res.status(400).send('Missing code or myUplink not configured'); return; }
    try {
      const redirectBase = `${req.protocol}://${req.get('host')}`;
      await myUplink.handleCallback(code, redirectBase);
      res.send('<script>window.close()</script><p>myUplink linked! You can close this tab.</p>');
    } catch (err) {
      res.status(500).send(`OAuth error: ${String(err)}`);
    }
  });

  router.post('/myuplink/unlink', (_req, res) => {
    myUplink?.unlink();
    res.json({ ok: true });
  });

  // ── Chat / AI Assistant ────────────────────────────────────────────────────

  /** POST /api/chat — natural language home control */
  router.post('/chat', async (req, res) => {
    const { message, history } = req.body as ChatRequest;
    if (!message || typeof message !== 'string') {
      res.status(400).json({ error: 'message is required' });
      return;
    }
    try {
      const config = loadConfig();
      const result = await handleChat(message, history || [], deviceStore, connection, myqPoller, config);
      res.json(result);
    } catch (err) {
      res.status(500).json({ error: String(err) });
    }
  });

  /** GET /api/chat/config — check if API key is configured (never exposes the key) */
  router.get('/chat/config', (_req, res) => {
    const config = loadConfig();
    res.json({ configured: !!(config.anthropicApiKey || process.env.ANTHROPIC_API_KEY) });
  });

  /** PUT /api/chat/config — save Anthropic API key */
  router.put('/chat/config', (req, res) => {
    const { apiKey } = req.body as { apiKey?: string };
    const config = loadConfig();
    config.anthropicApiKey = apiKey || '';
    saveConfig(config);
    res.json({ ok: true });
  });

  return router;
}
