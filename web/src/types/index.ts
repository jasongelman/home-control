export type DeviceType = 'light' | 'shade' | 'keypad';

export interface KeypadComponent {
  id: number;
  name: string;
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

export type ConnectionStatus = 'connected' | 'disconnected' | 'connecting';

// ── MyQ / Garage ─────────────────────────────────────────────────────────────

export type DoorState = 'open' | 'closed' | 'opening' | 'closing' | 'stopped' | 'unknown';

export interface MyQDoor {
  serial: string;
  name: string;
  state: DoorState;
  lastUpdated: number;
}

export interface MyQConfig {
  email: string;
  password: string;
  enabled: boolean;
}

// ── WebSocket messages ────────────────────────────────────────────────────────

export type ServerMessage =
  | { type: 'fullState'; devices: DeviceState[]; processorConnected: boolean; doors: MyQDoor[]; myqConnected: boolean }
  | { type: 'state'; deviceId: number; level: number; timestamp: number }
  | { type: 'connected'; processorIp: string }
  | { type: 'disconnected'; reason: string }
  | { type: 'garageState'; doors: MyQDoor[]; myqConnected: boolean }
  | { type: 'error'; message: string }
  | { type: 'pong' };

export type ClientMessage =
  | { type: 'setLevel'; deviceId: number; level: number; fadeTime?: number }
  | { type: 'pressButton'; deviceId: number; component: number }
  | { type: 'releaseButton'; deviceId: number; component: number }
  | { type: 'queryDevice'; deviceId: number }
  | { type: 'garageAction'; serial: string; action: 'open' | 'close' }
  | { type: 'ping' };

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
