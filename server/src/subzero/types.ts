export interface SubZeroConfig {
  accessToken?: string;
  refreshToken?: string;
  tokenExpiresAt?: number;
  subscriptionKey?: string;
  userId?: string;
  enabled: boolean;
}

// ── Refrigerator ────────────────────────────────────────────────────────────

export type RefrigeratorMode = 'normal' | 'vacation' | 'sabbath' | 'night' | 'unknown';
export type DoorState = 'open' | 'closed' | 'unknown';
export type CrisperMode = 'fruit' | 'vegetable' | 'deli' | 'beverage' | 'unknown';

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

// ── Wolf Oven / Range ───────────────────────────────────────────────────────

export type OvenMode =
  | 'off' | 'bake' | 'broil' | 'convection' | 'convection_roast'
  | 'roast' | 'warm' | 'proof' | 'dehydrate' | 'stone'
  | 'gourmet' | 'gourmet_plus' | 'self_clean' | 'sous_vide'
  | 'steam' | 'convection_steam' | 'convection_humid'
  | 'unknown';

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

// ── Cooktop ─────────────────────────────────────────────────────────────────

export interface WolfCooktop {
  applianceId: string;
  applianceName: string;
  model: string;
  online: boolean;
  cooktopOn: boolean;
  lockOn: boolean;
  lastUpdated: number;
}

export type SubZeroAppliance = SubZeroRefrigerator | WolfOven | WolfCooktop;
