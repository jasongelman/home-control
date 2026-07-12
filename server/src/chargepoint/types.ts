export type ChargingStatus = 'idle' | 'pluggedIn' | 'charging' | 'complete' | 'error' | 'unknown';

export interface ChargePointCharger {
  chargerId: string;
  accountIndex: number;
  nickname: string;
  status: ChargingStatus;
  isPluggedIn: boolean;
  powerKw: number | null;
  energyKwh: number | null;
  amperage: number;
  maxAmperage: number;
  lastUpdated: number;
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

export interface ChargePointAccountConfig {
  email: string;
  password: string;
  nickname: string;
}

export interface ChargePointConfig {
  accounts: ChargePointAccountConfig[];
  enabled: boolean;
}
