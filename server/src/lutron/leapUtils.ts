/**
 * Shared helpers for mapping LEAP topology to our internal DeviceConfig model.
 */
import type { DeviceConfig } from './types.js';
import type { LEAPZone, LEAPVirtualButton } from './LEAPConnection.js';

/**
 * Convert LEAP zones + virtual buttons into DeviceConfig records suitable
 * for persisting in config.json and loading into the DeviceStore.
 */
export function zonesToDeviceConfigs(
  zones: LEAPZone[],
  virtualButtons: LEAPVirtualButton[] = [],
): DeviceConfig[] {
  const devices: DeviceConfig[] = zones.map((z) => ({
    integrationId: z.id,
    name: z.name,
    type: z.controlType === 'Shade' ? 'shade' : 'light',
    room: z.areaName,
  }));

  // Group virtual buttons by area and create a keypad entry per area
  const buttonsByArea = new Map<number, LEAPVirtualButton[]>();
  for (const btn of virtualButtons) {
    const list = buttonsByArea.get(btn.areaId) ?? [];
    list.push(btn);
    buttonsByArea.set(btn.areaId, list);
  }

  for (const [areaId, buttons] of buttonsByArea) {
    const areaName = buttons[0]?.areaName ?? 'Unassigned';
    // Use a synthetic integration ID: 900000 + areaId to avoid collisions with zone IDs
    const syntheticId = 900_000 + areaId;
    devices.push({
      integrationId: syntheticId,
      name: `${areaName} Keypad`,
      type: 'keypad',
      room: areaName,
      components: buttons.map((b) => ({ id: b.id, name: b.name })),
    });
  }

  return devices;
}
