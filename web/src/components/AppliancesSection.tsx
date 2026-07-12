import { Box, Typography, Chip, LinearProgress, Paper, Slider, Collapse, List, ListItem, ListItemText, CircularProgress, IconButton } from '@mui/material';
import RefreshIcon from '@mui/icons-material/Refresh';
import AddIcon from '@mui/icons-material/Add';
import RemoveIcon from '@mui/icons-material/Remove';
import LocalLaundryServiceIcon from '@mui/icons-material/LocalLaundryService';
import DryCleaningIcon from '@mui/icons-material/DryCleaning';
import AcUnitIcon from '@mui/icons-material/AcUnit';
import EvStationIcon from '@mui/icons-material/EvStation';
import BoltIcon from '@mui/icons-material/Bolt';
import PowerIcon from '@mui/icons-material/Power';
import ExpandMoreIcon from '@mui/icons-material/ExpandMore';
import ExpandLessIcon from '@mui/icons-material/ExpandLess';
import { useState, useEffect, useCallback } from 'react';
import { useLutron } from '../context/LutronContext.js';
import KitchenIcon from '@mui/icons-material/Kitchen';
import type { DishwasherStatus, LaundryAppliance, HeatPumpStatus, ChargePointCharger, ChargePointSession, SubZeroRefrigerator, WolfOven } from '../types/index.js';

// ── Helpers ──────────────────────────────────────────────────────────────────

function fmtMinutes(m: number | null): string {
  if (m === null) return '';
  if (m < 60) return `${m}m left`;
  return `${Math.floor(m / 60)}h ${m % 60}m left`;
}

function fmtSeconds(s: number | null): string {
  if (s === null) return '';
  const m = Math.round(s / 60);
  if (m < 60) return `${m}m left`;
  return `${Math.floor(m / 60)}h ${m % 60}m left`;
}

function stateColor(state: string): 'default' | 'success' | 'warning' | 'error' | 'info' {
  if (['running', 'run'].includes(state)) return 'success';
  if (['paused', 'pause', 'actionRequired'].includes(state)) return 'warning';
  if (['error'].includes(state)) return 'error';
  if (['complete', 'finished', 'delayedStart', 'delayed'].includes(state)) return 'info';
  return 'default';
}

function ApplianceCard({ children, connected }: { children: React.ReactNode; connected: boolean }) {
  return (
    <Paper
      sx={{
        p: 1.5,
        bgcolor: 'background.paper',
        border: '1px solid',
        borderColor: connected ? 'rgba(255,255,255,0.09)' : 'rgba(255,255,255,0.04)',
        borderRadius: 2,
        opacity: connected ? 1 : 0.6,
      }}
    >
      {children}
    </Paper>
  );
}

// ── Dishwasher card ───────────────────────────────────────────────────────────

function DishwasherCard({ dw }: { dw: DishwasherStatus }) {
  const isActive = ['run', 'delayedStart', 'pause', 'actionRequired'].includes(dw.operationState);

  return (
    <ApplianceCard connected={dw.connected}>
      <Box sx={{ display: 'flex', alignItems: 'center', gap: 1, mb: 0.75 }}>
        <Typography sx={{ fontSize: 18 }}>🍽️</Typography>
        <Box sx={{ flex: 1, minWidth: 0 }}>
          <Typography variant="body2" fontWeight={600} noWrap>{dw.applianceName}</Typography>
        </Box>
        <Chip
          label={dw.operationState}
          size="small"
          color={stateColor(dw.operationState)}
          sx={{ height: 20, fontSize: 10, fontWeight: 700 }}
        />
      </Box>

      {dw.activeProgram && (
        <Typography variant="caption" color="text.secondary" display="block" sx={{ mb: 0.5 }}>
          {dw.activeProgram}
        </Typography>
      )}

      {isActive && dw.progress !== null && (
        <Box sx={{ mt: 0.75 }}>
          <Box sx={{ display: 'flex', justifyContent: 'space-between', mb: 0.35 }}>
            <Typography variant="caption" color="text.disabled">{dw.progress}%</Typography>
            {dw.remainingTime !== null && (
              <Typography variant="caption" color="text.secondary">{fmtSeconds(dw.remainingTime)}</Typography>
            )}
          </Box>
          <LinearProgress
            variant="determinate"
            value={dw.progress}
            sx={{
              height: 3, borderRadius: 2,
              bgcolor: 'rgba(255,255,255,0.06)',
              '& .MuiLinearProgress-bar': { bgcolor: 'rgba(33,150,243,0.8)', borderRadius: 2 },
            }}
          />
        </Box>
      )}

      {dw.doorState !== 'unknown' && (
        <Box sx={{ display: 'flex', gap: 1, mt: 0.75 }}>
          <Chip
            label={`Door: ${dw.doorState}`}
            size="small"
            variant="outlined"
            sx={{ height: 18, fontSize: 10, borderColor: 'rgba(255,255,255,0.12)' }}
          />
        </Box>
      )}
    </ApplianceCard>
  );
}

