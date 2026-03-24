import { useState, useCallback } from 'react';
import {
  Dialog, DialogTitle, DialogContent, DialogActions, Button, TextField, Box,
  Typography, ToggleButtonGroup, ToggleButton, Checkbox, Slider, FormControlLabel,
} from '@mui/material';
import CameraAltIcon from '@mui/icons-material/CameraAlt';
import TuneIcon from '@mui/icons-material/Tune';
import type { Scene, SceneDeviceTarget, DeviceState } from '../types/index.js';

const SCENE_ICONS = [
  '\u{1F319}', '\u{2600}\u{FE0F}', '\u{1F3AC}', '\u{1F3B5}', '\u{1F4A4}',
  '\u{1F37D}\u{FE0F}', '\u{1F389}', '\u{1F4DA}', '\u{1F3AE}', '\u{1F9D8}',
  '\u{2615}', '\u{1F3E0}', '\u{1F496}', '\u{1F30A}', '\u{1F525}', '\u{2728}',
];

interface SceneEditorProps {
  scene: Scene | null;
  rooms: Map<string, DeviceState[]>;
  onSave: (data: { name: string; icon: string; targets: SceneDeviceTarget[] }) => void;
  onClose: () => void;
  onCapture: () => Promise<SceneDeviceTarget[]>;
}

