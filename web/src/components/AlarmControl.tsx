import { Box, Chip, Typography, Button, Divider, Collapse, List, ListItem, ListItemText } from '@mui/material';
import SecurityIcon from '@mui/icons-material/Security';
import WarningAmberIcon from '@mui/icons-material/WarningAmber';
import ExpandMoreIcon from '@mui/icons-material/ExpandMore';
import ExpandLessIcon from '@mui/icons-material/ExpandLess';
import { useState, useEffect } from 'react';
import { useLutron } from '../context/LutronContext.js';
import type { AlarmPanel, AlarmZone } from '../types/index.js';

// ── Status display helpers ────────────────────────────────────────────────────

const STATE_LABELS: Record<string, string> = {
  disarmed:   'Disarmed',
  armedAway:  'Armed Away',
  armedHome:  'Armed Home',
  armedNight: 'Armed Night',
  alarming:   'ALARMING',
  arming:     'Arming…',
  disarming:  'Disarming…',
  unknown:    'Unknown',
};

const STATE_COLORS: Record<string, 'success' | 'warning' | 'error' | 'default'> = {
  disarmed:   'success',
  armedAway:  'warning',
  armedHome:  'warning',
  armedNight: 'warning',
  alarming:   'error',
  arming:     'default',
  disarming:  'default',
  unknown:    'default',
};

// ── Single panel card ─────────────────────────────────────────────────────────

function AlarmPanelCard({ panel }: { panel: AlarmPanel }) {
  const { triggerAlarm } = useLutron();
  const [zones, setZones] = useState<AlarmZone[]>([]);
  const [zonesOpen, setZonesOpen] = useState(false);

  useEffect(() => {
    fetch(`/api/alarm/zones/${panel.locationId}`)
      .then((r) => r.ok ? r.json() as Promise<AlarmZone[]> : Promise.resolve([]))
      .then(setZones)
      .catch(() => {});
  }, [panel.locationId, panel.state]);

  const isTransitioning = panel.state === 'arming' || panel.state === 'disarming';
  const isAlarming      = panel.state === 'alarming';
  const faultedZones    = zones.filter((z) => z.faulted && !z.bypassed);
  const color = STATE_COLORS[panel.state] ?? 'default';

  return (
    <Box
      sx={{
        p: 2,
        borderRadius: 2,
        border: '1px solid',
        borderColor: isAlarming ? 'error.main' : 'rgba(255,255,255,0.08)',
        bgcolor: isAlarming ? 'rgba(211,47,47,0.12)' : 'rgba(255,255,255,0.03)',
        animation: isAlarming ? 'alarmPulse 1s ease-in-out infinite alternate' : 'none',
        '@keyframes alarmPulse': {
          from: { borderColor: 'error.main', bgcolor: 'rgba(211,47,47,0.08)' },
          to:   { borderColor: 'error.light', bgcolor: 'rgba(211,47,47,0.22)' },
        },
      }}
    >
      {/* Header */}
      <Box sx={{ display: 'flex', alignItems: 'center', gap: 1.5, mb: 2 }}>
        <SecurityIcon sx={{ fontSize: 18, color: color === 'error' ? 'error.main' : color === 'success' ? 'success.main' : color === 'warning' ? 'warning.main' : 'text.disabled' }} />
        <Typography variant="body2" fontWeight={600} sx={{ flex: 1 }}>
          {panel.name}
        </Typography>
        <Chip
          size="small"
          label={STATE_LABELS[panel.state] ?? panel.state}
          color={color}
          variant="outlined"
          sx={{ fontWeight: 600, fontSize: 11 }}
        />
      </Box>

      {/* Control buttons */}
      <Box sx={{ display: 'flex', gap: 1, flexWrap: 'wrap' }}>
        <Button
          size="small"
          variant={panel.state === 'armedAway' ? 'contained' : 'outlined'}
          color="warning"
          disabled={isTransitioning || panel.state === 'armedAway'}
          onClick={() => triggerAlarm(panel.locationId, 'armAway')}
          sx={{ fontSize: 12, flex: 1, minWidth: 80 }}
        >
          Away
        </Button>
        <Button
          size="small"
          variant={panel.state === 'armedHome' ? 'contained' : 'outlined'}
          color="warning"
          disabled={isTransitioning || panel.state === 'armedHome'}
          onClick={() => triggerAlarm(panel.locationId, 'armHome')}
          sx={{ fontSize: 12, flex: 1, minWidth: 80 }}
        >
          Home
        </Button>
        <Button
          size="small"
          variant={panel.state === 'armedNight' ? 'contained' : 'outlined'}
          color="warning"
          disabled={isTransitioning || panel.state === 'armedNight'}
          onClick={() => triggerAlarm(panel.locationId, 'armNight')}
          sx={{ fontSize: 12, flex: 1, minWidth: 80 }}
        >
          Night
        </Button>
        <Button
          size="small"
          variant={panel.state === 'disarmed' ? 'contained' : 'outlined'}
          color="success"
          disabled={isTransitioning || panel.state === 'disarmed'}
          onClick={() => triggerAlarm(panel.locationId, 'disarm')}
          sx={{ fontSize: 12, flex: 1, minWidth: 80 }}
        >
          Disarm
        </Button>
      </Box>

      {/* Faulted zones */}
      {faultedZones.length > 0 && (
        <>
          <Divider sx={{ my: 1.5, borderColor: 'rgba(255,255,255,0.08)' }} />
          <Box
            sx={{ display: 'flex', alignItems: 'center', gap: 0.5, cursor: 'pointer', userSelect: 'none' }}
            onClick={() => setZonesOpen((o) => !o)}
          >
            <WarningAmberIcon sx={{ fontSize: 14, color: 'warning.main' }} />
            <Typography variant="caption" color="warning.main" sx={{ flex: 1 }}>
              {faultedZones.length} open zone{faultedZones.length !== 1 ? 's' : ''}
            </Typography>
            {zonesOpen ? <ExpandLessIcon sx={{ fontSize: 14 }} /> : <ExpandMoreIcon sx={{ fontSize: 14 }} />}
          </Box>
          <Collapse in={zonesOpen}>
            <List dense disablePadding sx={{ mt: 0.5 }}>
              {faultedZones.map((z) => (
                <ListItem key={z.zoneId} disablePadding sx={{ py: 0.25 }}>
                  <ListItemText
                    primary={z.name}
                    primaryTypographyProps={{ variant: 'caption', color: 'text.secondary' }}
                  />
                </ListItem>
              ))}
            </List>
          </Collapse>
        </>
      )}
    </Box>
  );
}

// ── Main export ───────────────────────────────────────────────────────────────

export function AlarmControl() {
  const { panels, alarmConnected } = useLutron();

  if (!alarmConnected || panels.size === 0) {
    return (
      <Box sx={{ display: 'flex', alignItems: 'center', gap: 1.5, p: 1.5 }}>
        <SecurityIcon sx={{ fontSize: 16, color: 'text.disabled' }} />
        <Typography variant="body2" color="text.disabled">
          {alarmConnected ? 'No panels found' : 'Alarm not connected'}
        </Typography>
      </Box>
    );
  }

  return (
    <Box sx={{ display: 'flex', flexDirection: 'column', gap: 1.5 }}>
      {Array.from(panels.values()).map((panel) => (
        <AlarmPanelCard key={panel.locationId} panel={panel} />
      ))}
    </Box>
  );
}
