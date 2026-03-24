import { Card, Box, Typography, Button } from '@mui/material';
import TouchAppIcon from '@mui/icons-material/TouchApp';
import { useLutron } from '../../context/LutronContext.js';
import type { DeviceState } from '../../types/index.js';

interface KeypadButtonProps {
  device: DeviceState;
}

export function KeypadButton({ device }: KeypadButtonProps) {
  const { pressButton, releaseButton } = useLutron();

  const handlePress = (component: number) => {
    pressButton(device.integrationId, component);
  };

  const handleRelease = (component: number) => {
    releaseButton(device.integrationId, component);
  };

  const components = device.components || [];

  return (
    <Card sx={{ p: 2 }}>
      <Box sx={{ display: 'flex', alignItems: 'center', gap: 1.5, mb: 1.5 }}>
        <TouchAppIcon sx={{ fontSize: 20, color: 'text.secondary' }} />
        <Typography variant="body2" fontWeight={500}>
          {device.name}
        </Typography>
      </Box>
      <Box sx={{ display: 'flex', flexWrap: 'wrap', gap: 1 }}>
        {components.map((comp) => (
          <Button
            key={comp.id}
            variant="outlined"
            size="small"
            onMouseDown={() => handlePress(comp.id)}
            onMouseUp={() => handleRelease(comp.id)}
            onTouchStart={() => handlePress(comp.id)}
            onTouchEnd={() => handleRelease(comp.id)}
            sx={{
              borderColor: 'rgba(255,255,255,0.15)',
              color: 'text.primary',
              fontSize: 13,
              '&:active': { bgcolor: 'primary.main', color: '#000', borderColor: 'primary.main' },
            }}
          >
            {comp.name}
          </Button>
        ))}
        {components.length === 0 && (
          <Typography variant="caption" color="text.secondary">No buttons configured</Typography>
        )}
      </Box>
    </Card>
  );
}
