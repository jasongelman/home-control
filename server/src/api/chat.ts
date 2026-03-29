import Anthropic from '@anthropic-ai/sdk';
import type { DeviceStore } from '../state/DeviceStore.js';
import type { LEAPConnection } from '../lutron/LEAPConnection.js';
import type { MyQPoller } from '../myq/MyQPoller.js';
import type { AppConfig, Scene } from '../lutron/types.js';

// ── Types ───────────────────────────────────────────────────────────────────

export interface ChatMessage {
  role: 'user' | 'assistant';
  content: string;
}

export interface ChatRequest {
  message: string;
  history?: ChatMessage[];
}

export interface ActionTaken {
  type: string;
  description: string;
}

export interface ChatResponse {
  reply: string;
  actions: ActionTaken[];
}

// ── Claude tool definitions ─────────────────────────────────────────────────

const TOOLS: Anthropic.Tool[] = [
  {
    name: 'set_device_level',
    description:
      'Set a light or shade to a specific level (0-100). For lights, 0=off, 100=full brightness. For shades, 0=fully closed, 100=fully open.',
    input_schema: {
      type: 'object' as const,
      properties: {
        deviceId: { type: 'number', description: 'The integration ID of the device' },
        level: { type: 'number', description: 'Target level 0-100' },
        fadeTime: { type: 'number', description: 'Fade duration in seconds (default 1)' },
      },
      required: ['deviceId', 'level'],
    },
  },
  {
    name: 'garage_action',
    description: 'Open or close a garage door.',
    input_schema: {
      type: 'object' as const,
      properties: {
        serial: { type: 'string', description: 'The garage door serial number' },
        action: { type: 'string', enum: ['open', 'close'], description: 'Action to perform' },
      },
      required: ['serial', 'action'],
    },
  },
  {
    name: 'activate_scene',
    description: 'Activate a saved scene by its ID, which sets multiple devices to their saved levels.',
    input_schema: {
      type: 'object' as const,
      properties: {
        sceneId: { type: 'string', description: 'The scene UUID' },
      },
      required: ['sceneId'],
    },
  },
];

// ── System prompt builder ───────────────────────────────────────────────────

function buildSystemPrompt(
  deviceStore: DeviceStore,
  myqPoller: MyQPoller,
  scenes: Scene[],
): string {
  const devices = deviceStore.getAllDevices();

  // Group by room
  const byRoom = new Map<string, typeof devices>();
  for (const d of devices) {
    const list = byRoom.get(d.room) || [];
    list.push(d);
    byRoom.set(d.room, list);
  }

  let deviceList = '';
  for (const [room, devs] of byRoom) {
    deviceList += `\n## ${room}\n`;
    for (const d of devs) {
      let status = '';
      if (d.type === 'light') {
        status = d.level > 0 ? `ON at ${d.level}%` : 'OFF';
      } else if (d.type === 'shade') {
        status = d.level === 100 ? 'fully open' : d.level === 0 ? 'fully closed' : `${d.level}% open`;
      }
      deviceList += `- ${d.name} (id: ${d.integrationId}, type: ${d.type}) — ${status}\n`;
    }
  }

  const doors = myqPoller.getDoors();
  let garageList = '';
  for (const door of doors) {
    garageList += `- ${door.name} (serial: ${door.serial}) — ${door.state}\n`;
  }

  let sceneList = '';
  for (const s of scenes) {
    sceneList += `- "${s.name}" (id: ${s.id}) — sets ${s.targets.length} devices\n`;
  }

  return `You are a home automation assistant for a smart home. You help the user control their lights, shades, garage doors, and scenes using natural language.

DEVICES AND CURRENT STATE:
${deviceList || 'No devices configured.'}

GARAGE DOORS:
${garageList || 'None configured.'}

SAVED SCENES:
${sceneList || 'None saved.'}

RULES:
- For lights: level 0 = off, 100 = full brightness. Use set_device_level.
- For shades: level 0 = fully closed, 100 = fully open. Use set_device_level.
- When the user says "turn off all lights", set every light to level 0.
- When the user says "close all shades", set every shade to level 0.
- For ambiguous requests, use your best judgment based on room/device names.
- If a request matches a saved scene, prefer activate_scene.
- For status queries ("what's on?"), describe the current state without tool calls.
- Be concise and friendly. Confirm what you did after executing commands.
- Use a 1-second fade time unless the user specifies otherwise.`;
}

// ── Action executor ─────────────────────────────────────────────────────────

