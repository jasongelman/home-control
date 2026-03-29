export interface SmartHQConfig {
  email: string;
  password: string;
  accessToken?: string;
  refreshToken?: string;
  tokenExpiresAt?: number;
  enabled: boolean;
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
