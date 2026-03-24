import { Box, Typography, Grid, Chip, Divider } from '@mui/material';
import LightbulbIcon from '@mui/icons-material/Lightbulb';
import BlindsIcon from '@mui/icons-material/Blinds';
import KeyboardIcon from '@mui/icons-material/Keyboard';
import type { DeviceState } from '../types/index.js';
import { LightControl } from './devices/LightControl.js';
import { ShadeControl } from './devices/ShadeControl.js';
import { KeypadButton } from './devices/KeypadButton.js';

interface RoomDetailProps {
  devices: DeviceState[];
}

function SectionHeader({ icon, label, count }: { icon: React.ReactNode; label: string; count: number }) {
  return (
    <Box sx={{ display: 'flex', alignItems: 'center', gap: 1, mb: 2 }}>
      {icon}
      <Typography variant="subtitle2" color="text.secondary">
        {label}
      </Typography>
      <Chip label={count} size="small" sx={{ height: 20, fontSize: 11, fontWeight: 700, bgcolor: 'rgba(255,255,255,0.08)', color: 'text.secondary' }} />
      <Divider sx={{ flex: 1, borderColor: 'rgba(255,255,255,0.06)' }} />
    </Box>
  );
}

export function RoomDetail({ devices }: RoomDetailProps) {
  const lights = devices.filter((d) => d.type === 'light');
  const shades = devices.filter((d) => d.type === 'shade');
  const keypads = devices.filter((d) => d.type === 'keypad');

  return (
    <Box sx={{ px: { xs: 2, sm: 3 }, py: 2.5, maxWidth: 1200, mx: 'auto' }}>
      {lights.length > 0 && (
        <Box sx={{ mb: 3 }}>
          <SectionHeader
            icon={<LightbulbIcon sx={{ fontSize: 18, color: 'text.secondary' }} />}
            label="Lights"
            count={lights.length}
          />
          <Grid container spacing={1.5}>
            {lights.map((d) => (
              <Grid size={{ xs: 12, sm: 6 }} key={d.integrationId}>
                <LightControl device={d} />
              </Grid>
            ))}
          </Grid>
        </Box>
      )}
      {shades.length > 0 && (
        <Box sx={{ mb: 3 }}>
          <SectionHeader
            icon={<BlindsIcon sx={{ fontSize: 18, color: 'text.secondary' }} />}
            label="Shades"
            count={shades.length}
          />
          <Grid container spacing={1.5}>
            {shades.map((d) => (
              <Grid size={{ xs: 12, sm: 6 }} key={d.integrationId}>
                <ShadeControl device={d} />
              </Grid>
            ))}
          </Grid>
        </Box>
      )}
      {keypads.length > 0 && (
        <Box sx={{ mb: 3 }}>
          <SectionHeader
            icon={<KeyboardIcon sx={{ fontSize: 18, color: 'text.secondary' }} />}
            label="Scenes"
            count={keypads.length}
          />
          <Grid container spacing={1.5}>
            {keypads.map((d) => (
              <Grid size={{ xs: 12, sm: 6 }} key={d.integrationId}>
                <KeypadButton device={d} />
              </Grid>
            ))}
          </Grid>
        </Box>
      )}
    </Box>
  );
}
