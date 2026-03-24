import * as net from 'net';
import { LutronConnection } from './LutronConnection.js';
import { parseLIPLine } from './LIPParser.js';
import type { ProcessorConfig } from './types.js';

const COMMAND_DELAY_MS = 50;
const RECONNECT_DELAYS = [5000, 10000, 20000, 40000, 60000];

export class LIPConnection extends LutronConnection {
  private socket: net.Socket | null = null;
  private config: ProcessorConfig | null = null;
  private buffer = '';
  private _isConnected = false;
  private reconnectAttempt = 0;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private commandQueue: string[] = [];
  private processingQueue = false;
  private pendingQueries = new Map<number, (level: number) => void>();
  private shouldReconnect = true;

  get isConnected(): boolean {
    return this._isConnected;
  }

  async connect(config: ProcessorConfig): Promise<void> {
    this.config = config;
    this.shouldReconnect = true;
    this.reconnectAttempt = 0;
    return this.doConnect();
  }

  private doConnect(): Promise<void> {
    return new Promise((resolve, reject) => {
      if (!this.config) {
        reject(new Error('No config'));
        return;
      }

      this.socket = new net.Socket();
      this.buffer = '';
      let resolved = false;

      this.socket.setTimeout(10000);

      this.socket.on('timeout', () => {
        if (!resolved) {
          resolved = true;
          reject(new Error('Connection timeout'));
        }
        this.socket?.destroy();
      });

      this.socket.on('data', (data) => {
        this.buffer += data.toString();
        const lines = this.buffer.split('\r\n');
        this.buffer = lines.pop() || '';

        // Check if buffer contains an inline prompt (no \r\n terminator)
        const bufferTrimmed = this.buffer.trim();
        if (bufferTrimmed === 'login:' || bufferTrimmed === 'password:' || bufferTrimmed === 'GNET>' || bufferTrimmed === 'QNET>') {
          lines.push(this.buffer);
          this.buffer = '';
        }

        for (const line of lines) {
          if (!line) continue;
          const event = parseLIPLine(line);
          if (!event) continue;

          if (event.kind === 'prompt') {
            if (event.promptType === 'login') {
              this.sendRaw(this.config!.username);
            } else if (event.promptType === 'password') {
              this.sendRaw(this.config!.password);
            } else if (event.promptType === 'gnet') {
              if (!this._isConnected) {
                this._isConnected = true;
                this.reconnectAttempt = 0;
                // Disable idle timeout now that we're authenticated
                this.socket?.setTimeout(0);
                // Enable monitoring for unsolicited state updates
                this.sendRaw('#MONITORING,255,1');
                this.emit('connected');
                if (!resolved) {
                  resolved = true;
                  resolve();
                }
              }
            }
          } else if (event.kind === 'output') {
            // Check if this is a response to a pending query
            const pending = this.pendingQueries.get(event.integrationId);
            if (pending) {
              this.pendingQueries.delete(event.integrationId);
              pending(event.level);
            }
            this.emit('stateChange', event.integrationId, event.level);
          } else if (event.kind === 'device') {
            this.emit('deviceEvent', event.integrationId, event.component, event.action);
          }
        }
      });

      this.socket.on('error', (err) => {
        this.emit('error', err);
        if (!resolved) {
          resolved = true;
          reject(err);
        }
      });

      this.socket.on('close', () => {
        const wasConnected = this._isConnected;
        this._isConnected = false;
        this.commandQueue = [];
        this.processingQueue = false;
        this.pendingQueries.clear();

        if (wasConnected) {
          this.emit('disconnected', 'connection closed');
        }

        if (this.shouldReconnect && this.config) {
          this.scheduleReconnect();
        }
      });

      this.socket.connect(this.config.port, this.config.ip);
    });
  }

  private scheduleReconnect(): void {
    if (this.reconnectTimer) return;
    const delay = RECONNECT_DELAYS[Math.min(this.reconnectAttempt, RECONNECT_DELAYS.length - 1)];
    this.reconnectAttempt++;
    console.log(`Reconnecting in ${delay / 1000}s (attempt ${this.reconnectAttempt})...`);
    this.reconnectTimer = setTimeout(async () => {
      this.reconnectTimer = null;
      try {
        await this.doConnect();
      } catch {
        // doConnect failure will trigger 'close' which schedules another reconnect
      }
    }, delay);
  }

  async disconnect(): Promise<void> {
    this.shouldReconnect = false;
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    if (this.socket) {
      this.socket.destroy();
      this.socket = null;
    }
    this._isConnected = false;
  }

  async setOutput(integrationId: number, level: number, fadeTime?: number): Promise<void> {
    const clampedLevel = Math.max(0, Math.min(100, level));
    let cmd = `#OUTPUT,${integrationId},1,${clampedLevel.toFixed(2)}`;
    if (fadeTime !== undefined) {
      cmd += `,${fadeTime.toFixed(2)}`;
    }
    this.queueCommand(cmd);
  }

  async queryOutput(integrationId: number): Promise<number> {
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.pendingQueries.delete(integrationId);
        reject(new Error(`Query timeout for device ${integrationId}`));
      }, 5000);

      this.pendingQueries.set(integrationId, (level) => {
        clearTimeout(timeout);
        resolve(level);
      });

      this.queueCommand(`?OUTPUT,${integrationId},1`);
    });
  }

  async pressButton(deviceId: number, component: number): Promise<void> {
    this.queueCommand(`#DEVICE,${deviceId},${component},3`);
  }

  async releaseButton(deviceId: number, component: number): Promise<void> {
    this.queueCommand(`#DEVICE,${deviceId},${component},4`);
  }

  private sendRaw(data: string): void {
    this.socket?.write(data + '\r\n');
  }

  private queueCommand(cmd: string): void {
    this.commandQueue.push(cmd);
    if (!this.processingQueue) {
      this.processQueue();
    }
  }

  private async processQueue(): Promise<void> {
    this.processingQueue = true;
    while (this.commandQueue.length > 0 && this._isConnected) {
      const cmd = this.commandQueue.shift()!;
      this.sendRaw(cmd);
      if (this.commandQueue.length > 0) {
        await new Promise((r) => setTimeout(r, COMMAND_DELAY_MS));
      }
    }
    this.processingQueue = false;
  }
}
