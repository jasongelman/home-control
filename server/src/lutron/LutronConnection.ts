import { EventEmitter } from 'events';
import type { ProcessorConfig } from './types.js';

export interface LutronConnectionEvents {
  stateChange: (integrationId: number, level: number) => void;
  deviceEvent: (integrationId: number, component: number, action: number) => void;
  connected: () => void;
  disconnected: (reason: string) => void;
  error: (error: Error) => void;
}

export abstract class LutronConnection extends EventEmitter {
  abstract connect(config: ProcessorConfig): Promise<void>;
  abstract disconnect(): Promise<void>;
  abstract setOutput(integrationId: number, level: number, fadeTime?: number): Promise<void>;
  abstract queryOutput(integrationId: number): Promise<number>;
  abstract pressButton(deviceId: number, component: number): Promise<void>;
  abstract releaseButton(deviceId: number, component: number): Promise<void>;
  abstract get isConnected(): boolean;
}
