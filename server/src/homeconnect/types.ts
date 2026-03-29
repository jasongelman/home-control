export interface HomeConnectConfig {
  clientId: string;
  clientSecret: string;
  accessToken?: string;
  refreshToken?: string;
  tokenExpiresAt?: number;
  enabled: boolean;
}

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