// ── Laundry card ──────────────────────────────────────────────────────────────

function LaundryCard({ appliance }: { appliance: LaundryAppliance }) {
  const isWasher = appliance.applianceType === 'Washer';
  const isRunning = ['running', 'paused', 'delayed'].includes(appliance.machineState);

  return (
    <ApplianceCard connected={appliance.online}>
      <Box sx={{ display: 'flex', alignItems: 'center', gap: 1, mb: 0.75 }}>
        {isWasher
          ? <LocalLaundryServiceIcon sx={{ fontSize: 18, color: 'rgba(33,150,243,0.7)' }} />
          : <DryCleaningIcon sx={{ fontSize: 18, color: 'rgba(245,166,35,0.7)' }} />
        }
        <Box sx={{ flex: 1, minWidth: 0 }}>
          <Typography variant="body2" fontWeight={600} noWrap>{appliance.applianceName}</Typography>
        </Box>
        <Chip
          label={appliance.machineState}
          size="small"
          color={stateColor(appliance.machineState)}
          sx={{ height: 20, fontSize: 10, fontWeight: 700 }}
        />
      </Box>

      {appliance.cycleName && (
        <Typography variant="caption" color="text.secondary" display="block" sx={{ mb: 0.5 }}>
          {appliance.cycleName}
        </Typography>
      )}

      <Box sx={{ display: 'flex', flexWrap: 'wrap', gap: 0.5, mt: 0.5 }}>
        {isRunning && appliance.remainingMinutes !== null && (
          <Chip label={fmtMinutes(appliance.remainingMinutes)} size="small" sx={{ height: 18, fontSize: 10, bgcolor: 'rgba(255,255,255,0.06)' }} />
        )}
        {appliance.doorLocked && (
          <Chip label="🔒 Locked" size="small" sx={{ height: 18, fontSize: 10, bgcolor: 'rgba(255,255,255,0.06)' }} />
        )}
        {isWasher && appliance.washTemp && (
          <Chip label={`Temp: ${appliance.washTemp}`} size="small" sx={{ height: 18, fontSize: 10, bgcolor: 'rgba(255,255,255,0.06)' }} />
        )}
        {!isWasher && appliance.dryTemp && (
          <Chip label={`Heat: ${appliance.dryTemp}`} size="small" sx={{ height: 18, fontSize: 10, bgcolor: 'rgba(255,255,255,0.06)' }} />
        )}
      </Box>
    </ApplianceCard>
  );
}

// ── Heat pump card ────────────────────────────────────────────────────────────

