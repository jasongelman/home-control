import { useState } from 'react';
import { Box, Typography, Chip, Collapse, IconButton } from '@mui/material';
import ExpandMoreIcon from '@mui/icons-material/ExpandMore';
import ExpandLessIcon from '@mui/icons-material/ExpandLess';
import GridViewIcon from '@mui/icons-material/GridView';
import { useLutron } from '../context/LutronContext.js';
import type { KeypadInfo, KeypadButtonInfo } from '../types/index.js';

function LEDButtonRow({ button, onToggle }: { button: KeypadButtonInfo; onToggle: () => void }) {
  const displayName = button.engraving || button.name;
  if (!displayName) return null;

  return (
    <Box sx={{ display: 'flex', alignItems: 'center', gap: 1.5, px: 2, py: 1 }}>
      <Box
        sx={{
          width: 8,
          height: 8,
          borderRadius: '50%',
          bgcolor: button.ledId != null && button.ledState === 'On' ? 'primary.main' : 'rgba(255,255,255,0.15)',
          flexShrink: 0,
        }}
      />
      <Typography variant="body2" sx={{ flex: 1, fontSize: 13 }}>
        {displayName}
      </Typography>
      {button.ledId != null && (
        <Chip
          label={button.ledState === 'On' ? 'ON' : 'OFF'}
          size="small"
          onClick={onToggle}
          sx={{
            height: 22,
            fontSize: 10,
            fontWeight: 700,
            cursor: 'pointer',
            bgcolor: button.ledState === 'On' ? 'primary.main' : 'rgba(255,255,255,0.08)',
            color: button.ledState === 'On' ? '#fff' : 'text.secondary',
            '&:hover': {
              bgcolor: button.ledState === 'On' ? 'primary.dark' : 'rgba(255,255,255,0.15)',
            },
          }}
        />
      )}
    </Box>
  );
}

function KeypadCard({ keypad }: { keypad: KeypadInfo }) {
  const { setLEDState } = useLutron();
  const [expanded, setExpanded] = useState(false);

  const activeCount = keypad.buttons.filter((b) => b.ledState === 'On').length;
  const visibleButtons = keypad.buttons.filter((b) => b.engraving || b.name);

  return (
    <Box
      sx={{
        bgcolor: 'background.paper',
        border: '1px solid rgba(255,255,255,0.08)',
        borderRadius: 2,
        overflow: 'hidden',
      }}
    >
      <Box
        onClick={() => setExpanded(!expanded)}
        sx={{
          display: 'flex',
          alignItems: 'center',
          gap: 1.5,
          p: 2,
          cursor: 'pointer',
          '&:hover': { bgcolor: 'rgba(255,255,255,0.03)' },
        }}
      >
        <GridViewIcon sx={{ color: 'primary.main', fontSize: 22 }} />
        <Box sx={{ flex: 1 }}>
          <Typography variant="subtitle2" sx={{ fontWeight: 600, lineHeight: 1.3 }}>
            {keypad.name}
          </Typography>
          <Typography variant="caption" color="text.secondary">
            {keypad.deviceType}
            {keypad.modelNumber && ` \u00B7 ${keypad.modelNumber}`}
          </Typography>
        </Box>
        {activeCount > 0 && (
          <Chip
            label={activeCount}
            size="small"
            sx={{
              height: 20,
              fontSize: 10,
              fontWeight: 700,
              bgcolor: 'primary.main',
              color: '#fff',
              '& .MuiChip-label': { px: 0.75 },
            }}
          />
        )}
        <IconButton size="small" sx={{ color: 'text.secondary' }}>
          {expanded ? <ExpandLessIcon fontSize="small" /> : <ExpandMoreIcon fontSize="small" />}
        </IconButton>
      </Box>
      <Collapse in={expanded}>
        <Box sx={{ borderTop: '1px solid rgba(255,255,255,0.06)', py: 0.5 }}>
          {visibleButtons.map((button) => (
            <LEDButtonRow
              key={button.id}
              button={button}
              onToggle={() => {
                if (button.ledId != null) {
                  setLEDState(button.ledId, button.ledState === 'On' ? 'Off' : 'On');
                }
              }}
            />
          ))}
        </Box>
      </Collapse>
    </Box>
  );
}

export function KeypadsSection() {
  const { keypads } = useLutron();

  if (keypads.length === 0) return null;

  const grouped = new Map<string, KeypadInfo[]>();
  for (const kp of keypads) {
    const list = grouped.get(kp.areaName) ?? [];
    list.push(kp);
    grouped.set(kp.areaName, list);
  }
  const rooms = Array.from(grouped.entries())
    .map(([room, kps]) => ({ room, keypads: kps.sort((a, b) => a.name.localeCompare(b.name)) }))
    .sort((a, b) => a.room.localeCompare(b.room));

  return (
    <>
      <Box sx={{ display: 'flex', alignItems: 'center', gap: 1, mt: 4, mb: 1.5 }}>
        <Typography variant="subtitle2" color="text.secondary">
          Keypads
        </Typography>
        <Chip
          label={keypads.length}
          size="small"
          sx={{
            height: 20,
            fontSize: 11,
            fontWeight: 700,
            bgcolor: 'rgba(255,255,255,0.08)',
            color: 'text.secondary',
          }}
        />
      </Box>
      <Box sx={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
        {rooms.map(({ room, keypads: roomKeypads }) => (
          <Box key={room}>
            <Typography
              variant="caption"
              sx={{
                fontWeight: 600,
                color: 'text.secondary',
                textTransform: 'uppercase',
                letterSpacing: '0.08em',
                fontSize: 10,
                mb: 0.75,
                display: 'block',
              }}
            >
              {room}
            </Typography>
            <Box sx={{ display: 'flex', flexDirection: 'column', gap: 1 }}>
              {roomKeypads.map((kp) => (
                <KeypadCard key={kp.deviceId} keypad={kp} />
              ))}
            </Box>
          </Box>
        ))}
      </Box>
    </>
  );
}
