import { Box, Typography, ButtonBase } from '@mui/material';
import BlindsIcon from '@mui/icons-material/Blinds';
import BlindsClosedIcon from '@mui/icons-material/BlindsClosed';
import { useLutron } from '../../context/LutronContext.js';
import type { DeviceState } from '../../types/index.js';

interface ShadeControlProps {
  device: DeviceState;
}

// Shades are set by preset only — no granular slider (a drag surface invites
// accidental moves while scrolling on touch devices). Matches iOS.
const SHADE_PRESETS: { value: number; label: string }[] = [
  { value: 0, label: 'Close' },
  { value: 25, label: '25%' },
  { value: 50, label: '50%' },
  { value: 75, label: '75%' },
  { value: 100, label: 'Open' },
];

export function ShadeControl({ device }: ShadeControlProps) {
  const { setLevel, trackDevice } = useLutron();
  const level = Math.round(device.level);
  const isOpen = level > 0;

  const applyPreset = (preset: number) => {
    setLevel(device.integrationId, preset, 2);
    trackDevice(device.integrationId, preset === 0 ? 'turnOff' : 'setLevel', device.room, preset);
  };

  return (
    <Box
      sx={{
        borderRadius: 1.5,
        border: '1px solid',
        borderColor: isOpen ? 'rgba(0,188,212,0.3)' : 'rgba(255,255,255,0.1)',
        bgcolor: 'rgba(255,255,255,0.04)',
        p: 1,
      }}
    >
      <Box sx={{ display: 'flex', alignItems: 'center', gap: 0.75, mb: 1, px: 0.25 }}>
        {isOpen
          ? <BlindsIcon sx={{ fontSize: 14, color: 'secondary.main', flexShrink: 0 }} />
          : <BlindsClosedIcon sx={{ fontSize: 14, color: 'rgba(255,255,255,0.3)', flexShrink: 0 }} />}
        <Typography
          variant="body2"
          fontWeight={500}
          sx={{ flex: 1, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', fontSize: 12, color: isOpen ? 'text.primary' : 'text.secondary' }}
        >
          {device.name}
        </Typography>
        <Typography
          variant="caption"
          sx={{ fontSize: 11, fontWeight: 600, fontVariantNumeric: 'tabular-nums', flexShrink: 0, color: isOpen ? 'secondary.main' : 'text.secondary' }}
        >
          {level}%
        </Typography>
      </Box>
      <Box sx={{ display: 'grid', gridTemplateColumns: 'repeat(5, 1fr)', gap: 0.5 }}>
        {SHADE_PRESETS.map((p) => {
          const active = Math.abs(level - p.value) <= 2;
          return (
            <ButtonBase
              key={p.value}
              onClick={() => applyPreset(p.value)}
              aria-pressed={active}
              aria-label={`${device.name} ${p.value === 0 ? 'close' : p.value === 100 ? 'open' : `${p.value}%`}`}
              sx={{
                height: 32,
                borderRadius: 1,
                fontSize: 11,
                fontWeight: 700,
                letterSpacing: '0.03em',
                textTransform: 'uppercase',
                border: '1px solid',
                borderColor: active ? 'rgba(0,188,212,0.5)' : 'rgba(255,255,255,0.08)',
                bgcolor: active ? 'rgba(0,188,212,0.22)' : 'rgba(255,255,255,0.03)',
                color: active ? 'secondary.main' : 'text.secondary',
                transition: 'background-color 0.15s ease, border-color 0.15s ease, color 0.15s ease',
                '&:hover': { bgcolor: active ? 'rgba(0,188,212,0.28)' : 'rgba(255,255,255,0.07)' },
              }}
            >
              {p.label}
            </ButtonBase>
          );
        })}
      </Box>
    </Box>
  );
}