function HeatPumpCard({ hp }: { hp: HeatPumpStatus }) {
  const modeColor: Record<string, string> = {
    heating: 'rgba(245,100,35,0.8)',
    cooling: 'rgba(33,150,243,0.8)',
    auto: 'rgba(150,100,255,0.8)',
    off: 'rgba(120,120,120,0.7)',
    unknown: 'rgba(120,120,120,0.5)',
  };

  return (
    <ApplianceCard connected={hp.connected}>
      <Box sx={{ display: 'flex', alignItems: 'center', gap: 1, mb: 0.75 }}>
        <AcUnitIcon sx={{ fontSize: 18, color: modeColor[hp.mode] }} />
        <Box sx={{ flex: 1, minWidth: 0 }}>
          <Typography variant="body2" fontWeight={600} noWrap>{hp.deviceName}</Typography>
        </Box>
        <Chip
          label={hp.mode}
          size="small"
          sx={{ height: 20, fontSize: 10, fontWeight: 700, bgcolor: `${modeColor[hp.mode]}25`, color: modeColor[hp.mode] }}
        />
      </Box>

      <Box sx={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 0.75 }}>
        {hp.outdoorTemp !== null && (
          <Box>
            <Typography variant="caption" color="text.disabled" display="block">Outdoor</Typography>
            <Typography variant="body2" fontWeight={600}>{hp.outdoorTemp}°F</Typography>
          </Box>
        )}
        {hp.setpointTemp !== null && (
          <Box>
            <Typography variant="caption" color="text.disabled" display="block">Setpoint</Typography>
            <Typography variant="body2" fontWeight={600}>{hp.setpointTemp}°F</Typography>
          </Box>
        )}
        {hp.supplyTemp !== null && (
          <Box>
            <Typography variant="caption" color="text.disabled" display="block">Supply</Typography>
            <Typography variant="body2" fontWeight={600}>{hp.supplyTemp}°F</Typography>
          </Box>
        )}
        {hp.compressorFreq !== null && (
          <Box>
            <Typography variant="caption" color="text.disabled" display="block">Compressor</Typography>
            <Typography variant="body2" fontWeight={600}>{hp.compressorFreq} Hz</Typography>
          </Box>
        )}
      </Box>
    </ApplianceCard>
  );
}

// ── Charger card ─────────────────────────────────────────────────────────────

const CHARGER_STATUS_LABELS: Record<string, string> = {
  idle: 'Idle', pluggedIn: 'Plugged In', charging: 'Charging',
  complete: 'Complete', error: 'Error', unknown: 'Unknown',
};

const CHARGER_STATUS_COLORS: Record<string, 'success' | 'warning' | 'error' | 'default' | 'info'> = {
  idle: 'default', pluggedIn: 'info', charging: 'success',
  complete: 'success', error: 'error', unknown: 'default',
};

