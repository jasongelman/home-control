import { readFileSync, writeFileSync, existsSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import type { AppConfig } from './lutron/types.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const CONFIG_PATH = join(__dirname, '..', 'data', 'config.json');

const DEFAULT_CONFIG: AppConfig = {
  processor: {
    ip: '',
    port: 0, // 0 = auto-detect (8081 plain, then 8083 TLS)
    username: 'lutron',
    password: 'integration',
  },
  devices: [],
  myq: {
    email: '',
    password: '',
    enabled: false,
  },
  homeConnect: {
    clientId: '',
    clientSecret: '',
    enabled: false,
  },
  smartHQ: {
    email: '',
    password: '',
    enabled: false,
  },
  myUplink: {
    clientId: '',
    clientSecret: '',
  totalconnect: {
    username: '',
    password: '',
    userCode: '',
    enabled: false,
  },
};

export function loadConfig(): AppConfig {
  if (!existsSync(CONFIG_PATH)) {
    return structuredClone(DEFAULT_CONFIG);
  }
  try {
    const raw = readFileSync(CONFIG_PATH, 'utf-8');
    return JSON.parse(raw) as AppConfig;
  } catch {
    return structuredClone(DEFAULT_CONFIG);
  }
}

export function saveConfig(config: AppConfig): void {
  writeFileSync(CONFIG_PATH, JSON.stringify(config, null, 2), 'utf-8');
}
