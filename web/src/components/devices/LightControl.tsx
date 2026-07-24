import { useState, useEffect, useRef } from 'react';
import { Box, Typography, IconButton, Popover, Slider, Tooltip } from '@mui/material';
import PowerSettingsNewIcon from '@mui/icons-material/PowerSettingsNew';
import LightbulbIcon from '@mui/icons-material/Lightbulb';
import PaletteIcon from '@mui/icons-material/Palette';
import { useLutron } from '../../context/LutronContext.js';
import type { DeviceState } from '../../types/index.js';

interface LightControlProps {
  device: DeviceState;
}

// ── HSV / RGB helpers (Hue 0–360, Saturation/Value 0–100) ────────────────────
function hsvToRgb(h: number, s: number, v: number): [number, number, number] {
  s /= 100; v /= 100;
  const c = v * s;
  const x = c * (1 - Math.abs(((h / 60) % 2) - 1));
  const m = v - c;
  let r = 0, g = 0, b = 0;
  if (h < 60) [r, g, b] = [c, x, 0];
  else if (h < 120) [r, g, b] = [x, c, 0];
  else if (h < 180) [r, g, b] = [0, c, x];
  else if (h < 240) [r, g, b] = [0, x, c];
  else if (h < 300) [r, g, b] = [x, 0, c];
  else [r, g, b] = [c, 0, x];
  return [Math.round((r + m) * 255), Math.round((g + m) * 255), Math.round((b + m) * 255)];
}

function hsvToHex(h: number, s: number, v = 100): string {
  const [r, g, b] = hsvToRgb(h, s, v);
  return '#' + [r, g, b].map((n) => n.toString(16).padStart(2, '0')).join('');
}

/** Convert a #rrggbb hex to Hue (0–360) + Saturation (0–100). Value is dropped (brightness is separate). */
function hexToHueSat(hex: string): { hue: number; saturation: number } {
  const r = parseInt(hex.slice(1, 3), 16) / 255;
  const g = parseInt(hex.slice(3, 5), 16) / 255;
  const b = parseInt(hex.slice(5, 7), 16) / 255;
  const max = Math.max(r, g, b), min = Math.min(r, g, b);
  const d = max - min;
  let h = 0;
  if (d !== 0) {
    if (max === r) h = ((g - b) / d) % 6;
    else if (max === g) h = (b - r) / d + 2;
    else h = (r - g) / d + 4;
    h *= 60;
    if (h < 0) h += 360;
  }
  const saturation = max === 0 ? 0 : (d / max) * 100;
  return { hue: Math.round(h), saturation: Math.round(saturation) };
}

// Preset color shortcuts (mirror the physical "Colors" keypad palette).
const COLOR_PRESETS: Array<{ name: string; hue: number; saturation: number }> = [
  { name: 'Red', hue: 0, saturation: 100 },
  { name: 'Orange', hue: 30, saturation: 100 },
  { name: 'Yellow', hue: 55, saturation: 100 },
  { name: 'Green', hue: 120, saturation: 100 },
  { name: 'Aqua', hue: 180, saturation: 100 },
  { name: 'Blue', hue: 220, saturation: 100 },
  { name: 'Purple', hue: 275, saturation: 100 },
  { name: 'Pink', hue: 320, saturation: 90 },
  { name: 'White', hue: 0, saturation: 0 },
];

export function LightControl({ device }: LightControlProps) {
  const { setLevel, setColor, trackDevice } = useLutron();
  const [colorAnchor, setColorAnchor] = useState<HTMLElement | null>(null);
  const hsv = device.hsv ?? { hue: 210, saturation: 80 };
  const swatch = hsvToHex(hsv.hue, hsv.saturation, 100);

  const applyColor = (hue: number, saturation: number) => {
    setColor(device.integrationId, hue, saturation);
    trackDevice(device.integrationId, 'setLevel', device.room, device.level || 100);
  };
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
        {device.colorCapable && (
          <Tooltip title="Color">
            <IconButton
              size="small"
              onClick={(e) => setColorAnchor(e.currentTarget)}
              sx={{ width: 32, height: 40, borderRadius: 0, flexShrink: 0, p: 0 }}
            >
              <Box
                sx={{
                  width: 16, height: 16, borderRadius: '50%',
                  background: swatch,
                  border: '1.5px solid rgba(255,255,255,0.55)',
                  boxShadow: '0 0 6px rgba(0,0,0,0.4)',
                }}
              />
            </IconButton>
          </Tooltip>
        )}
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

      {device.colorCapable && (
        <Popover
          open={Boolean(colorAnchor)}
          anchorEl={colorAnchor}
          onClose={() => setColorAnchor(null)}
          anchorOrigin={{ vertical: 'bottom', horizontal: 'right' }}
          transformOrigin={{ vertical: 'top', horizontal: 'right' }}
          slotProps={{ paper: { sx: { p: 2, width: 260, bgcolor: '#1c1c1e', backgroundImage: 'none' } } }}
        >
          <Box onPointerDown={(e) => e.stopPropagation()} onPointerMove={(e) => e.stopPropagation()} onPointerUp={(e) => e.stopPropagation()}>
            <Box sx={{ display: 'flex', alignItems: 'center', gap: 1, mb: 1.5 }}>
              <PaletteIcon sx={{ fontSize: 16, color: 'primary.main' }} />
              <Typography variant="caption" sx={{ letterSpacing: 0.8, fontWeight: 600 }}>
                {device.name.toUpperCase()} · COLOR
              </Typography>
            </Box>

            {/* Full color wheel (native picker → RGB → HSV) */}
            <Box
              component="input"
              type="color"
              value={swatch}
              onChange={(e: React.ChangeEvent<HTMLInputElement>) => {
                const { hue, saturation } = hexToHueSat(e.target.value);
                applyColor(hue, saturation);
              }}
              sx={{
                width: '100%', height: 44, p: 0, border: 'none',
                borderRadius: 1, cursor: 'pointer', bgcolor: 'transparent',
              }}
            />

            {/* Preset shortcuts */}
            <Box sx={{ display: 'flex', flexWrap: 'wrap', gap: 0.75, mt: 1.5 }}>
              {COLOR_PRESETS.map((p) => {
                const hex = hsvToHex(p.hue, p.saturation, 100);
                const active = Math.abs(hsv.hue - p.hue) < 6 && Math.abs(hsv.saturation - p.saturation) < 6;
                return (
                  <Tooltip title={p.name} key={p.name}>
                    <Box
                      onClick={() => applyColor(p.hue, p.saturation)}
                      sx={{
                        width: 24, height: 24, borderRadius: '50%', cursor: 'pointer',
                        background: hex,
                        border: active ? '2px solid #f5a623' : '1px solid rgba(255,255,255,0.25)',
                      }}
                    />
                  </Tooltip>
                );
              })}
            </Box>

            {/* Brightness slider */}
            <Typography variant="caption" sx={{ display: 'block', mt: 2, mb: 0.5, color: 'text.secondary', letterSpacing: 0.8 }}>
              BRIGHTNESS · {Math.round(localLevel)}%
            </Typography>
            <Slider
              size="small"
              value={localLevel}
              min={0}
              max={100}
              onChange={(_, v) => setLocalLevel(v as number)}
              onChangeCommitted={(_, v) => {
                const lvl = v as number;
                // Re-send color with new level so the color is preserved at the new brightness.
                setColor(device.integrationId, hsv.hue, hsv.saturation, lvl);
                trackDevice(device.integrationId, lvl === 0 ? 'turnOff' : 'setLevel', device.room, lvl);
              }}
            />
          </Box>
        </Popover>
      )}
    </Box>
  );
}
