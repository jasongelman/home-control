import type { WebSocket } from 'ws';
import type { ServerMessage } from '../lutron/types.js';

export class StateSync {
  private clients = new Set<WebSocket>();

  addClient(ws: WebSocket): void {
    this.clients.add(ws);
    ws.on('close', () => this.clients.delete(ws));
  }

  removeClient(ws: WebSocket): void {
    this.clients.delete(ws);
  }

  broadcast(message: ServerMessage): void {
    const data = JSON.stringify(message);
    for (const client of this.clients) {
      if (client.readyState === client.OPEN) {
        client.send(data);
      }
    }
  }

  get clientCount(): number {
    return this.clients.size;
  }
}
