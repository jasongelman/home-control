export interface MyUplinkConfig {
  clientId: string;
  clientSecret: string;
  accessToken?: string;
  refreshToken?: string;
  tokenExpiresAt?: number;
  enabled: boolean;
}

export type HeatPumpMode = 'heating' | 'cooling' | 'auto' | 'off' | 'unknown';

export interface HeatPumpStatus {
  systemId: string;
  deviceId: string;
  deviceName: string;
  connected: boolean;
  outdoorTemp: number | null;     // °F
  supplyTemp: number | null;      // °F
  returnTemp: number | null;      // °F
  setpointTemp: number | null;    // °F
  mode: HeatPumpMode;
  compressorFreq: number | null;  // Hz
  lastUpdated: number;
}
