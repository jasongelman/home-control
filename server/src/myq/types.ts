export type DoorState = 'open' | 'closed' | 'opening' | 'closing' | 'stopped' | 'unknown';

export interface MyQConfig {
  email: string;
  password: string;
  enabled: boolean;
}

export interface MyQDoor {
  serial: string;
  name: string;
  state: DoorState;
  lastUpdated: number;
}
