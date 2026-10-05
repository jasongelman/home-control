import { Box, Typography, IconButton } from '@mui/material';
import PowerSettingsNewIcon from '@mui/icons-material/PowerSettingsNew';
import LightbulbIcon from '@mui/icons-material/Lightbulb';
import { useLutron } from '../../context/LutronContext.js';
import type { DeviceState } from '../../types/index.js';
import { useHorizontalDrag } from '../../hooks/useHorizontalDrag.js';

interface LightControlProps {
  device: DeviceState;
}

export function LightControl({ device }: LightControlProps) {
  const { setLevel, trackDevice } = useLutron();
  const { ref: pillRef, localLevel, setLocalLevel, dragging, handlers } = useHorizontalDrag<HTMLDivElement>(device.level, {
    min: 1,
    onAdjust: (v) => setLevel(device.integrationId, v),
    onCommit: (v) => {
      setLevel(device.integrationId, v);
      trackDevice(device.integrationId, 'setLevel', device.room, v);
    },
    // Inner on/off buttons handle their own clicks.
    ignore: (e) => !!(e.target as HTMLElement).closest('button'),
  });

  const isOn = localLevel > 0;

  return (
    <Box
      ref={pillRef}
      {...handlers}
      sx={{
        position: 'relative',
        touchAction: 'pan-y',
        height: 40,
        borderRadius: 1.5,
        overflow: 'hidden',
        border: '1px solid',
        borderColor: isOn ? 'rgba(245,166,35,0.3)' : 'rgba(255,255,255,0.1)',
        cursor: 'ew-resize',
        userSelect: 'none',
        bgcolor: 'rgba(255,255,255,0.04)',
      }}
    >
      <Box
        sx={{
          position: 'absolute',
          inset: 0,
          width: `${localLevel}%`,
          bgcolor: 'rgba(245,166,35,0.32)',
          transition: dragging ? 'none' : 'width 0.15s ease-out',
          pointerEvents: 'none',
        }}
      />
      <Box sx={{ position: 'relative', display: 'flex', alignItems: 'center', height: '100%' }}>
        <IconButton
          size="small"
          onClick={() => {
            setLocalLevel(0);
            setLevel(device.integrationId, 0, 1);
            trackDevice(device.integrationId, 'turnOff', device.room, 0);
          }}
          sx={{ width: 40, height: 40, borderRadius: 0, flexShrink: 0, color: isOn ? 'primary.main' : 'rgba(255,255,255,0.3)' }}
        >
          <PowerSettingsNewIcon sx={{ fontSize: 14 }} />
        </IconButton>
        <Typography
          variant="body2"
          fontWeight={500}
          sx={{ flex: 1, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', fontSize: 12, color: isOn ? 'text.primary' : 'text.secondary' }}
        >
          {device.name}
        </Typography>
        <IconButton
          size="small"
          onClick={() => {
            setLocalLevel(100);
            setLevel(device.integrationId, 100, 1);
            trackDevice(device.integrationId, 'setLevel', device.room, 100);
          }}
          sx={{ width: 40, height: 40, borderRadius: 0, flexShrink: 0, color: isOn ? 'primary.main' : 'rgba(255,255,255,0.3)' }}
        >
          <LightbulbIcon sx={{ fontSize: 14 }} />
        </IconButton>
      </Box>
    </Box>
  );
}
