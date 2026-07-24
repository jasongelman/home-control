export type ChargingStatus = 'idle' | 'pluggedIn' | 'scheduled' | 'charging' | 'complete' | 'error' | 'unknown';

export interface ChargePointCharger {
  chargerId: string;
  accountIndex: number;
  nickname: string;
  status: ChargingStatus;
  isPluggedIn: boolean;
  /** Scheduled start time-of-day (e.g. "12:00 AM") when status is 'scheduled'. */
  scheduledFor?: string | null;
  powerKw: number | null;
  energyKwh: number | null;
  amperage: number;
  maxAmperage: number;
  /**
   * Live/most-recent charging session while the car is plugged in. Cleared
   * (null) the moment `isPluggedIn` goes false. Sourced from the driver-bff
   * charging-activities feed since the /status endpoint carries no telemetry.
   */
  liveSession?: ChargePointSessionStats | null;
  /** Rolling average kWh per week from the persisted on-disk session history. */
  weeklyAvgKwh?: number | null;
  lastUpdated: number;
}

/** Per-session energy stats surfaced on the charger card while plugged in. */
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

/** Longer-term aggregate computed from persisted session history. */
export interface ChargePointWeeklyStats {
  weeklyAvgKwh: number;
  weeks: number;
  totalKwh: number;
  sessionCount: number;
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