function ChargerCard({ charger }: { charger: ChargePointCharger }) {
  const { setChargerAmperage } = useLutron();
  const [historyOpen, setHistoryOpen] = useState(false);
  const [sessions, setSessions] = useState<ChargePointSession[]>([]);
  const [loadingSessions, setLoadingSessions] = useState(false);
  const [localAmps, setLocalAmps] = useState(charger.amperage);

  useEffect(() => { setLocalAmps(charger.amperage); }, [charger.amperage]);

  const loadHistory = useCallback(() => {
    if (sessions.length > 0) { setHistoryOpen((o) => !o); return; }
    setLoadingSessions(true);
    setHistoryOpen(true);
    fetch(`/api/chargepoint/sessions/${charger.chargerId}`)
      .then((r) => r.ok ? r.json() as Promise<ChargePointSession[]> : Promise.resolve([]))
      .then(setSessions)
      .catch(() => {})
      .finally(() => setLoadingSessions(false));
  }, [charger.chargerId, sessions.length]);

  const isCharging = charger.status === 'charging';
  const color = CHARGER_STATUS_COLORS[charger.status] ?? 'default';

  return (
    <ApplianceCard connected>
      {/* Header */}
      <Box sx={{ display: 'flex', alignItems: 'center', gap: 1, mb: 0.75 }}>
        {isCharging ? (
          <BoltIcon sx={{ fontSize: 18, color: 'success.main' }} />
        ) : charger.isPluggedIn ? (
          <PowerIcon sx={{ fontSize: 18, color: 'info.main' }} />
        ) : (
          <EvStationIcon sx={{ fontSize: 18, color: 'text.disabled' }} />
        )}
        <Box sx={{ flex: 1, minWidth: 0 }}>
          <Typography variant="body2" fontWeight={600} noWrap>{charger.nickname}</Typography>
        </Box>
        <Chip
          size="small"
          label={CHARGER_STATUS_LABELS[charger.status] ?? charger.status}
          color={color}
          variant="outlined"
          sx={{ height: 20, fontSize: 10, fontWeight: 700 }}
        />
      </Box>

      {/* Live stats */}
      {(isCharging || charger.isPluggedIn) && (
        <Box sx={{ display: 'flex', gap: 2, mb: 0.75, flexWrap: 'wrap' }}>
          {charger.powerKw != null && charger.powerKw > 0 && (
            <Box>
              <Typography variant="caption" color="text.disabled" display="block" sx={{ fontSize: 10 }}>Power</Typography>
              <Typography variant="body2" fontWeight={700}>{charger.powerKw.toFixed(1)} kW</Typography>
            </Box>
          )}
          {charger.energyKwh != null && charger.energyKwh > 0 && (
            <Box>
              <Typography variant="caption" color="text.disabled" display="block" sx={{ fontSize: 10 }}>Session</Typography>
              <Typography variant="body2" fontWeight={700}>{charger.energyKwh.toFixed(1)} kWh</Typography>
            </Box>
          )}
        </Box>
      )}

      {/* Amperage control */}
      {charger.maxAmperage > 0 && (
        <Box sx={{ px: 0.5 }}>
          <Box sx={{ display: 'flex', justifyContent: 'space-between', mb: 0.5 }}>
            <Typography variant="caption" color="text.secondary" sx={{ fontSize: 10 }}>Amperage Limit</Typography>
            <Typography variant="caption" fontWeight={600} sx={{ fontSize: 11, fontVariantNumeric: 'tabular-nums' }}>{localAmps}A</Typography>
          </Box>
          <Slider
            value={localAmps}
            min={8}
            max={charger.maxAmperage}
            step={1}
            onChange={(_e, v) => setLocalAmps(v as number)}
            onChangeCommitted={(_e, v) => setChargerAmperage(charger.chargerId, v as number)}
            size="small"
            sx={{ color: 'primary.main', '& .MuiSlider-thumb': { width: 14, height: 14 } }}
          />
        </Box>
      )}

      {/* Session history toggle */}
      <Box
        sx={{ display: 'flex', alignItems: 'center', gap: 0.5, cursor: 'pointer', userSelect: 'none', mt: 1 }}
        onClick={loadHistory}
      >
        <Typography variant="caption" color="text.secondary" sx={{ flex: 1, fontSize: 11 }}>Charging History</Typography>
        {historyOpen ? <ExpandLessIcon sx={{ fontSize: 14 }} /> : <ExpandMoreIcon sx={{ fontSize: 14 }} />}
      </Box>
      <Collapse in={historyOpen}>
        {loadingSessions ? (
          <Box sx={{ display: 'flex', justifyContent: 'center', py: 2 }}><CircularProgress size={18} /></Box>
        ) : sessions.length === 0 ? (
          <Typography variant="caption" color="text.secondary" sx={{ display: 'block', py: 1 }}>No recent sessions</Typography>
        ) : (
          <List dense disablePadding sx={{ mt: 0.5 }}>
            {sessions.slice(0, 10).map((s) => (
              <ListItem key={s.sessionId} disablePadding sx={{ py: 0.25 }}>
                <ListItemText
                  primary={`${new Date(s.startTime).toLocaleDateString()} — ${s.energyKwh.toFixed(1)} kWh${s.cost != null ? ` / $${s.cost.toFixed(2)}` : ''}`}
                  primaryTypographyProps={{ variant: 'caption', color: 'text.secondary' }}
                  secondary={s.milesAdded != null ? `${s.milesAdded.toFixed(0)} miles added` : undefined}
                  secondaryTypographyProps={{ variant: 'caption', color: 'text.disabled', fontSize: 10 }}
                />
              </ListItem>
            ))}
          </List>
        )}
      </Collapse>
    </ApplianceCard>
  );
}

// ── Refrigerator card ────────────────────────────────────────────────────────
// READ-ONLY: Sub-Zero reports SETPOINTS only (fridgeTemp/freezerTemp are always
// null), so we render the setpoints. No controls — the command backend is unsolved.

const FRIDGE_MODE_LABELS: Record<string, string> = {
  normal: 'Normal', vacation: 'Vacation', sabbath: 'Sabbath', night: 'Night', unknown: 'Unknown',
};

function SetpointStepper({ label, setpoint, min, max, onChange }: {
  label: string; setpoint: number | null; min: number; max: number; onChange: (v: number) => void;
}) {
  const v = setpoint;
  return (
    <Box>
      <Typography variant="caption" color="text.disabled" display="block">{label}</Typography>
      <Box sx={{ display: 'flex', alignItems: 'center', gap: 0.25 }}>
        <IconButton size="small" disabled={v === null || v <= min} onClick={() => v !== null && onChange(v - 1)} sx={{ p: 0.25 }}>
          <RemoveIcon sx={{ fontSize: 14 }} />
        </IconButton>
        <Typography variant="body2" fontWeight={700} sx={{ minWidth: 34, textAlign: 'center' }}>
          {v !== null ? `${Math.round(v)}°` : '—'}
        </Typography>
        <IconButton size="small" disabled={v === null || v >= max} onClick={() => v !== null && onChange(v + 1)} sx={{ p: 0.25 }}>
          <AddIcon sx={{ fontSize: 14 }} />
        </IconButton>
      </Box>
    </Box>
  );
}

