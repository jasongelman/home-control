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

// ── Appliances ───────────────────────────────────────────────────────────────

export type DishwasherOpState =
  | 'inactive' | 'ready' | 'delayedStart' | 'run'
  | 'pause' | 'actionRequired' | 'finished' | 'error'
  | 'aborting' | 'unknown';

export interface DishwasherStatus {
  applianceId: string;
  applianceName: string;
  connected: boolean;
  operationState: DishwasherOpState;
  doorState: 'open' | 'closed' | 'locked' | 'unknown';
  remoteControlActive: boolean;
  remainingTime: number | null;  // seconds
  progress: number | null;       // 0-100
  activeProgram: string | null;
  lastUpdated: number;
}

export type LaundryMachineState = 'off' | 'standby' | 'running' | 'paused' | 'complete' | 'delayed' | 'error';

export interface LaundryAppliance {
  applianceId: string;
  applianceName: string;
  applianceType: string; // 'Washer' or 'Dryer'
  online: boolean;
  machineState: LaundryMachineState;
  remainingMinutes: number | null;
  cycleName: string | null;
  doorLocked: boolean;
  soilLevel: string | null;
  washTemp: string | null;
  spinSpeed: string | null;
  dryLevel: string | null;
  dryTemp: string | null;
  lastUpdated: number;
}

export type HeatPumpMode = 'heating' | 'cooling' | 'auto' | 'off' | 'unknown';

export interface HeatPumpStatus {
  systemId: string;
  deviceId: string;
  deviceName: string;
  connected: boolean;
  outdoorTemp: number | null;
  supplyTemp: number | null;
  returnTemp: number | null;
  setpointTemp: number | null;
  mode: HeatPumpMode;
  compressorFreq: number | null;
  lastUpdated: number;
}

// ── Total Connect 2.0 (Resideo Alarm) ────────────────────────────────────────

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

// ── WebSocket messages ────────────────────────────────────────────────────────

export type ServerMessage =
  | {
      type: 'fullState';
      devices: DeviceState[];
      processorConnected: boolean;
      doors: MyQDoor[];
      myqConnected: boolean;
      dishwashers: DishwasherStatus[];
      laundry: LaundryAppliance[];
      heatPumps: HeatPumpStatus[];
      homeConnectLinked: boolean;
      smartHQLinked: boolean;
      myUplinkLinked: boolean;
      panels: AlarmPanel[];
      alarmConnected: boolean;
    }
  | { type: 'state'; deviceId: number; level: number; timestamp: number }
  | { type: 'connected'; processorIp: string }
  | { type: 'disconnected'; reason: string }
  | { type: 'garageState'; doors: MyQDoor[]; myqConnected: boolean }
  | { type: 'applianceState'; dishwashers: DishwasherStatus[]; laundry: LaundryAppliance[]; heatPumps: HeatPumpStatus[] }
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
