export interface ProcessorConfig {
  ip: string;
  /** 0 = auto-detect (try 8081 then 8083). Set by LEAPConnection after successful connect. */
  port: number;
  username: string;
  password: string;
}

export type DeviceType = 'light' | 'shade' | 'keypad';

export interface KeypadComponent {
  id: number;
  name: string;
}

export interface DeviceConfig {
  integrationId: number;
  name: string;
  type: DeviceType;
  room: string;
  components?: KeypadComponent[];
}

export interface DeviceState {
  integrationId: number;
  name: string;
  type: DeviceType;
  room: string;
  level: number;
  components?: KeypadComponent[];
  lastUpdated: number;
}

// ── Scenes ──────────────────────────────────────────────────────────────────

export interface SceneDeviceTarget {
  deviceId: number;
  level: number;
}

export interface Scene {
  id: string;
  name: string;
  icon: string;
  targets: SceneDeviceTarget[];
  createdAt: number;
  updatedAt: number;
}

// ── Sun-shade Automations ────────────────────────────────────────────────────

export interface AutomationShadeTarget {
  deviceId: number;
  /** Level (0–100) to set when sun enters the window. */
  downLevel: number;
  /** Level (0–100) to restore when sun leaves the window. */
  upLevel: number;
}

export interface SunAzimuthTrigger {
  type: 'sun-azimuth';
  /** Lower bound of sun azimuth (degrees from north) that activates shades. */
  azimuthMin: number;
  /** Upper bound of sun azimuth (degrees from north) that activates shades. */
  azimuthMax: number;
  /** Minimum sun altitude (degrees above horizon) required to activate. */
  altitudeMin: number;
}

export interface AutomationConfig {
  id: string;
  name: string;
  enabled: boolean;
  location: { lat: number; lon: number };
  trigger: SunAzimuthTrigger;
  shades: AutomationShadeTarget[];
  /** Fade duration in seconds when moving shades. */
  fadeSeconds: number;
  /** Weather-based gate. If omitted, weather is not checked. */
  weather?: {
    /** Cloud cover % above which the sun is considered blocked. Default 75. */
    cloudCoverThreshold: number;
  };
}

export interface AppConfig {
  processor: ProcessorConfig;
  devices: DeviceConfig[];
  scenes?: Scene[];
  myq?: MyQConfig;
  totalconnect?: TotalConnectConfig;
  automations?: AutomationConfig[];
}

// ── MyQ ──────────────────────────────────────────────────────────────────────

export interface MyQConfig {
  email: string;
  password: string;
  enabled: boolean;
}

export type DoorState = 'open' | 'closed' | 'opening' | 'closing' | 'stopped' | 'unknown';

export interface MyQDoor {
  serial: string;
  name: string;
  state: DoorState;
  lastUpdated: number;
}

// ── Total Connect 2.0 (Resideo Alarm) ────────────────────────────────────────

export interface TotalConnectConfig {
  username: string;
  password: string;
  userCode: string;
  enabled: boolean;
}

export type PanelState =
  | 'disarmed' | 'armedAway' | 'armedHome' | 'armedNight'
  | 'alarming' | 'arming' | 'disarming' | 'unknown';

export interface AlarmPanel {
  locationId: string;
  securityDeviceId: string;
  name: string;
  state: PanelState;
  rawArmingState: number;
  partitionIds: number[];
  lastUpdated: number;
}

export interface AlarmZone {
  zoneId: number;
  name: string;
  faulted: boolean;
  bypassed: boolean;
  lowBattery: boolean;
}

// ── WebSocket message types ───────────────────────────────────────────────────

export type ServerMessage =
  | { type: 'fullState'; devices: DeviceState[]; processorConnected: boolean; doors: MyQDoor[]; myqConnected: boolean; panels: AlarmPanel[]; alarmConnected: boolean }
  | { type: 'state'; deviceId: number; level: number; timestamp: number }
  | { type: 'connected'; processorIp: string }
  | { type: 'disconnected'; reason: string }
  | { type: 'garageState'; doors: MyQDoor[]; myqConnected: boolean }
  | { type: 'alarmState'; panels: AlarmPanel[]; alarmConnected: boolean }
  | { type: 'error'; message: string }
  | { type: 'pong' };

export type ClientMessage =
  | { type: 'setLevel'; deviceId: number; level: number; fadeTime?: number }
  | { type: 'pressButton'; deviceId: number; component: number }
  | { type: 'releaseButton'; deviceId: number; component: number }
  | { type: 'queryDevice'; deviceId: number }
  | { type: 'garageAction'; serial: string; action: 'open' | 'close' }
  | { type: 'alarmAction'; locationId: string; action: 'armAway' | 'armHome' | 'armNight' | 'disarm' }
  | { type: 'ping' };