function FilterReadout({ label, pct }: { label: string; pct: number }) {
  return (
    <Box>
      <Typography variant="caption" color="text.disabled" display="block">{label}</Typography>
      <Typography variant="body2" fontWeight={700} color={pct < 20 ? 'warning.main' : 'text.primary'}>{Math.round(pct)}%</Typography>
    </Box>
  );
}

function RefrigeratorCard({ fridge }: { fridge: SubZeroRefrigerator }) {
  const { subZeroCommand } = useLutron();
  const id = fridge.applianceId;
  return (
    <ApplianceCard connected={fridge.online}>
      <Box sx={{ display: 'flex', alignItems: 'center', gap: 1, mb: 0.75 }}>
        <KitchenIcon sx={{ fontSize: 20, color: fridge.online ? 'info.main' : 'text.disabled' }} />
        <Box sx={{ flex: 1, minWidth: 0 }}>
          <Typography variant="body2" fontWeight={600} noWrap>{fridge.applianceName}</Typography>
          {fridge.model && (
            <Typography variant="caption" color="text.disabled" noWrap display="block">{fridge.model}</Typography>
          )}
        </Box>
        {fridge.mode !== 'normal' && fridge.mode !== 'unknown' && (
          <Chip label={FRIDGE_MODE_LABELS[fridge.mode] ?? fridge.mode} size="small" color="info" variant="outlined" sx={{ height: 20, fontSize: 10, fontWeight: 700 }} />
        )}
        <IconButton size="small" onClick={() => subZeroCommand(id, 'refresh', null)} title="Refresh now" sx={{ p: 0.25 }}>
          <RefreshIcon sx={{ fontSize: 16 }} />
        </IconButton>
      </Box>

      {/* Door-ajar indicators */}
      {(fridge.fridgeDoorOpen || fridge.freezerDoorOpen) && (
        <Box sx={{ display: 'flex', gap: 0.5, mb: 0.75, flexWrap: 'wrap' }}>
          {fridge.fridgeDoorOpen && (
            <Chip label="Fridge door open" size="small" color="warning" sx={{ height: 18, fontSize: 10, fontWeight: 700 }} />
          )}
          {fridge.freezerDoorOpen && (
            <Chip label="Freezer door open" size="small" color="warning" sx={{ height: 18, fontSize: 10, fontWeight: 700 }} />
          )}
        </Box>
      )}

      {/* Setpoints (tap ± to adjust) */}
      <Box sx={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 0.75 }}>
        <SetpointStepper label="Fridge" setpoint={fridge.fridgeSetpoint} min={34} max={45}
          onChange={(v) => subZeroCommand(id, 'setFridgeTemp', v)} />
        <SetpointStepper label="Freezer" setpoint={fridge.freezerSetpoint} min={-5} max={5}
          onChange={(v) => subZeroCommand(id, 'setFreezerTemp', v)} />
        {fridge.crisperSetpoint !== null && (
          <SetpointStepper label="Crisper" setpoint={fridge.crisperSetpoint} min={34} max={45}
            onChange={(v) => subZeroCommand(id, 'setCrisperTemp', v)} />
        )}
      </Box>

      {/* Filters */}
      {(fridge.waterFilterPct !== null || fridge.airPurificationPct !== null) && (
        <Box sx={{ display: 'flex', gap: 2, mt: 1, flexWrap: 'wrap' }}>
          {fridge.waterFilterPct !== null && <FilterReadout label="Water Filter" pct={fridge.waterFilterPct} />}
          {fridge.airPurificationPct !== null && <FilterReadout label="Air Filter" pct={fridge.airPurificationPct} />}
          {fridge.humidityControl !== null && (
            <Box>
              <Typography variant="caption" color="text.disabled" display="block">Humidity</Typography>
              <Typography variant="body2" fontWeight={700}>{fridge.humidityControl}</Typography>
            </Box>
          )}
        </Box>
      )}

      {/* Toggle chips (tap to change) */}
      <Box sx={{ display: 'flex', gap: 0.5, mt: 1, flexWrap: 'wrap' }}>
        <Chip
          label={fridge.iceMakerOn ? (fridge.maxIceOn ? 'Ice: Max' : 'Ice: On') : 'Ice: Off'}
          size="small"
          variant="outlined"
          onClick={() => subZeroCommand(id, 'setIceMaker', !fridge.iceMakerOn)}
          sx={{ height: 18, fontSize: 10, cursor: 'pointer', borderColor: fridge.iceMakerOn ? 'rgba(33,150,243,0.4)' : 'rgba(255,255,255,0.12)', color: fridge.iceMakerOn ? 'info.main' : 'text.secondary' }}
        />
        <Chip
          label="Night mode"
          size="small"
          variant="outlined"
          onClick={() => subZeroCommand(id, 'setNightMode', !fridge.nightMode)}
          sx={{ height: 18, fontSize: 10, cursor: 'pointer', borderColor: fridge.nightMode ? 'rgba(150,100,255,0.4)' : 'rgba(255,255,255,0.12)', color: fridge.nightMode ? 'rgba(150,100,255,0.9)' : 'text.secondary' }}
        />
        <Chip
          label="Light"
          size="small"
          variant="outlined"
          onClick={() => subZeroCommand(id, 'toggleLight', !fridge.lightOn)}
          sx={{ height: 18, fontSize: 10, cursor: 'pointer', borderColor: fridge.lightOn ? 'rgba(245,166,35,0.4)' : 'rgba(255,255,255,0.12)', color: fridge.lightOn ? 'primary.main' : 'text.secondary' }}
        />
      </Box>
    </ApplianceCard>
  );
}

