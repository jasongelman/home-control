/**
 * LEAPClient — low-level LEAP protocol transport.
 *
 * LEAP (Lutron Extensible Application Protocol) sends newline-delimited JSON
 * over a plain TCP socket (port 8081) or TLS socket (port 8083).
 * Each outgoing message gets a unique ClientTag so responses can be
 * matched back to the originating request.
 */
import net from 'net';
import tls from 'tls';
import { EventEmitter } from 'events';

export interface LEAPMessage {
  CommuniqueType: string;
  Header: {
    ClientTag?: string;
    MessageBodyType?: string;
    StatusCode?: string;
    Url: string;
  };
  Body?: Record<string, unknown>;
}

interface Pending {
  resolve: (msg: LEAPMessage) => void;
  reject: (err: Error) => void;
  timer: NodeJS.Timeout;
}

export interface LEAPClientOptions {
  cert?: string;  // PEM client certificate (for mTLS)
  key?: string;   // PEM private key
  ca?: string;    // PEM CA cert to verify server (optional — defaults to skip verify)
}

export class LEAPClient extends EventEmitter {
  private socket: net.Socket | null = null;
  private buffer = '';
  private tagCounter = 0;
  private pending = new Map<string, Pending>();

  constructor(
    private readonly host: string,
    private readonly port: number,
    private readonly useTLS: boolean = false,
    private readonly tlsOptions: LEAPClientOptions = {},
  ) {
    super();
  }

  // ── Connection ────────────────────────────────────────────────────────────

  connect(): Promise<void> {
    return new Promise((resolve, reject) => {
      let settled = false;
      const settle = (err?: Error) => {
        if (settled) return;
        settled = true;
        err ? reject(err) : resolve();
      };

      if (this.useTLS) {
        this.socket = tls.connect({
          host: this.host,
          port: this.port,
          rejectUnauthorized: false, // Lutron uses self-signed server certs
          // Client certificate for mTLS (required by HomeWorks QS)
          ...(this.tlsOptions.cert && this.tlsOptions.key
            ? { cert: this.tlsOptions.cert, key: this.tlsOptions.key }
            : {}),
          ...(this.tlsOptions.ca ? { ca: this.tlsOptions.ca } : {}),
        });
        (this.socket as tls.TLSSocket).once('secureConnect', () => settle());
      } else {
        this.socket = net.createConnection({ host: this.host, port: this.port });
        this.socket.once('connect', () => settle());
      }

      this.socket.once('error', (err) => settle(err));
      this.socket.on('data', (chunk: Buffer) => this.onData(chunk));
      this.socket.on('close', () => {
        this.emit('disconnect');
        this.rejectAllPending(new Error('Connection closed'));
      });
      this.socket.on('error', (err: Error) => this.emit('error', err));
    });
  }

  disconnect(): void {
    this.rejectAllPending(new Error('Disconnected'));
    this.socket?.destroy();
    this.socket = null;
  }

  get isConnected(): boolean {
    return !!(this.socket && !this.socket.destroyed);
  }

  // ── Sending ───────────────────────────────────────────────────────────────

  /** Send a request and wait for the matching response (by ClientTag). */
  send(
    msg: Omit<LEAPMessage, 'Header'> & { Header: Omit<LEAPMessage['Header'], 'ClientTag'> },
    timeoutMs = 8000,
  ): Promise<LEAPMessage> {
    const tag = String(++this.tagCounter);
    const payload: LEAPMessage = { ...msg, Header: { ...msg.Header, ClientTag: tag } };

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(tag);
        reject(new Error(`LEAP timeout waiting for ${payload.Header.Url}`));
      }, timeoutMs);

      this.pending.set(tag, { resolve, reject, timer });
      this.write(payload);
    });
  }

  /** Fire-and-forget — no response expected. */
  sendUntagged(msg: LEAPMessage): void {
    this.write(msg);
  }

  // ── Receiving ─────────────────────────────────────────────────────────────

  private onData(chunk: Buffer): void {
    this.buffer += chunk.toString('utf8');
    const lines = this.buffer.split('\n');
    this.buffer = lines.pop() ?? ''; // keep incomplete tail

    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      try {
        this.dispatch(JSON.parse(trimmed) as LEAPMessage);
      } catch {
        // malformed — ignore
      }
    }
  }

  private dispatch(msg: LEAPMessage): void {
    const tag = msg.Header.ClientTag;
    const pending = tag ? this.pending.get(tag) : undefined;
    if (pending) {
      clearTimeout(pending.timer);
      this.pending.delete(tag!);
      pending.resolve(msg);
    } else {
      // Unsolicited (subscription updates, server-pushed events)
      this.emit('message', msg);
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  private write(msg: LEAPMessage): void {
    if (!this.socket || this.socket.destroyed) return;
    this.socket.write(JSON.stringify(msg) + '\r\n');
  }

  private rejectAllPending(err: Error): void {
    for (const { reject, timer } of this.pending.values()) {
      clearTimeout(timer);
      reject(err);
    }
    this.pending.clear();
  }
}
