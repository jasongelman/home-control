import { useState, useRef } from 'react';

interface SetupWizardProps {
  onComplete: () => void;
}

interface DiscoveryResult {
  areas: number;
  zones: number;
  virtualButtons: number;
  devices: number;
  topology: {
    areas: Array<{ id: number; name: string }>;
    zones: Array<{ id: number; name: string; areaName: string; controlType: string }>;
    virtualButtons: Array<{ id: number; name: string; areaName: string }>;
  };
}

interface PairingStatus {
  stage: 'generating' | 'connecting' | 'waiting' | 'signing' | 'done' | 'error';
  message: string;
  detail?: string;
}

const DETECTED_IPS = ['192.168.1.191', '192.168.1.196'];

export function SetupWizard({ onComplete }: SetupWizardProps) {
  const [step, setStep] = useState(1);

  // Step 1
  const [ip, setIp] = useState(DETECTED_IPS[0]);
  const [username, setUsername] = useState('lutron');
  const [password, setPassword] = useState('integration');
  const [step1Status, setStep1Status] = useState('');
  const [step1Ok, setStep1Ok] = useState(false);

  // Step 2 — cert mode toggle
  const [certMode, setCertMode] = useState<'pairing' | 'manual'>('pairing');

  // Step 2a — pairing
  const [pairingStatuses, setPairingStatuses] = useState<PairingStatus[]>([]);
  const [pairing, setPairing] = useState(false);
  const [pairingDone, setPairingDone] = useState(false);
  const pairingAbortRef = useRef<(() => void) | null>(null);

  // Step 2b — manual import
  const [certPem, setCertPem] = useState('');
  const [keyPem, setKeyPem] = useState('');
  const [caCertPem, setCaCertPem] = useState('');
  const [certStatus, setCertStatus] = useState('');
  const [certOk, setCertOk] = useState(false);

  // Step 3
  const [discovering, setDiscovering] = useState(false);
  const [result, setResult] = useState<DiscoveryResult | null>(null);
  const [discoverStatus, setDiscoverStatus] = useState('');
  const [discoverOk, setDiscoverOk] = useState(false);

  // ── Step 1 ─────────────────────────────────────────────────────────────────

  const saveConfig = async () => {
    setStep1Status('Saving…');
    setStep1Ok(false);
    try {
      const res = await fetch('/api/config', {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ processor: { ip, port: 0, username, password } }),
      });
      const data = await res.json() as { connected: boolean; error?: string };
      if (data.connected) {
        setStep1Status('Connected directly (no certificate needed)!');
        setStep1Ok(true);
        setTimeout(() => setStep(3), 600);
      } else {
        setStep1Status('Config saved. A client certificate is required for this processor.');
        setStep1Ok(true);
        setTimeout(() => setStep(2), 900);
      }
    } catch (err) {
      setStep1Status(`Error: ${String(err)}`);
    }
  };

  // ── Step 2a: Pairing ────────────────────────────────────────────────────────

  const startPairing = async () => {
    setPairing(true);
    setPairingDone(false);
    setPairingStatuses([]);

    const controller = new AbortController();
    pairingAbortRef.current = () => {
      controller.abort();
      fetch('/api/pair', { method: 'DELETE' }).catch(() => {});
    };

    try {
      const res = await fetch('/api/pair', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({}),
        signal: controller.signal,
      });

      const reader = res.body!.getReader();
      const decoder = new TextDecoder();
      let buf = '';

      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        buf += decoder.decode(value, { stream: true });
        const lines = buf.split('\n');
        buf = lines.pop() ?? '';
        for (const line of lines) {
          if (line.startsWith('data: ')) {
            try {
              const status = JSON.parse(line.slice(6)) as PairingStatus;
              setPairingStatuses(prev => [...prev, status]);
              if (status.stage === 'done') setPairingDone(true);
            } catch { /* skip */ }
          }
        }
      }
    } catch (err) {
      if (!(err instanceof Error && err.name === 'AbortError')) {
        setPairingStatuses(prev => [...prev, {
          stage: 'error', message: `Connection error: ${String(err)}`
        }]);
      }
    } finally {
      setPairing(false);
      pairingAbortRef.current = null;
    }
  };

  const cancelPairing = () => {
    pairingAbortRef.current?.();
    setPairing(false);
  };

  // ── Step 2b: Manual import ─────────────────────────────────────────────────

  const importCert = async () => {
    if (!certPem.trim() || !keyPem.trim()) {
      setCertStatus('Both Certificate and Private Key are required.');
      return;
    }
    setCertStatus('Importing and reconnecting…');
    setCertOk(false);
    try {
      const res = await fetch('/api/cert', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          certPem: certPem.trim(),
          keyPem: keyPem.trim(),
          caCertPem: caCertPem.trim() || undefined,
        }),
      });
      const data = await res.json() as { ok: boolean; connected: boolean; error?: string };
      if (data.connected) {
        setCertStatus('Certificate accepted — connected!');
        setCertOk(true);
        setTimeout(() => setStep(3), 600);
      } else if (data.ok) {
        setCertStatus(`Certificate saved. Connection error: ${data.error ?? 'unknown'}`);
      } else {
        setCertStatus(data.error ?? 'Import failed');
      }
    } catch (err) {
      setCertStatus(`Error: ${String(err)}`);
    }
  };

  // ── Step 3: Discover ────────────────────────────────────────────────────────

  const discoverDevices = async () => {
    setDiscovering(true);
    setDiscoverStatus('Reading zones and areas from processor…');
    setResult(null);
    setDiscoverOk(false);
    try {
      const res = await fetch('/api/discover', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({}),
      });
      const data = await res.json() as DiscoveryResult & { error?: string };
      if ('error' in data) {
        setDiscoverStatus(`Discovery failed: ${data.error}`);
      } else {
        setResult(data);
        setDiscoverStatus(`Found ${data.zones} zones across ${data.areas} areas`);
        setDiscoverOk(true);
      }
    } catch (err) {
      setDiscoverStatus(`Error: ${String(err)}`);
    }
    setDiscovering(false);
  };

  // ── Render ─────────────────────────────────────────────────────────────────

  const steps = ['Processor', 'Certificate', 'Devices'];
  const lastPairing = pairingStatuses[pairingStatuses.length - 1];

  return (
    <div className="setup-wizard">
      <h1>Lutron Home Setup</h1>

      <div className="step-indicator">
        {steps.map((label, i) => (
          <div key={label} className={`step-dot ${i + 1 === step ? 'active' : i + 1 < step ? 'done' : ''}`}>
            <span className="step-num">{i + 1 < step ? '✓' : i + 1}</span>
            <span className="step-label">{label}</span>
          </div>
        ))}
      </div>

      {/* ── Step 1 ── */}
      {step === 1 && (
        <div className="setup-step">
          <h2>Processor Connection</h2>
          <p>Two Lutron processors were detected on your network.</p>

          <div className="form-group">
            <label>Detected Processors</label>
            <div className="ip-picker">
              {DETECTED_IPS.map(detected => (
                <button key={detected} className={`ip-chip ${ip === detected ? 'active' : 'secondary'}`} onClick={() => setIp(detected)}>
                  {detected}
                </button>
              ))}
            </div>
          </div>
          <div className="form-group">
            <label>IP Address</label>
            <input type="text" value={ip} onChange={e => setIp(e.target.value)} placeholder="192.168.1.x" />
          </div>
          <div className="form-group">
            <label>Username</label>
            <input type="text" value={username} onChange={e => setUsername(e.target.value)} />
          </div>
          <div className="form-group">
            <label>Password</label>
            <input type="password" value={password} onChange={e => setPassword(e.target.value)} />
          </div>

          {step1Status && <p className={`status ${step1Ok ? 'status-ok' : ''}`}>{step1Status}</p>}
          <button onClick={saveConfig} disabled={!ip}>Next</button>
        </div>
      )}

      {/* ── Step 2 ── */}
      {step === 2 && (
        <div className="setup-step">
          <h2>Client Certificate</h2>
          <p>HomeWorks QSX requires a client certificate for LEAP access. Choose how to get one:</p>

          <div className="cert-mode-tabs">
            <button className={`tab-btn ${certMode === 'pairing' ? 'active' : ''}`} onClick={() => setCertMode('pairing')}>
              Button-Press Pairing
            </button>
            <button className={`tab-btn ${certMode === 'manual' ? 'active' : ''}`} onClick={() => setCertMode('manual')}>
              Import from Designer
            </button>
          </div>

          {/* ── Pairing mode ── */}
          {certMode === 'pairing' && (
            <div className="pairing-panel">
              <div className="cert-explainer">
                <p><strong>Click Pair Now first</strong>, then press the Access Button on your HomeWorks QSX processor.</p>
                <ol>
                  <li>Click <strong>Pair Now</strong> below — it will start polling for the pairing window</li>
                  <li>Go to your QSX processor (HQP7-2 — usually in a utility closet or panel)</li>
                  <li>Press the <strong>Access Button</strong> on the front panel once</li>
                  <li>The system will automatically detect the pairing window and complete setup</li>
                </ol>
              </div>

              {pairingStatuses.length > 0 && (
                <div className="pairing-log">
                  {pairingStatuses.map((s, i) => (
                    <div key={i} className={`pairing-entry ${s.stage}`}>
                      <span className="pairing-icon">
                        {s.stage === 'done' ? '✓' : s.stage === 'error' ? '✗' : s.stage === 'waiting' ? '⏳' : '…'}
                      </span>
                      <span>
                        {s.message}
                        {s.detail && <span className="pairing-detail"> — {s.detail}</span>}
                      </span>
                    </div>
                  ))}
                </div>
              )}

              <div className="button-row">
                <button className="secondary" onClick={() => setStep(1)}>Back</button>
                {pairing ? (
                  <button className="danger" onClick={cancelPairing}>Cancel</button>
                ) : (
                  <button onClick={startPairing}>
                    {pairingStatuses.length > 0 ? 'Try Again' : 'Pair Now'}
                  </button>
                )}
                {pairingDone && (
                  <button onClick={() => setStep(3)}>Continue</button>
                )}
              </div>
            </div>
          )}

          {/* ── Manual import mode ── */}
          {certMode === 'manual' && (
            <div>
              <div className="cert-explainer">
                <p>Export a LEAP certificate package from <em>Lutron Designer</em>:</p>
                <ol>
                  <li>Tools → Integration → Enable LEAP API</li>
                  <li>Generate a new LEAP integration account</li>
                  <li>Export the certificate package (ZIP)</li>
                  <li>Paste <code>client.crt</code> and <code>client.key</code> below</li>
                </ol>
              </div>

              <div className="form-group">
                <label>Client Certificate <code className="file-hint">(client.crt)</code></label>
                <textarea rows={5} value={certPem} onChange={e => setCertPem(e.target.value)}
                  placeholder="-----BEGIN CERTIFICATE-----&#10;...&#10;-----END CERTIFICATE-----" spellCheck={false} />
              </div>
              <div className="form-group">
                <label>Private Key <code className="file-hint">(client.key)</code></label>
                <textarea rows={5} value={keyPem} onChange={e => setKeyPem(e.target.value)}
                  placeholder="-----BEGIN PRIVATE KEY-----&#10;...&#10;-----END PRIVATE KEY-----" spellCheck={false} />
              </div>
              <div className="form-group">
                <label>CA Certificate <span className="optional">(optional — ca.crt)</span></label>
                <textarea rows={4} value={caCertPem} onChange={e => setCaCertPem(e.target.value)}
                  placeholder="-----BEGIN CERTIFICATE-----&#10;...&#10;-----END CERTIFICATE-----" spellCheck={false} />
              </div>

              {certStatus && <p className={`status ${certOk ? 'status-ok' : ''}`}>{certStatus}</p>}

              <div className="button-row">
                <button className="secondary" onClick={() => setStep(1)}>Back</button>
                <button onClick={importCert} disabled={!certPem.trim() || !keyPem.trim()}>
                  Import &amp; Connect
                </button>
              </div>
            </div>
          )}
        </div>
      )}

      {/* ── Step 3 ── */}
      {step === 3 && (
        <div className="setup-step">
          <h2>Discover Devices</h2>
          <p>Read all rooms, zones, and scenes directly from the processor.</p>

          {discoverStatus && <p className={`status ${discoverOk ? 'status-ok' : ''}`}>{discoverStatus}</p>}

          {result && (
            <div className="discovery-result">
              <div className="discovery-stats">
                <div className="stat"><span className="stat-num">{result.areas}</span><span className="stat-label">Areas</span></div>
                <div className="stat"><span className="stat-num">{result.zones}</span><span className="stat-label">Zones</span></div>
                <div className="stat"><span className="stat-num">{result.virtualButtons}</span><span className="stat-label">Scenes</span></div>
              </div>

              <div className="area-list">
                {result.topology.areas.map(a => {
                  const areaZones = result.topology.zones.filter(z => z.areaName === a.name);
                  const areaScenes = result.topology.virtualButtons.filter(b => b.areaName === a.name);
                  if (!areaZones.length && !areaScenes.length) return null;
                  return (
                    <div key={a.id} className="area-card">
                      <div className="area-name">{a.name}</div>
                      <div className="area-zones">
                        {areaZones.map(z => <span key={z.id} className={`zone-chip ${z.controlType.toLowerCase()}`}>{z.name}</span>)}
                        {areaScenes.map(b => <span key={b.id} className="zone-chip scene">▶ {b.name}</span>)}
                      </div>
                    </div>
                  );
                })}
              </div>
            </div>
          )}

          <div className="button-row">
            <button className="secondary" onClick={() => setStep(2)}>Back</button>
            <button onClick={discoverDevices} disabled={discovering}>
              {discovering ? 'Reading…' : result ? 'Re-scan' : 'Read Devices'}
            </button>
            <button onClick={onComplete} disabled={!result}>Done</button>
          </div>
        </div>
      )}
    </div>
  );
}