// ── Wolf Oven card ──────────────────────────────────────────────────────────
// READ-ONLY: displays live oven state. No start/preheat/timer controls — the
// command backend is a separate unsolved problem.

// timerRemaining is in SECONDS; format as a kitchen-timer m:ss (e.g. 3:05).
function fmtOvenTimer(seconds: number | null): string {
  if (seconds === null || seconds <= 0) return '';
  const m = Math.floor(seconds / 60);
  const s = seconds % 60;
  return `${m}:${String(s).padStart(2, '0')}`;
}

function OvenStatRow({ label, value }: { label: string; value: string | null }) {
  return (
    <Box sx={{ display: 'flex', justifyContent: 'space-between', py: 0.25 }}>
      <Typography variant="caption" color="text.secondary">{label}</Typography>
      <Typography variant="caption" fontWeight={value ? 700 : 400} color={value ? 'text.primary' : 'text.disabled'}>{value ?? '—'}</Typography>
    </Box>
  );
}

function WolfOvenCard({ oven }: { oven: WolfOven }) {
  const isProbing = oven.probeTemp !== null;
  const cookMode = oven.unitOn && oven.cookMode !== 'off' && oven.cookMode !== 'unknown'
    ? oven.cookMode.replace(/_/g, ' ')
    : null;

  return (
    <ApplianceCard connected={oven.online}>
      <Box sx={{ display: 'flex', alignItems: 'center', gap: 1, mb: 0.75 }}>
        <Typography sx={{ fontSize: 18 }}>🔥</Typography>
        <Box sx={{ flex: 1, minWidth: 0 }}>
          <Typography variant="body2" fontWeight={600} noWrap>{oven.applianceName}</Typography>
          {oven.model && (
            <Typography variant="caption" color="text.disabled" noWrap display="block">{oven.model}</Typography>
          )}
        </Box>
        <Chip
          label={oven.unitOn ? 'cooking' : oven.remoteReady ? 'remote ready' : 'off'}
          size="small"
          color={oven.unitOn ? 'warning' : oven.remoteReady ? 'success' : 'default'}
          sx={{ height: 20, fontSize: 10, fontWeight: 700 }}
        />
      </Box>

      {/* Current → target while cooking */}
      {oven.unitOn && oven.currentTemp !== null && (
        <Box sx={{ display: 'flex', alignItems: 'baseline', gap: 0.5, mt: 0.5, mb: 0.5 }}>
          <Typography variant="h6" fontWeight={700} sx={{ fontVariantNumeric: 'tabular-nums' }}>
            {Math.round(oven.currentTemp)}°F
          </Typography>
          {oven.targetTemp != null && oven.targetTemp > 0 && (
            <Typography variant="body2" color="text.secondary">→ {Math.round(oven.targetTemp)}°F</Typography>
          )}
        </Box>
      )}

      {/* Detail rows */}
      <Box sx={{ mt: 0.5 }}>
        {cookMode && <OvenStatRow label="Mode" value={cookMode} />}
        {isProbing && (
          <OvenStatRow
            label="Probe"
            value={oven.probeTargetTemp != null && oven.probeTargetTemp > 0
              ? `${Math.round(oven.probeTemp as number)}°F → ${Math.round(oven.probeTargetTemp)}°F`
              : `${Math.round(oven.probeTemp as number)}°F`}
          />
        )}
        {oven.timerRemaining != null && oven.timerRemaining > 0 && (
          <Box sx={{ display: 'flex', justifyContent: 'space-between', py: 0.25 }}>
            <Typography variant="caption" color="text.secondary">Timer</Typography>
            <Typography variant="caption" fontWeight={700} color="warning.main" sx={{ fontVariantNumeric: 'tabular-nums' }}>
              {fmtOvenTimer(oven.timerRemaining)}
            </Typography>
          </Box>
        )}
        <OvenStatRow label="Light" value={oven.lightOn ? 'On' : null} />
      </Box>
    </ApplianceCard>
  );
}

