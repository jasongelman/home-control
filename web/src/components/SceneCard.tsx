import { useState } from 'react';
import { Chip, IconButton, Box } from '@mui/material';
import EditIcon from '@mui/icons-material/Edit';
import DeleteIcon from '@mui/icons-material/Delete';
import type { Scene } from '../types/index.js';

interface SceneCardProps {
  scene: Scene;
  onActivate: () => void;
  onEdit: () => void;
  onDelete: () => void;
}

export function SceneCard({ scene, onActivate, onEdit, onDelete }: SceneCardProps) {
  const [activating, setActivating] = useState(false);

  const handleActivate = async () => {
    setActivating(true);
    await onActivate();
    setTimeout(() => setActivating(false), 1500);
  };

  return (
    <Box sx={{ display: 'flex', alignItems: 'center', flexShrink: 0 }}>
      <Chip
        icon={<span style={{ fontSize: 18, lineHeight: 1 }}>{scene.icon}</span>}
        label={scene.name}
        onClick={handleActivate}
        variant="outlined"
        sx={{
          height: 40,
          borderRadius: 20,
          px: 1,
          fontSize: 14,
          fontWeight: 500,
          borderColor: activating ? 'primary.main' : 'rgba(255,255,255,0.12)',
          bgcolor: activating ? 'rgba(245,166,35,0.08)' : 'background.paper',
          boxShadow: activating ? '0 0 16px rgba(245,166,35,0.2)' : 'none',
          transition: 'all 0.25s ease',
          '&:hover': {
            bgcolor: 'rgba(255,255,255,0.06)',
            borderColor: 'rgba(255,255,255,0.2)',
            transform: 'translateY(-1px)',
          },
          '& .MuiChip-icon': { ml: 0.5 },
        }}
      />
      <IconButton size="small" onClick={onEdit} sx={{ ml: 0.5, color: 'text.secondary', p: 0.5 }}>
        <EditIcon sx={{ fontSize: 14 }} />
      </IconButton>
      <IconButton size="small" onClick={onDelete} sx={{ color: 'text.secondary', p: 0.5, '&:hover': { color: 'error.main' } }}>
        <DeleteIcon sx={{ fontSize: 14 }} />
      </IconButton>
    </Box>
  );
}
