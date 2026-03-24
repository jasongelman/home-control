import express from 'express';
import { createServer } from 'http';
import { WebSocketServer } from 'ws';
import { LEAPConnection } from './lutron/LEAPConnection.js';
import { DeviceStore } from './state/DeviceStore.js';
import { StateSync } from './state/StateSync.js';
import { loadConfig, saveConfig } from './config.js';
import { createRoutes } from './api/routes.js';
import { handleWebSocket } from './api/websocket.js';
import { MyQPoller } from './myq/MyQPoller.js';
import { SunShadeAutomation } from './automation/SunShadeAutomation.js';
import type { LEAPZone } from './lutron/LEAPConnection.js';
import type { MyQDoor } from './myq/types.js';

const PORT = parseInt(process.env.PORT || '3001', 10);

const app = express();
app.use(express.json());

// CORS for local development
app.use((_req, res, next) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, PUT, POST, DELETE');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  if (_req.method === 'OPTIONS') {
    res.sendStatus(204);
    return;
  }
  next();
});

const connection = new LEAPConnection();
const deviceStore = new DeviceStore();
const stateSync = new StateSync();
const config0 = loadConfig();
const myqPoller = new MyQPoller(config0.myq ?? { email: '', password: '', enabled: false });

// ── Sun-shade automations ──────────────────────────────────────────────────
const sunAutomations = (config0.automations ?? []).map(
  (cfg) => new SunShadeAutomation(cfg, connection),
);

// ── Wire up LEAP events ───────────────────────────────────────────────────────

connection.on('stateChange', (zoneId: number, level: number) => {
  deviceStore.updateLevel(zoneId, level);
  stateSync.broadcast({
    type: 'state',
    deviceId: zoneId,
    level,
    timestamp: Date.now(),
  });
});

connection.on('zonesLoaded', (zones: LEAPZone[]) => {
  // Auto-populate device store from LEAP topology
  const config = loadConfig();
  if (config.devices.length === 0) {
    // First time — populate from discovered zones
    const devices = zonesAsDeviceConfigs(zones);
    deviceStore.loadFromConfig(devices);
    config.devices = devices;
    saveConfig(config);
    console.log(`LEAP: auto-populated ${devices.length} devices from zone topology`);
  } else {
    // Reload existing config (levels will be updated via stateChange events)
    deviceStore.loadFromConfig(config.devices);
  }
  stateSync.broadcast({
    type: 'fullState',
    devices: deviceStore.getAllDevices(),
    processorConnected: true,
    doors: myqPoller.getDoors(),
    myqConnected: myqPoller.isConnected,
  });
});

connection.on('connected', (ip: string) => {
  console.log(`Connected to Lutron processor at ${ip}`);
  stateSync.broadcast({ type: 'connected', processorIp: ip });
  sunAutomations.forEach((a) => a.start());
});

connection.on('disconnected', (reason: string) => {
  console.log(`Disconnected from processor: ${reason}`);
  stateSync.broadcast({ type: 'disconnected', reason });
  sunAutomations.forEach((a) => a.stop());
  // Auto-reconnect after 5 seconds
  scheduleReconnect();
});

connection.on('error', (err: Error) => {
  console.error('Lutron connection error:', err.message);
  scheduleReconnect();
});

// ── Wire up MyQ events ────────────────────────────────────────────────────────

myqPoller.on('stateChange', (doors: MyQDoor[]) => {
  stateSync.broadcast({ type: 'garageState', doors, myqConnected: true });
});

myqPoller.on('connected', () => {
  console.log('MyQ connected');
  stateSync.broadcast({ type: 'garageState', doors: myqPoller.getDoors(), myqConnected: true });
});

myqPoller.on('disconnected', (reason: string) => {
  console.log(`MyQ disconnected: ${reason}`);
  stateSync.broadcast({ type: 'garageState', doors: [], myqConnected: false });
});

// ── Auto-reconnect logic ──────────────────────────────────────────────────────

let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
let reconnectAttempt = 0;
const MAX_RECONNECT_DELAY = 60_000; // 1 minute max

function scheduleReconnect() {
  if (reconnectTimer) return; // already scheduled
  const cfg = loadConfig();
  if (!cfg.processor.ip) return; // nothing to connect to

  // Exponential backoff: 5s, 10s, 20s, 40s, 60s (capped)
  const delay = Math.min(5_000 * Math.pow(2, reconnectAttempt), MAX_RECONNECT_DELAY);
  reconnectAttempt++;
  console.log(`Auto-reconnect in ${delay / 1000}s (attempt ${reconnectAttempt})...`);

  reconnectTimer = setTimeout(async () => {
    reconnectTimer = null;
    const currentConfig = loadConfig();
    if (!currentConfig.processor.ip) return;
    try {
      console.log(`Reconnecting to processor at ${currentConfig.processor.ip}...`);
      await connection.connect(currentConfig.processor);
      reconnectAttempt = 0; // reset on success
      console.log('Reconnected successfully');
    } catch (err) {
      console.error('Reconnect failed:', (err as Error).message);
      scheduleReconnect();
    }
  }, delay);
}

// ── REST API ──────────────────────────────────────────────────────────────────

app.use('/api', createRoutes(deviceStore, connection, myqPoller, sunAutomations));

// ── HTTP + WebSocket ──────────────────────────────────────────────────────────

const server = createServer(app);
const wss = new WebSocketServer({ server, path: '/ws' });

wss.on('connection', (ws) => {
  console.log(`WebSocket client connected (${stateSync.clientCount + 1} total)`);
  handleWebSocket(ws, deviceStore, stateSync, connection, myqPoller);
});

// ── Start ─────────────────────────────────────────────────────────────────────

const config = loadConfig();
deviceStore.loadFromConfig(config.devices);

server.listen(PORT, () => {
  console.log(`Lutron Home server running on http://localhost:${PORT}`);

  const myqCfg = config.myq;
  if (myqCfg?.enabled && myqCfg.email && myqCfg.password) {
    console.log(`Starting MyQ poller for ${myqCfg.email}...`);
    myqPoller.start();
  } else {
    console.log('MyQ not configured. Add credentials via Settings → Garage.');
  }

  if (config.processor.ip) {
    console.log(
      `Connecting to processor at ${config.processor.ip} (port ${config.processor.port || 'auto'})...`,
    );
    connection.connect(config.processor).catch((err: Error) => {
      console.error('Failed to connect to processor:', err.message);
      console.log('Configure processor via the web UI or PUT /api/config');
    });
  } else {
    console.log('No processor configured. Use the web UI to set up your connection.');
  }
});

// ── Helpers ───────────────────────────────────────────────────────────────────

function zonesAsDeviceConfigs(zones: LEAPZone[]) {
  return zones.map((z) => ({
    integrationId: z.id,
    name: z.name,
    type: (z.controlType === 'Shade' ? 'shade' : 'light') as 'light' | 'shade',
    room: z.areaName,
  }));
}
