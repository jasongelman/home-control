import { Box, Typography, Chip, LinearProgress, Paper } from '@mui/material';
import LocalLaundryServiceIcon from '@mui/icons-material/LocalLaundryService';
import DryCleaningIcon from '@mui/icons-material/DryCleaning';
import AcUnitIcon from '@mui/icons-material/AcUnit';
import type { DishwasherStatus, LaundryAppliance, HeatPumpStatus } from '../types/index.js';

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

// ── Section ───────────────────────────────────────────────────────────────────

export function AppliancesSection({
  dishwashers,
  laundry,
  heatPumps,
}: {
  dishwashers: DishwasherStatus[];
  laundry: LaundryAppliance[];
  heatPumps: HeatPumpStatus[];
}) {
  const all = dishwashers.length + laundry.length + heatPumps.length;
  if (all === 0) return null;

  const activeCount = [
    ...dishwashers.filter((d) => ['run', 'delayedStart', 'pause', 'actionRequired'].includes(d.operationState)),
    ...laundry.filter((a) => ['running', 'paused', 'delayed'].includes(a.machineState)),
    ...heatPumps.filter((h) => h.mode !== 'off' && h.mode !== 'unknown'),
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
      </Box>
    </>
  );
}
