// Canonical alarm state for UI — maps many raw TC2 arming codes to 8 states
export type PanelState =
  | 'disarmed'
  | 'armedAway'
  | 'armedHome'
  | 'armedNight'
  | 'alarming'
  | 'arming'
  | 'disarming'
  | 'unknown';

// ArmType integer codes sent in the arm request body
export const ArmType = {
  Away:        0,
  Stay:        1,
  StayInstant: 2,
  AwayInstant: 3,
  Night:       4,
} as const;
export type ArmType = typeof ArmType[keyof typeof ArmType];

export interface TotalConnectConfig {
  username: string;
  password: string;
  userCode: string;  // PIN — stored server-side only, never sent to browser
  enabled: boolean;
}

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
