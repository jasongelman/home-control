import { Box, Typography, Chip, Slider, Collapse, List, ListItem, ListItemText, CircularProgress } from '@mui/material';
import EvStationIcon from '@mui/icons-material/EvStation';
import BoltIcon from '@mui/icons-material/Bolt';
import PowerIcon from '@mui/icons-material/Power';
import ExpandMoreIcon from '@mui/icons-material/ExpandMore';
import ExpandLessIcon from '@mui/icons-material/ExpandLess';
import { useState, useEffect, useCallback } from 'react';
import { useLutron } from '../context/LutronContext.js';
import type { ChargePointCharger, ChargePointSession } from '../types/index.js';

const STATUS_LABELS: Record<string, string> = {
  idle:      'Idle',
  pluggedIn: 'Plugged In',
  charging:  'Charging',
  complete:  'Complete',
  error:     'Error',
  unknown:   'Unknown',
};

const STATUS_COLORS: Record<string, 'success' | 'warning' | 'error' | 'default' | 'info'> = {
  idle:      'default',
  pluggedIn: 'info',
  charging:  'success',
  complete:  'success',
  error:     'error',
  unknown:   'default',
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
  const color = STATUS_COLORS[charger.status] ?? 'default';

  return (
    <Box
      sx={{
        p: 2,
        borderRadius: 2,
        border: '1px solid',
        borderColor: isCharging ? 'success.main' : 'rgba(255,255,255,0.08)',
        bgcolor: isCharging ? 'rgba(76,175,80,0.08)' : 'rgba(255,255,255,0.03)',
      }}
    >
      {/* Header */}
      <Box sx={{ display: 'flex', alignItems: 'center', gap: 1.5, mb: 1.5 }}>
        {isCharging ? (
          <BoltIcon sx={{ fontSize: 18, color: 'success.main' }} />
        ) : charger.isPluggedIn ? (
          <PowerIcon sx={{ fontSize: 18, color: 'info.main' }} />
        ) : (
          <EvStationIcon sx={{ fontSize: 18, color: 'text.disabled' }} />
        )}
        <Typography variant="body2" fontWeight={600} sx={{ flex: 1 }}>
          {charger.nickname}
        </Typography>
        <Chip
          size="small"
          label={STATUS_LABELS[charger.status] ?? charger.status}
          color={color}
          variant="outlined"
          sx={{ fontWeight: 600, fontSize: 11 }}
        />
      </Box>

      {/* Live stats when charging or plugged in */}
      {(isCharging || charger.isPluggedIn) && (
        <Box sx={{ display: 'flex', gap: 2, mb: 1.5, flexWrap: 'wrap' }}>
          {charger.powerKw != null && charger.powerKw > 0 && (
            <Box>
              <Typography variant="caption" color="text.secondary" sx={{ fontSize: 10 }}>Power</Typography>
              <Typography variant="body2" fontWeight={700}>{charger.powerKw.toFixed(1)} kW</Typography>
            </Box>
          )}
          {charger.energyKwh != null && charger.energyKwh > 0 && (
            <Box>
              <Typography variant="caption" color="text.secondary" sx={{ fontSize: 10 }}>Session</Typography>
              <Typography variant="body2" fontWeight={700}>{charger.energyKwh.toFixed(1)} kWh</Typography>
            </Box>
          )}
        </Box>
      )}

      {/* Amperage control */}
      {charger.maxAmperage > 0 && (
        <Box sx={{ px: 0.5 }}>
          <Box sx={{ display: 'flex', justifyContent: 'space-between', mb: 0.5 }}>
            <Typography variant="caption" color="text.secondary" sx={{ fontSize: 10 }}>
              Amperage Limit
            </Typography>
            <Typography variant="caption" fontWeight={600} sx={{ fontSize: 11, fontVariantNumeric: 'tabular-nums' }}>
              {localAmps}A
            </Typography>
          </Box>
          <Slider
            value={localAmps}
            min={8}
            max={charger.maxAmperage}
            step={1}
            onChange={(_e, v) => setLocalAmps(v as number)}
            onChangeCommitted={(_e, v) => setChargerAmperage(charger.chargerId, v as number)}
            size="small"
            sx={{
              color: 'primary.main',
              '& .MuiSlider-thumb': { width: 14, height: 14 },
            }}
          />
        </Box>
      )}

      {/* Session history toggle */}
      <Box
        sx={{ display: 'flex', alignItems: 'center', gap: 0.5, cursor: 'pointer', userSelect: 'none', mt: 1 }}
        onClick={loadHistory}
      >
        <Typography variant="caption" color="text.secondary" sx={{ flex: 1, fontSize: 11 }}>
          Charging History
        </Typography>
        {historyOpen ? <ExpandLessIcon sx={{ fontSize: 14 }} /> : <ExpandMoreIcon sx={{ fontSize: 14 }} />}
      </Box>
      <Collapse in={historyOpen}>
        {loadingSessions ? (
          <Box sx={{ display: 'flex', justifyContent: 'center', py: 2 }}>
            <CircularProgress size={18} />
          </Box>
        ) : sessions.length === 0 ? (
          <Typography variant="caption" color="text.secondary" sx={{ display: 'block', py: 1 }}>
            No recent sessions
          </Typography>
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
    </Box>
  );
}

export function EVChargingSection() {
  const { chargers, chargePointConnected } = useLutron();

  if (!chargePointConnected || chargers.length === 0) return null;

  return (
    <>
      <Box sx={{ display: 'flex', alignItems: 'center', gap: 1, mt: 4, mb: 1.5 }}>
        <Typography variant="subtitle2" color="text.secondary">EV Charging</Typography>
        {!chargePointConnected && (
          <Chip label="offline" size="small" sx={{ height: 18, fontSize: 10, color: 'error.main', borderColor: 'error.main' }} variant="outlined" />
        )}
      </Box>
      <Box sx={{ display: 'flex', flexDirection: 'column', gap: 1.5 }}>
        {chargers.map((charger) => (
          <ChargerCard key={charger.chargerId} charger={charger} />
        ))}
      </Box>
    </>
  );
}
