import { useState, useEffect, useRef } from 'react';
import { Box, Typography, IconButton } from '@mui/material';
import PowerSettingsNewIcon from '@mui/icons-material/PowerSettingsNew';
import LightbulbIcon from '@mui/icons-material/Lightbulb';
import { useLutron } from '../../context/LutronContext.js';
import type { DeviceState } from '../../types/index.js';

interface LightControlProps {
  device: DeviceState;
}

export function LightControl({ device }: LightControlProps) {
  const { setLevel, trackDevice } = useLutron();
  const [localLevel, setLocalLevel] = useState(device.level);
  const pillRef = useRef<HTMLDivElement>(null);
  const isDragging = useRef(false);
  const pointerDownX = useRef<number | null>(null);
  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    if (!isDragging.current) setLocalLevel(device.level);
  }, [device.level]);

  const isOn = localLevel > 0;

  const handlePointerDown = (e: React.PointerEvent) => {
    if ((e.target as HTMLElement).closest('button')) return;
    pointerDownX.current = e.clientX;
    pillRef.current?.setPointerCapture(e.pointerId);
  };

  const handlePointerMove = (e: React.PointerEvent) => {
    if (pointerDownX.current === null) return;
    const rect = pillRef.current?.getBoundingClientRect();
    if (!rect) return;
    if (!isDragging.current && Math.abs(e.clientX - pointerDownX.current) < 5) return;
    isDragging.current = true;
    const pct = Math.max(1, Math.min(100, ((e.clientX - rect.left) / rect.width) * 100));
    const snapped = Math.round(pct / 5) * 5;
    setLocalLevel(snapped);
    if (debounceRef.current) clearTimeout(debounceRef.current);
    debounceRef.current = setTimeout(() => setLevel(device.integrationId, snapped), 50);
  };

  const handlePointerUp = (e: React.PointerEvent) => {
    if (isDragging.current) {
      const rect = pillRef.current?.getBoundingClientRect();
      if (rect) {
        const pct = Math.max(1, Math.min(100, ((e.clientX - rect.left) / rect.width) * 100));
        const snapped = Math.round(pct / 5) * 5;
        setLevel(device.integrationId, snapped);
        trackDevice(device.integrationId, 'setLevel', device.room, snapped);
      }
    }
    pointerDownX.current = null;
    isDragging.current = false;
  };

  return (
    <Box
      ref={pillRef}
      onPointerDown={handlePointerDown}
      onPointerMove={handlePointerMove}
      onPointerUp={handlePointerUp}
      sx={{
        position: 'relative',
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
          transition: isDragging.current ? 'none' : 'width 0.15s ease-out',
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
