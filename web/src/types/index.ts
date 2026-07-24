export type DeviceType = 'light' | 'shade' | 'keypad';

export interface KeypadComponent {
  id: number;
  name: string;
}

// Physical Lutron keypad with per-button LED state (mirrors server LEAPKeypad).
export interface KeypadButtonInfo {
  id: number;
  buttonNumber: number;
  name: string;
  engraving: string;
  ledId: number | null;
  ledState: 'On' | 'Off' | 'Unknown';
}

export interface KeypadInfo {
  deviceId: number;
  name: string;
  deviceType: string;
  modelNumber: string;
  areaName: string;
  buttons: KeypadButtonInfo[];
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

// ── ChargePoint / EV Charging ────────────────────────────────────────────────

export type ChargingStatus = 'idle' | 'pluggedIn' | 'scheduled' | 'charging' | 'complete' | 'error' | 'unknown';

export interface ChargePointCharger {
  chargerId: string;
  accountIndex: number;
  nickname: string;
  status: ChargingStatus;
  isPluggedIn: boolean;
  scheduledFor?: string | null;
  powerKw: number | null;
  energyKwh: number | null;
  amperage: number;
  maxAmperage: number;
  /** Live/most-recent session while plugged in; null when unplugged. */
  liveSession?: ChargePointSessionStats | null;
  /** Rolling average kWh per week from persisted history. */
  weeklyAvgKwh?: number | null;
  lastUpdated: number;
}

export interface ChargePointSessionStats {
  energyKwh: number;
  cost: number | null;
  milesAdded: number | null;
  startTime: number;
  /** null => session still in progress. */
  endTime: number | null;
  durationSeconds: number;
}

export interface ChargePointSession {
  sessionId: string;
  chargerId: string;
  startTime: number;
  endTime: number | null;
  energyKwh: number;
  cost: number | null;
  milesAdded: number | null;
}

export interface ChargePointWeeklyStats {
  weeklyAvgKwh: number;
  weeks: number;
  totalKwh: number;
  sessionCount: number;
}

// ── Sub-Zero / Wolf ─────────────────────────────────────────────────────────

export type RefrigeratorMode = 'normal' | 'vacation' | 'sabbath' | 'night' | 'unknown';

export type OvenMode =
  | 'off' | 'bake' | 'broil' | 'convection' | 'convection_roast'
  | 'roast' | 'warm' | 'proof' | 'dehydrate' | 'stone'
  | 'gourmet' | 'gourmet_plus' | 'self_clean' | 'sous_vide'
  | 'steam' | 'convection_steam' | 'convection_humid'
  | 'unknown';

export interface SubZeroRefrigerator {
  applianceId: string;
  applianceName: string;
  model: string;
  online: boolean;
  fridgeTemp: number | null;
  freezerTemp: number | null;
  fridgeSetpoint: number | null;
  freezerSetpoint: number | null;
  crisperSetpoint: number | null;
  fridgeDoorOpen: boolean;
  freezerDoorOpen: boolean;
  iceMakerOn: boolean;
  maxIceOn: boolean;
  mode: RefrigeratorMode;
  nightMode: boolean;
  lightOn: boolean;
  waterFilterPct: number | null;
  airPurificationPct: number | null;
  humidityControl: string | null;
  lastUpdated: number;
}

export interface WolfOven {
  applianceId: string;
  applianceName: string;
  model: string;
  online: boolean;
  unitOn: boolean;
  currentTemp: number | null;
  targetTemp: number | null;
  cookMode: OvenMode;
  probeTemp: number | null;
  probeTargetTemp: number | null;
  timerRemaining: number | null;
  timer2Remaining: number | null;
  remoteReady: boolean;
  lightOn: boolean;
  lastUpdated: number;
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
      chargers: ChargePointCharger[];
      chargePointConnected: boolean;
      refrigerators: SubZeroRefrigerator[];
      ovens: WolfOven[];
      subZeroLinked: boolean;
      keypads: KeypadInfo[];
    }
  | { type: 'keypadsState'; keypads: KeypadInfo[] }
  | { type: 'ledState'; keypadId: number; ledId: number; state: 'On' | 'Off' }
  | { type: 'state'; deviceId: number; level: number; timestamp: number }
  | { type: 'connected'; processorIp: string }
  | { type: 'disconnected'; reason: string }
  | { type: 'garageState'; doors: MyQDoor[]; myqConnected: boolean }
  | { type: 'applianceState'; dishwashers: DishwasherStatus[]; laundry: LaundryAppliance[]; heatPumps: HeatPumpStatus[] }
  | { type: 'alarmState'; panels: AlarmPanel[]; alarmConnected: boolean }
  | { type: 'chargerState'; chargers: ChargePointCharger[]; chargePointConnected: boolean }
  | { type: 'subZeroState'; refrigerators: SubZeroRefrigerator[]; ovens: WolfOven[]; subZeroLinked: boolean }
  | { type: 'error'; message: string }
  | { type: 'pong' };

export type ClientMessage =
  | { type: 'setLevel'; deviceId: number; level: number; fadeTime?: number }
  | { type: 'pressButton'; deviceId: number; component: number }
  | { type: 'releaseButton'; deviceId: number; component: number }
  | { type: 'queryDevice'; deviceId: number }
  | { type: 'garageAction'; serial: string; action: 'open' | 'close' }
  | { type: 'alarmAction'; locationId: string; action: 'armAway' | 'armHome' | 'armNight' | 'disarm' }
  | { type: 'chargerAction'; chargerId: string; action: 'setAmperage'; value: number }
  | { type: 'subZeroAction'; applianceId: string; action: 'setFridgeTemp' | 'setFreezerTemp' | 'setCrisperTemp' | 'setIceMaker' | 'setMaxIce' | 'setNightMode' | 'setHumidityControl' | 'toggleLight' | 'toggleOvenLight' | 'setKitchenTimer' | 'cancelKitchenTimer' | 'setProperty' | 'refresh'; property?: string; value?: unknown; timer?: number }
  | { type: 'setLEDState'; ledId: number; state: 'On' | 'Off' }
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