// ── Section ───────────────────────────────────────────────────────────────────

export function AppliancesSection({
  dishwashers,
  laundry,
  heatPumps,
  chargers = [],
  chargePointConnected = false,
  refrigerators = [],
  ovens = [],
  subZeroLinked = false,
}: {
  dishwashers: DishwasherStatus[];
  laundry: LaundryAppliance[];
  heatPumps: HeatPumpStatus[];
  chargers?: ChargePointCharger[];
  chargePointConnected?: boolean;
  refrigerators?: SubZeroRefrigerator[];
  ovens?: WolfOven[];
  subZeroLinked?: boolean;
}) {
  const all = dishwashers.length + laundry.length + heatPumps.length + chargers.length + refrigerators.length + ovens.length;
  if (all === 0) return null;

  const activeCount = [
    ...dishwashers.filter((d) => ['run', 'delayedStart', 'pause', 'actionRequired'].includes(d.operationState)),
    ...laundry.filter((a) => ['running', 'paused', 'delayed'].includes(a.machineState)),
    ...heatPumps.filter((h) => h.mode !== 'off' && h.mode !== 'unknown'),
    ...chargers.filter((c) => c.status === 'charging'),
    ...ovens.filter((o) => o.unitOn),
  ].length;

  return (
    <>
      <Box sx={{ display: 'flex', alignItems: 'center', gap: 1, mt: 4, mb: 1.5 }}>
        <Typography variant="subtitle2" color="text.secondary">Appliances</Typography>
        {activeCount > 0 && (
          <Chip
            label={`${activeCount} active`}
            size="small"
            sx={{ height: 20, fontSize: 11, fontWeight: 700, bgcolor: 'rgba(33,150,243,0.15)', color: 'rgba(33,150,243,0.9)' }}
          />
        )}
      </Box>

      <Box sx={{ display: 'grid', gridTemplateColumns: { xs: '1fr', sm: 'repeat(2, 1fr)', md: 'repeat(3, 1fr)' }, gap: 1.25 }}>
        {dishwashers.map((dw) => <DishwasherCard key={dw.applianceId} dw={dw} />)}
        {laundry.map((a) => <LaundryCard key={a.applianceId} appliance={a} />)}
        {heatPumps.map((hp) => <HeatPumpCard key={hp.deviceId} hp={hp} />)}
        {chargePointConnected && chargers.map((c) => <ChargerCard key={c.chargerId} charger={c} />)}
        {subZeroLinked && refrigerators.map((f) => <RefrigeratorCard key={f.applianceId} fridge={f} />)}
        {subZeroLinked && ovens.map((o) => <WolfOvenCard key={o.applianceId} oven={o} />)}
      </Box>
    </>
  );
}