export function SceneEditor({ scene, rooms, onSave, onClose, onCapture }: SceneEditorProps) {
  const [name, setName] = useState(scene?.name || '');
  const [icon, setIcon] = useState(scene?.icon || SCENE_ICONS[0]);
  const [mode, setMode] = useState<'capture' | 'manual'>('capture');
  const [targets, setTargets] = useState<Map<number, number>>(() => {
    const m = new Map<number, number>();
    if (scene) {
      for (const t of scene.targets) m.set(t.deviceId, t.level);
    }
    return m;
  });
  const [captured, setCaptured] = useState(false);

  const handleCapture = useCallback(async () => {
    const result = await onCapture();
    const m = new Map<number, number>();
    for (const t of result) m.set(t.deviceId, t.level);
    setTargets(m);
    setCaptured(true);
  }, [onCapture]);

  const toggleDevice = (deviceId: number, currentLevel: number) => {
    setTargets((prev) => {
      const next = new Map(prev);
      if (next.has(deviceId)) {
        next.delete(deviceId);
      } else {
        next.set(deviceId, currentLevel > 0 ? currentLevel : 100);
      }
      return next;
    });
  };

  const setDeviceLevel = (deviceId: number, level: number) => {
    setTargets((prev) => {
      const next = new Map(prev);
      next.set(deviceId, level);
      return next;
    });
  };

  const handleSave = () => {
    if (!name.trim()) return;
    const targetList: SceneDeviceTarget[] = [];
    for (const [deviceId, level] of targets) {
      targetList.push({ deviceId, level });
    }
    onSave({ name: name.trim(), icon, targets: targetList });
  };

  const allRooms = Array.from(rooms.entries()).filter(([, devs]) =>
    devs.some((d) => d.type === 'light' || d.type === 'shade')
  );

  return (
    <Dialog
      open
      onClose={onClose}
      maxWidth="sm"
      fullWidth
      slotProps={{
        backdrop: { sx: { backdropFilter: 'blur(8px)' } },
      }}
    >
      <DialogTitle sx={{ fontWeight: 700 }}>
        {scene ? 'Edit Scene' : 'New Scene'}
      </DialogTitle>
      <DialogContent dividers>
        <TextField
          fullWidth
          placeholder="Scene name..."
          value={name}
          onChange={(e) => setName(e.target.value)}
          autoFocus
          size="small"
          sx={{ mb: 2 }}
        />

        {/* Icon Picker */}
        <Typography variant="caption" color="text.secondary" sx={{ mb: 1, display: 'block' }}>Icon</Typography>
        <Box sx={{ display: 'flex', flexWrap: 'wrap', gap: 0.75, mb: 2.5 }}>
          {SCENE_ICONS.map((ic) => (
            <Box
              key={ic}
              onClick={() => setIcon(ic)}
              sx={{
                width: 40,
                height: 40,
                borderRadius: 1.5,
                border: '1px solid',
                borderColor: icon === ic ? 'primary.main' : 'rgba(255,255,255,0.12)',
                bgcolor: icon === ic ? 'rgba(245,166,35,0.12)' : 'background.default',
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
                fontSize: 20,
                cursor: 'pointer',
                transition: 'all 0.15s',
                '&:hover': { borderColor: 'primary.main' },
              }}
            >
              {ic}
            </Box>
          ))}
        </Box>

        {/* Mode Tabs */}
        <ToggleButtonGroup
          value={mode}
          exclusive
          onChange={(_, v) => v && setMode(v)}
          fullWidth
          size="small"
          sx={{ mb: 2 }}
        >
          <ToggleButton value="capture" sx={{ gap: 1 }}>
            <CameraAltIcon sx={{ fontSize: 16 }} /> Capture Current
          </ToggleButton>
          <ToggleButton value="manual" sx={{ gap: 1 }}>
            <TuneIcon sx={{ fontSize: 16 }} /> Manual
          </ToggleButton>
        </ToggleButtonGroup>

        {mode === 'capture' ? (
          <Box sx={{ mb: 2 }}>
            <Typography variant="body2" color="text.secondary" sx={{ mb: 1.5 }}>
              Set your lights to the levels you want, then capture the current state.
            </Typography>
            <Button variant="outlined" onClick={handleCapture} color={captured ? 'success' : 'primary'}>
              {captured ? `Captured ${targets.size} devices` : 'Capture Current State'}
            </Button>
          </Box>
        ) : (
          <Box sx={{ maxHeight: 300, overflowY: 'auto', mb: 2 }}>
            {allRooms.map(([roomName, devs]) => {
              const controllable = devs.filter((d) => d.type === 'light' || d.type === 'shade');
              return (
                <Box key={roomName} sx={{ mb: 1.5 }}>
                  <Typography variant="caption" color="text.secondary" sx={{ textTransform: 'uppercase', letterSpacing: '0.06em', fontWeight: 600 }}>
                    {roomName}
                  </Typography>
                  {controllable.map((d) => {
                    const included = targets.has(d.integrationId);
                    const level = targets.get(d.integrationId) ?? d.level;
                    return (
                      <Box
                        key={d.integrationId}
                        sx={{
                          display: 'flex',
                          alignItems: 'center',
                          gap: 1,
                          py: 0.75,
                          px: 1.5,
                          borderRadius: 1,
                          bgcolor: 'background.default',
                          mb: 0.5,
                        }}
                      >
                        <FormControlLabel
                          control={
                            <Checkbox
                              size="small"
                              checked={included}
                              onChange={() => toggleDevice(d.integrationId, d.level)}
                              sx={{ '&.Mui-checked': { color: 'primary.main' } }}
                            />
                          }
                          label={<Typography variant="body2">{d.name}</Typography>}
                          sx={{ flex: 1, m: 0 }}
                        />
                        {included && (
                          <>
                            <Slider
                              value={level}
                              onChange={(_, v) => setDeviceLevel(d.integrationId, v as number)}
                              min={0}
                              max={100}
                              size="small"
                              sx={{ width: 80, mx: 1 }}
                            />
                            <Typography variant="caption" color="text.secondary" sx={{ minWidth: 32, textAlign: 'right', fontVariantNumeric: 'tabular-nums' }}>
                              {level}%
                            </Typography>
                          </>
                        )}
                      </Box>
                    );
                  })}
                </Box>
              );
            })}
          </Box>
        )}
      </DialogContent>
      <DialogActions sx={{ px: 3, py: 2 }}>
        <Button onClick={onClose} color="inherit">Cancel</Button>
        <Button variant="contained" onClick={handleSave} disabled={!name.trim() || targets.size === 0}>
          {scene ? 'Update' : 'Create'} Scene
        </Button>
      </DialogActions>
    </Dialog>
  );
}
