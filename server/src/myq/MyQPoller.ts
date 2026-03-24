import { EventEmitter } from 'events';
import type { MyQDoor, MyQConfig } from './types.js';
import { login, getDoors, setDoorAction, type MyQSession } from './MyQClient.js';

const POLL_INTERVAL = 10_000; // 10s
const TOKEN_TTL = 20 * 60 * 1000; // 20 minutes — refresh before MyQ expires the token

export class MyQPoller extends EventEmitter {
  private config: MyQConfig;
  private session: MyQSession | null = null;
  private sessionExpiry = 0;
  private doors: Map<string, MyQDoor> = new Map();
  private pollTimer: ReturnType<typeof setInterval> | null = null;
  private _connected = false;

  constructor(config: MyQConfig) {
    super();
    this.config = config;
  }

  get isConnected(): boolean {
    return this._connected;
  }

  getDoors(): MyQDoor[] {
    return Array.from(this.doors.values());
  }

  updateConfig(config: MyQConfig): void {
    this.config = config;
    // Force re-auth on credential change
    this.session = null;
    this.sessionExpiry = 0;

    if (config.enabled && config.email && config.password) {
      if (!this.pollTimer) this.start();
      else this.poll(); // immediate re-poll with new creds
    } else {
      this.stop();
    }
  }

  start(): void {
    if (this.pollTimer) return;
    void this.poll(); // immediate first poll
    this.pollTimer = setInterval(() => { void this.poll(); }, POLL_INTERVAL);
  }

  stop(): void {
    if (this.pollTimer) {
      clearInterval(this.pollTimer);
      this.pollTimer = null;
    }
    this.session = null;
    this._connected = false;
    this.doors.clear();
  }

  async triggerAction(serial: string, action: 'open' | 'close'): Promise<void> {
    const session = await this.getSession();
    await setDoorAction(session, serial, action);

    // Optimistic state update while MyQ processes the command
    const door = this.doors.get(serial);
    if (door) {
      this.doors.set(serial, {
        ...door,
        state: action === 'open' ? 'opening' : 'closing',
        lastUpdated: Date.now(),
      });
      this.emit('stateChange', this.getDoors());
    }
  }

  private async getSession(): Promise<MyQSession> {
    if (this.session && Date.now() < this.sessionExpiry) return this.session;
    const session = await login(this.config.email, this.config.password);
    this.session = session;
    this.sessionExpiry = Date.now() + TOKEN_TTL;
    return session;
  }

  private async poll(): Promise<void> {
    if (!this.config.enabled || !this.config.email || !this.config.password) return;

    try {
      const session = await this.getSession();
      const doors = await getDoors(session);

      let changed = false;
      for (const door of doors) {
        const prev = this.doors.get(door.serial);
        if (!prev || prev.state !== door.state) changed = true;
        this.doors.set(door.serial, door);
      }

      if (!this._connected) {
        this._connected = true;
        this.emit('connected');
        this.emit('stateChange', this.getDoors());
      } else if (changed) {
        this.emit('stateChange', this.getDoors());
      }
    } catch (err) {
      const wasConnected = this._connected;
      this._connected = false;
      this.session = null;
      this.sessionExpiry = 0;
      if (wasConnected) this.emit('disconnected', (err as Error).message);
      this.emit('error', err as Error);
      console.error('MyQ poll error:', (err as Error).message);
    }
  }
}
