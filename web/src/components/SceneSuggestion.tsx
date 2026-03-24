import { useCallback } from 'react';
import { Box, Typography, Button, Paper, IconButton } from '@mui/material';
import AutoAwesomeIcon from '@mui/icons-material/AutoAwesome';
import CloseIcon from '@mui/icons-material/Close';
import AddIcon from '@mui/icons-material/Add';
import type { DetectedPattern } from '../hooks/usePatternDetector.js';
import { dismissPattern } from '../hooks/usePatternDetector.js';
import type { DeviceState } from '../types/index.js';

interface SceneSuggestionProps {
  pattern: DetectedPattern;
  devices: Map<number, DeviceState>;
  onCreateScene: (targets: { deviceId: number; level: number }[]) => void;
  onDismiss: (hash: string) => void;
}

export function SceneSuggestion({ pattern, devices, onCreateScene, onDismiss }: SceneSuggestionProps) {
  const handleDismiss = useCallback(() => {
    dismissPattern(pattern.hash);
    onDismiss(pattern.hash);
  }, [pattern.hash, onDismiss]);

  const handleCreate = useCallback(() => {
    const targets = pattern.devices.map((d) => ({
      deviceId: d.id,
      level: d.avgLevel,
    }));
    onCreateScene(targets);
  }, [pattern, onCreateScene]);

  // Build a human-readable description
  const description = pattern.devices
    .map((d) => {
      const device = devices.get(d.id);
      const name = device ? `${device.room} ${device.name}` : `Device ${d.id}`;
      return `${name} ${d.avgLevel}%`;
    })
    .join(', ');

  const timeLabel = pattern.timeOfDay ? ` in the ${pattern.timeOfDay}` : '';

  return (
    <Paper
      sx={{
        p: 2,
        mb: 2,
        border: '1px solid rgba(245,166,35,0.2)',
        bgcolor: 'rgba(245,166,35,0.04)',
        borderRadius: 2,
      }}
    >
      <Box sx={{ display: 'flex', alignItems: 'flex-start', gap: 1.5 }}>
        <AutoAwesomeIcon sx={{ fontSize: 20, color: 'primary.main', mt: 0.25 }} />
        <Box sx={{ flex: 1 }}>
          <Typography variant="body2" fontWeight={600} sx={{ mb: 0.5 }}>
            Suggested Scene
          </Typography>
          <Typography variant="caption" color="text.secondary" sx={{ display: 'block', mb: 1.5 }}>
            You often set {description}{timeLabel} ({pattern.frequency} times)
          </Typography>
          <Box sx={{ display: 'flex', gap: 1 }}>
            <Button
              size="small"
              variant="contained"
              startIcon={<AddIcon />}
              onClick={handleCreate}
              sx={{
                bgcolor: 'primary.main',
                color: '#000',
                fontWeight: 600,
                fontSize: 12,
                '&:hover': { bgcolor: 'primary.light' },
              }}
            >
              Create Scene
            </Button>
          </Box>
        </Box>
        <IconButton size="small" onClick={handleDismiss} sx={{ color: 'text.secondary' }}>
          <CloseIcon fontSize="small" />
        </IconButton>
      </Box>
    </Paper>
  );
}
