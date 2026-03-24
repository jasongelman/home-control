/**
 * LEAPCertManager — handles client-certificate lifecycle for LEAP mTLS.
 *
 * HomeWorks QS requires a client certificate signed by a Lutron CA.
 * Certificates come from one of these sources:
 *
 *   1. Lutron Designer export  (ZIP → client.crt + client.key + ca.crt)
 *   2. Lutron Integrator Program portal
 *   3. Future: Caseta-style button-press pairing (if supported by HW QS)
 *
 * Certificates are stored in server/data/certs/ and referenced in config.json.
 */
import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import { createPrivateKey, createPublicKey, generateKeyPairSync } from 'crypto';

const __dirname = dirname(fileURLToPath(import.meta.url));
export const CERT_DIR = join(__dirname, '..', '..', 'data', 'certs');

export interface StoredCert {
  certPem: string;
  keyPem: string;
  caCertPem?: string;
}

// ── Disk helpers ──────────────────────────────────────────────────────────────

export function ensureCertDir(): void {
  if (!existsSync(CERT_DIR)) mkdirSync(CERT_DIR, { recursive: true });
}

export function hasCert(): boolean {
  return (
    existsSync(join(CERT_DIR, 'client.crt')) && existsSync(join(CERT_DIR, 'client.key'))
  );
}

export function loadCert(): StoredCert | null {
  try {
    const certPem = readFileSync(join(CERT_DIR, 'client.crt'), 'utf-8');
    const keyPem = readFileSync(join(CERT_DIR, 'client.key'), 'utf-8');
    const caPath = join(CERT_DIR, 'ca.crt');
    const caCertPem = existsSync(caPath) ? readFileSync(caPath, 'utf-8') : undefined;
    return { certPem, keyPem, caCertPem };
  } catch {
    return null;
  }
}

export function saveCert(cert: StoredCert): void {
  ensureCertDir();
  writeFileSync(join(CERT_DIR, 'client.crt'), cert.certPem, 'utf-8');
  writeFileSync(join(CERT_DIR, 'client.key'), cert.keyPem, 'utf-8');
  if (cert.caCertPem) {
    writeFileSync(join(CERT_DIR, 'ca.crt'), cert.caCertPem, 'utf-8');
  }
}

export function deleteCert(): void {
  for (const name of ['client.crt', 'client.key', 'ca.crt']) {
    const p = join(CERT_DIR, name);
    if (existsSync(p)) {
      import('fs').then(({ unlinkSync }) => unlinkSync(p)).catch(() => {});
    }
  }
}

// ── Validation ────────────────────────────────────────────────────────────────

export function validateCertPair(certPem: string, keyPem: string): void {
  // Verify the cert and key are syntactically valid PEM
  createPublicKey({ key: certPem, format: 'pem' });
  createPrivateKey({ key: keyPem, format: 'pem' });
  // (Cross-matching cert↔key would require third-party libs; skip for now)
}

// ── Self-signed cert generation (for pairing flow) ───────────────────────────

/**
 * Generate a temporary self-signed certificate to use during the Caseta-style
 * pairing handshake. The real certificate is obtained AFTER the processor
 * signs our public key during pairing.
 */
export function generateSelfSignedCert(): { certPem: string; keyPem: string } {
  // Node.js crypto doesn't have built-in X.509 generation.
  // We embed a minimal pre-generated self-signed cert for pairing use.
  // In production this would use the `forge` or `@peculiar/x509` package.
  //
  // For now, return a placeholder that signals "pairing cert needed".
  // The actual cert will be generated when forge/x509 is available.
  const { privateKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
  const keyPem = privateKey.export({ type: 'pkcs8', format: 'pem' }) as string;
  // Placeholder — the pairing route will handle actual cert generation
  return { certPem: '', keyPem };
}

// ── Certificate info parser ───────────────────────────────────────────────────

export interface CertInfo {
  subject: string;
  issuer: string;
  validFrom: string;
  validTo: string;
}

export function parseCertInfo(certPem: string): CertInfo | null {
  try {
    // Simple regex extraction from PEM — avoids needing openssl subprocess
    const lines = certPem.split('\n').filter((l) => l.trim());
    // Subject/issuer can be extracted from ASN.1 but that's complex.
    // For now just return a placeholder indicating it's a valid PEM.
    const hasHeader = lines.some((l) => l.includes('BEGIN CERTIFICATE'));
    const hasFooter = lines.some((l) => l.includes('END CERTIFICATE'));
    if (!hasHeader || !hasFooter) return null;
    return {
      subject: 'Lutron LEAP Client',
      issuer: 'Lutron Certificate Authority',
      validFrom: 'Unknown',
      validTo: 'Unknown',
    };
  } catch {
    return null;
  }
}
