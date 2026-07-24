import { EventEmitter } from 'events';
import type { DeviceConfig, DeviceState } from '../lutron/types.js';
import { isColorRoom } from '../lutron/LEAPConnection.js';

export class DeviceStore extends EventEmitter {
  private devices = new Map<number, DeviceState>();

  loadFromConfig(configs: DeviceConfig[]): void {
    this.devices.clear();
    for (const config of configs) {
      this.devices.set(config.integrationId, {
        integrationId: config.integrationId,
        name: config.name,
        type: config.type,
        room: config.room,
        level: 0,
        colorCapable: config.type === 'light' && isColorRoom(config.room),
        hsv: null,
        components: config.components,
        lastUpdated: Date.now(),
      });
    }
  }

  updateLevel(integrationId: number, level: number): void {
    const device = this.devices.get(integrationId);
    if (device) {
      device.level = level;
      device.lastUpdated = Date.now();
      this.emit('stateChange', integrationId, level);
    }
  }

  /** Record the last color set on a color-capable zone (optimistic). */
  updateColor(integrationId: number, hue: number, saturation: number): void {
    const device = this.devices.get(integrationId);
    if (device) {
      device.hsv = { hue, saturation };
      device.lastUpdated = Date.now();
    }
  }

  getDevice(integrationId: number): DeviceState | undefined {
    return this.devices.get(integrationId);
  }

  getAllDevices(): DeviceState[] {
    return Array.from(this.devices.values());
  }

  getDevicesByRoom(): Map<string, DeviceState[]> {
    const rooms = new Map<string, DeviceState[]>();
    for (const device of this.devices.values()) {
      const list = rooms.get(device.room) || [];
      list.push(device);
      rooms.set(device.room, list);
    }
    return rooms;
  }

  addDevice(config: DeviceConfig): void {
    this.devices.set(config.integrationId, {
      ...config,
      level: 0,
      lastUpdated: Date.now(),
    });
  }

  removeDevice(integrationId: number): void {
    this.devices.delete(integrationId);
  }

  has(integrationId: number): boolean {
    return this.devices.has(integrationId);
  }
}
