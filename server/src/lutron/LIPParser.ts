export interface OutputEvent {
  kind: 'output';
  integrationId: number;
  action: number;
  level: number;
}

export interface DeviceEvent {
  kind: 'device';
  integrationId: number;
  component: number;
  action: number;
}

export interface PromptEvent {
  kind: 'prompt';
  promptType: 'login' | 'password' | 'gnet';
}

export type LIPEvent = OutputEvent | DeviceEvent | PromptEvent;

export function parseLIPLine(line: string): LIPEvent | null {
  const trimmed = line.trim();

  if (trimmed === 'login:' || trimmed === 'login: ') {
    return { kind: 'prompt', promptType: 'login' };
  }
  if (trimmed === 'password:' || trimmed === 'password: ') {
    return { kind: 'prompt', promptType: 'password' };
  }
  if (trimmed === 'GNET>' || trimmed === 'QNET>') {
    return { kind: 'prompt', promptType: 'gnet' };
  }

  // ~OUTPUT,<id>,<action>,<level>
  if (trimmed.startsWith('~OUTPUT,')) {
    const parts = trimmed.substring(8).split(',');
    if (parts.length >= 3) {
      return {
        kind: 'output',
        integrationId: parseInt(parts[0], 10),
        action: parseInt(parts[1], 10),
        level: parseFloat(parts[2]),
      };
    }
  }

  // ~DEVICE,<id>,<component>,<action>
  if (trimmed.startsWith('~DEVICE,')) {
    const parts = trimmed.substring(8).split(',');
    if (parts.length >= 3) {
      return {
        kind: 'device',
        integrationId: parseInt(parts[0], 10),
        component: parseInt(parts[1], 10),
        action: parseInt(parts[2], 10),
      };
    }
  }

  return null;
}
