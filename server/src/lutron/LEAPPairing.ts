/**
 * LEAPPairing — certificate pairing flow for HomeWorks QSX / Caseta LEAP.
 *
 * How it works (matching the pylutron-caseta protocol):
 *  1. Generate an RSA keypair + CSR (Certificate Signing Request).
 *  2. User presses the Access Button on the QSX processor (or the
 *     small button on a Caseta bridge). This opens a ~30 second window
 *     where the processor relaxes mTLS and accepts unauthenticated
 *     TLS connections on port 8083.
 *  3. Connect to port 8083 with TLS but WITHOUT a client certificate.
 *  4. Send a LEAP pairing request containing the CSR.
 *  5. The processor signs the CSR with its "Caseta Local Access Protocol
 *     Cert Authority" CA and returns a signed certificate.
 *  6. Persist the signed certificate + private key to disk.
 *
 * For HomeWorks QSX (HQP7-2): press the Access Button on the front panel.
 * For Caseta Smart Bridge: press the small black button on the back.
 */
import { execFile } from 'child_process';
import { promisify } from 'util';
import { mkdtempSync, readFileSync, rmSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';
import { EventEmitter } from 'events';
import tls from 'tls';
import { saveCert, ensureCertDir } from './LEAPCertManager.js';

const execFileAsync = promisify(execFile);

export interface PairingStatus {
  stage: 'generating' | 'connecting' | 'waiting' | 'signing' | 'done' | 'error';
  message: string;
  detail?: string;
}

export class LEAPPairing extends EventEmitter {
  private aborted = false;

  constructor(private readonly host: string) {
    super();
  }

  /** Abort an in-progress pairing attempt. */
  abort(): void {
    this.aborted = true;
  }

  /**
   * Run the full pairing flow.
   * Emits 'status' events with PairingStatus objects.
   * Resolves when pairing completes; rejects on unrecoverable error.
   */
  async pair(timeoutMs = 60_000): Promise<void> {
    ensureCertDir();

    // ── 1. Generate RSA key + CSR ────────────────────────────────────────
    this.status('generating', 'Generating keypair and certificate signing request…');
    const { keyPem, csrPem } = await generateKeyAndCSR();

    if (this.aborted) throw new Error('Pairing aborted');

    // ── 2. Retry TLS connection (no client cert) until pairing window opens ─
    this.status('waiting',
      'Press the Access Button on your HomeWorks QSX processor now.',
      'The button is on the front panel. Press once — the LED may blink. ' +
      'Retrying connection every 3 seconds…',
    );

    let socket: tls.TLSSocket | null = null;
    const deadline = Date.now() + timeoutMs;

    while (!this.aborted && Date.now() < deadline) {
      try {
        socket = await this.connectNoClientCert();
        console.log(`LEAP pairing: connected to ${this.host}:8083 (no client cert)`);
        break;
      } catch (err) {
        const msg = (err as Error).message;
        // "bad certificate" (alert 42) = pairing window not open yet
        if (!msg.includes('bad certificate') && !msg.includes('alert')) {
          console.log(`LEAP pairing: unexpected error: ${msg}`);
        }
        socket = null;
      }

      if (this.aborted) break;
      await sleep(3000);
      this.status('connecting',
        'Still waiting for pairing mode…',
        'Make sure you pressed the Access Button on the front of the processor.',
      );
    }

    if (!socket) {
      this.status('error',
        'Timed out waiting for pairing mode.',
        'Press the Access Button on the processor, then click Pair Now within 30 seconds.',
      );
      throw new Error('Could not connect to processor for pairing');
    }

    if (this.aborted) { socket.destroy(); throw new Error('Pairing aborted'); }

    // ── 3. Send LEAP pairing request with CSR ────────────────────────────
    this.status('connecting', 'Connected! Sending pairing request with CSR…');

    try {
      const response = await this.sendPairingRequest(socket, csrPem);
      socket.destroy();

      // ── 4. Extract signed cert from response ───────────────────────────
      this.status('signing', 'Processor accepted pairing. Saving certificate…');
      this.extractAndSaveCert(response, keyPem);
      this.status('done', 'Paired successfully! Certificate saved.');
    } catch (err) {
      socket.destroy();
      const msg = (err as Error).message;
      this.status('error',
        'Pairing request failed.',
        msg,
      );
      throw err;
    }
  }

  // ── Internal helpers ──────────────────────────────────────────────────

  /** Connect to port 8083 with TLS but NO client certificate. */
  private connectNoClientCert(): Promise<tls.TLSSocket> {
    return new Promise((resolve, reject) => {
      const socket = tls.connect({
        host: this.host,
        port: 8083,
        rejectUnauthorized: false, // Lutron uses self-signed server certs
        // Deliberately no cert/key — this only works during the pairing window
      });

      let settled = false;
      const settle = (err?: Error) => {
        if (settled) return;
        settled = true;
        err ? reject(err) : resolve(socket);
      };

      socket.once('secureConnect', () => settle());
      socket.once('error', (err) => settle(err));

      // Hard timeout — don't wait forever for a single attempt
      setTimeout(() => {
        if (!settled) {
          socket.destroy();
          settle(new Error('Connection timeout'));
        }
      }, 5000);
    });
  }

  /** Send the LEAP pairing request and read the JSON response. */
  private sendPairingRequest(
    socket: tls.TLSSocket,
    csrPem: string,
  ): Promise<Record<string, unknown>> {
    return new Promise((resolve, reject) => {
      const request = {
        CommuniqueType: 'CreateRequest',
        Header: { Url: '/pair' },
        Body: {
          PairingList: {
            Devices: [
              {
                DeviceName: 'LutronHome',
                DeviceUID: randomUID(),
                Role: 'Admin',
                CSR: csrPem,
              },
            ],
          },
        },
      };

      let buffer = '';

      socket.on('data', (chunk: Buffer) => {
        buffer += chunk.toString('utf8');
        const lines = buffer.split('\n');
        buffer = lines.pop() ?? '';

        for (const line of lines) {
          const trimmed = line.trim();
          if (!trimmed) continue;
          try {
            const msg = JSON.parse(trimmed);
            console.log('LEAP pairing response:', JSON.stringify(msg, null, 2));
            resolve(msg);
          } catch {
            // not valid JSON — ignore
          }
        }
      });

      socket.once('error', (err) => reject(err));
      socket.once('close', () => reject(new Error('Connection closed before pairing response')));

      // Send the pairing request
      const payload = JSON.stringify(request) + '\r\n';
      console.log('LEAP pairing: sending request to /pair');
      socket.write(payload);

      // Timeout for the pairing response
      setTimeout(() => reject(new Error('Timed out waiting for pairing response')), 30_000);
    });
  }

  /** Extract the signed certificate from the LEAP pairing response and save it. */
  private extractAndSaveCert(
    response: Record<string, unknown>,
    keyPem: string,
  ): void {
    const body = response.Body as Record<string, unknown> | undefined;
    if (!body) throw new Error('Pairing response has no body');

    // Try multiple response formats used by different Lutron processors
    let signedCert = '';
    let caCert = '';

    // Format 1: PairingList.Devices[0].Certificate (Caseta / QSX standard)
    const pairingList = body.PairingList as Record<string, unknown> | undefined;
    if (pairingList) {
      const devices = pairingList.Devices as Array<Record<string, unknown>> | undefined;
      if (devices && devices.length > 0) {
        signedCert = (devices[0].Certificate as string) ?? '';
        caCert = (devices[0].CACertificate as string) ?? '';
      }
    }

    // Format 2: Pairing.Certificate (older format)
    if (!signedCert) {
      const pairing = body.Pairing as Record<string, unknown> | undefined;
      if (pairing) {
        signedCert = (pairing.Certificate as string) ?? (pairing.ClientCertificate as string) ?? '';
        caCert = (pairing.CACertificate as string) ?? (pairing.CA as string) ?? '';
      }
    }

    // Format 3: direct body fields
    if (!signedCert) {
      signedCert = (body.Certificate as string) ?? '';
      caCert = (body.CA as string) ?? (body.CACertificate as string) ?? '';
    }

    if (!signedCert) {
      throw new Error(
        'Processor accepted pairing but did not return a signed certificate. ' +
        'Response body: ' + JSON.stringify(body),
      );
    }

    saveCert({ certPem: signedCert, keyPem, caCertPem: caCert || undefined });
    console.log('LEAP pairing: stored processor-signed certificate');
    if (caCert) {
      console.log('LEAP pairing: stored CA certificate');
    }
  }

  private status(
    stage: PairingStatus['stage'],
    message: string,
    detail?: string,
  ): void {
    this.emit('status', { stage, message, detail } satisfies PairingStatus);
  }
}

// ── Certificate generation ──────────────────────────────────────────────────

/** Generate an RSA private key and a CSR (Certificate Signing Request). */
async function generateKeyAndCSR(): Promise<{ keyPem: string; csrPem: string }> {
  const dir = mkdtempSync(join(tmpdir(), 'lutron-pair-'));
  const keyPath = join(dir, 'key.pem');
  const csrPath = join(dir, 'csr.pem');

  try {
    // Generate RSA key
    await execFileAsync('openssl', [
      'genrsa', '-out', keyPath, '2048',
    ]);

    // Generate CSR
    await execFileAsync('openssl', [
      'req', '-new',
      '-key', keyPath,
      '-out', csrPath,
      '-subj', '/CN=LutronHome',
    ]);

    const keyPem = readFileSync(keyPath, 'utf-8');
    const csrPem = readFileSync(csrPath, 'utf-8');
    return { keyPem, csrPem };
  } finally {
    try { rmSync(dir, { recursive: true }); } catch { /* cleanup best-effort */ }
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function randomUID(): string {
  return Array.from(
    { length: 16 },
    () => Math.floor(Math.random() * 256).toString(16).padStart(2, '0'),
  ).join('');
}