async function executeToolCall(
  toolName: string,
  toolInput: Record<string, unknown>,
  connection: LEAPConnection,
  myqPoller: MyQPoller,
  scenes: Scene[],
  deviceStore: DeviceStore,
): Promise<{ result: string; action: ActionTaken }> {
  switch (toolName) {
    case 'set_device_level': {
      const { deviceId, level, fadeTime } = toolInput as {
        deviceId: number;
        level: number;
        fadeTime?: number;
      };
      const device = deviceStore.getDevice(deviceId);
      const name = device?.name ?? `Device ${deviceId}`;
      await connection.setLevel(deviceId, level, fadeTime ?? 1);
      const desc =
        device?.type === 'shade'
          ? `Set ${name} to ${level}% open`
          : level === 0
            ? `Turned off ${name}`
            : `Set ${name} to ${level}%`;
      return { result: `OK: ${desc}`, action: { type: 'set_device_level', description: desc } };
    }

    case 'garage_action': {
      const { serial, action } = toolInput as { serial: string; action: 'open' | 'close' };
      const doors = myqPoller.getDoors();
      const door = doors.find((d) => d.serial === serial);
      const name = door?.name ?? serial;
      await myqPoller.triggerAction(serial, action);
      const desc = `${action === 'open' ? 'Opened' : 'Closed'} ${name}`;
      return { result: `OK: ${desc}`, action: { type: 'garage_action', description: desc } };
    }

    case 'activate_scene': {
      const { sceneId } = toolInput as { sceneId: string };
      const scene = scenes.find((s) => s.id === sceneId);
      if (!scene) throw new Error(`Scene not found: ${sceneId}`);
      await Promise.allSettled(
        scene.targets.map((t) => connection.setLevel(t.deviceId, t.level, 2)),
      );
      const desc = `Activated scene "${scene.name}"`;
      return { result: `OK: ${desc}`, action: { type: 'activate_scene', description: desc } };
    }

    default:
      throw new Error(`Unknown tool: ${toolName}`);
  }
}

// ── Main handler ────────────────────────────────────────────────────────────

export async function handleChat(
  message: string,
  history: ChatMessage[],
  deviceStore: DeviceStore,
  connection: LEAPConnection,
  myqPoller: MyQPoller,
  config: AppConfig,
): Promise<ChatResponse> {
  const apiKey = config.anthropicApiKey || process.env.ANTHROPIC_API_KEY;
  if (!apiKey) {
    return {
      reply: 'The AI assistant is not configured yet. Please add your Anthropic API key in Settings.',
      actions: [],
    };
  }

  const client = new Anthropic({ apiKey });
  const scenes = config.scenes ?? [];
  const systemPrompt = buildSystemPrompt(deviceStore, myqPoller, scenes);

  // Build messages from history + new message
  const messages: Anthropic.MessageParam[] = [
    ...history.slice(-20).map((m) => ({
      role: m.role as 'user' | 'assistant',
      content: m.content,
    })),
    { role: 'user', content: message },
  ];

  const actions: ActionTaken[] = [];

  // Call Claude with tools
  let response = await client.messages.create({
    model: 'claude-sonnet-4-20250514',
    max_tokens: 1024,
    system: systemPrompt,
    tools: TOOLS,
    messages,
  });

  // Process tool calls in a loop (Claude may return multiple)
  while (response.stop_reason === 'tool_use') {
    const toolUseBlocks = response.content.filter(
      (b): b is Anthropic.ToolUseBlock => b.type === 'tool_use',
    );

    const toolResults: Anthropic.ToolResultBlockParam[] = [];

    for (const block of toolUseBlocks) {
      try {
        const { result, action } = await executeToolCall(
          block.name,
          block.input as Record<string, unknown>,
          connection,
          myqPoller,
          scenes,
          deviceStore,
        );
        actions.push(action);
        toolResults.push({ type: 'tool_result', tool_use_id: block.id, content: result });
      } catch (err) {
        toolResults.push({
          type: 'tool_result',
          tool_use_id: block.id,
          content: `Error: ${String(err)}`,
          is_error: true,
        });
      }
    }

    // Continue the conversation with tool results
    messages.push({ role: 'assistant', content: response.content.map((b) => {
      if (b.type === 'tool_use') {
        return { type: 'tool_use' as const, id: b.id, name: b.name, input: b.input };
      }
      return { type: 'text' as const, text: (b as Anthropic.TextBlock).text };
    }) });
    messages.push({ role: 'user', content: toolResults });

    response = await client.messages.create({
      model: 'claude-sonnet-4-20250514',
      max_tokens: 1024,
      system: systemPrompt,
      tools: TOOLS,
      messages,
    });
  }

  // Extract text from final response
  const textBlocks = response.content.filter(
    (b): b is Anthropic.TextBlock => b.type === 'text',
  );
  const reply = textBlocks.map((b) => b.text).join('\n') || 'Done!';

  return { reply, actions };
}
