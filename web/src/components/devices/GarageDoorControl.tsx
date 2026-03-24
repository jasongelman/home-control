import { Box, Typography, Button, Chip } from '@mui/material';
import GarageIcon from '@mui/icons-material/Garage';
import type { MyQDoor } from '../../types/index.js';

const STATE_LABEL: Record<MyQDoor['state'], string> = {
  open: 'Open',
  closed: 'Closed',
  opening: 'Opening…',
  closing: 'Closing…',
  stopped: 'Stopped',
  unknown: 'Unknown',
};

const STATE_COLOR: Record<MyQDoor['state'], string> = {
  open: 'rgba(245,166,35,0.85)',
  closed: 'rgba(80,200,120,0.85)',
  opening: 'rgba(100,160,255,0.85)',
  closing: 'rgba(100,160,255,0.85)',
  stopped: 'rgba(255,100,100,0.85)',
  unknown: 'rgba(150,150,150,0.85)',
};

const isTransitioning = (state: MyQDoor['state']) =>
  state === 'opening' || state === 'closing';

interface Props {
  door: MyQDoor;
  onAction: (serial: string, action: 'open' | 'close') => void;
  disabled?: boolean;
}

export function GarageDoorControl({ door, onAction, disabled }: Props) {
  const transitioning = isTransitioning(door.state);
  const canOpen = door.state === 'closed' || door.state === 'stopped';
  const canClose = door.state === 'open' || door.state === 'stopped';

  return (
    <Box
      sx={{
        display: 'flex',
        alignItems: 'center',
        gap: 2,
        p: 2,
        borderRadius: 2,
        border: '1px solid',
        borderColor: door.state === 'open'
          ? 'rgba(245,166,35,0.3)'
          : 'rgba(255,255,255,0.08)',
        bgcolor: door.state === 'open'
          ? 'rgba(245,166,35,0.04)'
          : 'background.paper',
        transition: 'border-color 0.3s ease, background-color 0.3s ease',
      }}
    >
      <GarageIcon
        sx={{
          fontSize: 28,
          color: door.state === 'open' ? 'primary.main' : 'text.disabled',
          transition: 'color 0.3s ease',
          flexShrink: 0,
        }}
      />

      <Box sx={{ flex: 1, minWidth: 0 }}>
        <Typography variant="subtitle2" fontWeight={700} noWrap>
          {door.name}
        </Typography>
        <Chip
          label={STATE_LABEL[door.state]}
          size="small"
          sx={{
            mt: 0.5,
            height: 20,
            fontSize: 11,
            fontWeight: 700,
            bgcolor: STATE_COLOR[door.state],
            color: '#111',
            ...(transitioning && {
              animation: 'pulse 1.2s ease-in-out infinite',
              '@keyframes pulse': {
                '0%, 100%': { opacity: 1 },
                '50%': { opacity: 0.5 },
              },
            }),
          }}
        />
      </Box>

      <Box sx={{ display: 'flex', gap: 1, flexShrink: 0 }}>
        <Button
          size="small"
          variant="outlined"
          disabled={disabled || !canOpen || transitioning}
          onClick={() => onAction(door.serial, 'open')}
          sx={{
            minWidth: 60,
            fontSize: 12,
            borderColor: 'rgba(245,166,35,0.3)',
            color: 'primary.main',
            '&:hover': { borderColor: 'primary.main', bgcolor: 'rgba(245,166,35,0.08)' },
            '&.Mui-disabled': { opacity: 0.35 },
          }}
        >
          Open
        </Button>
        <Button
          size="small"
          variant="outlined"
          disabled={disabled || !canClose || transitioning}
          onClick={() => onAction(door.serial, 'close')}
          sx={{
            minWidth: 60,
            fontSize: 12,
            borderColor: 'rgba(255,255,255,0.15)',
            color: 'text.primary',
            '&:hover': { borderColor: 'rgba(255,255,255,0.3)', bgcolor: 'rgba(255,255,255,0.04)' },
            '&.Mui-disabled': { opacity: 0.35 },
          }}
        >
          Close
        </Button>
      </Box>
    </Box>
  );
}
