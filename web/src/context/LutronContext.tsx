import { createContext, useContext, type ReactNode } from 'react';
import { useWebSocket } from '../hooks/useWebSocket.js';
import { useUsageTracker } from '../hooks/useUsageTracker.js';
import type { DeviceState, ConnectionStatus, MyQDoor } from '../types/index.js';
import type { UsageEvent } from '../hooks/useUsageTracker.js';

interface LutronContextValue {
  devices: Map<number, DeviceState>;
  connectionStatus: ConnectionStatus;
  processorConnected: boolean;
  setLevel: (deviceId: number, level: number, fadeTime?: number) => void;
  pressButton: (deviceId: number, component: number) => void;
  releaseButton: (deviceId: number, component: number) => void;
  doors: Map<string, MyQDoor>;
  myqConnected: boolean;
  triggerGarage: (serial: string, action: 'open' | 'close') => void;
  trackDevice: (id: number, action: UsageEvent['action'], room?: string, level?: number) => void;
  trackScene: (id: string, name?: string) => void;
  getUsageEvents: () => UsageEvent[];
}

const LutronCtx = createContext<LutronContextValue | null>(null);

export function LutronProvider({ children }: { children: ReactNode }) {
  const ws = useWebSocket();
  const { trackDevice, trackScene, getEvents } = useUsageTracker();
  return (
    <LutronCtx.Provider value={{ ...ws, trackDevice, trackScene, getUsageEvents: getEvents }}>
      {children}
    </LutronCtx.Provider>
  );
}

export function useLutron(): LutronContextValue {
  const ctx = useContext(LutronCtx);
  if (!ctx) throw new Error('useLutron must be used within LutronProvider');
  return ctx;
}
