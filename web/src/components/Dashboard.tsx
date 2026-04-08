import { useMemo, useState, useCallback, useRef, useEffect } from 'react';
import {
  AppBar, Toolbar, Typography, IconButton, Box, Grid, Card, CardActionArea,
  LinearProgress, Chip, Button, Tooltip, Paper,
} from '@mui/material';
import SettingsIcon from '@mui/icons-material/Settings';
import AddIcon from '@mui/icons-material/Add';
import ArrowBackIcon from '@mui/icons-material/ArrowBack';
import FiberManualRecordIcon from '@mui/icons-material/FiberManualRecord';
import LightbulbIcon from '@mui/icons-material/Lightbulb';
import NightlightIcon from '@mui/icons-material/Nightlight';
import DownhillSkiingIcon from '@mui/icons-material/DownhillSkiing';
import BlindsClosedIcon from '@mui/icons-material/BlindsClosed';
import PowerOffIcon from '@mui/icons-material/PowerOff';
import AutoAwesomeIcon from '@mui/icons-material/AutoAwesome';
import PlayArrowIcon from '@mui/icons-material/PlayArrow';
import { useLutron } from '../context/LutronContext.js';
import { GarageDoorControl } from './devices/GarageDoorControl.js';
import { AppliancesSection } from './AppliancesSection.js';
import { AlarmControl } from './AlarmControl.js';
import { RoomDetail } from './RoomDetail.js';
import { SceneEditor } from './SceneEditor.js';
import { SettingsDialog } from './SettingsDialog.js';
import { useScenes } from '../hooks/useScenes.js';
import { useAdaptiveDashboard } from '../hooks/useAdaptiveDashboard.js';
import { usePatternDetector } from '../hooks/usePatternDetector.js';
import { SceneSuggestion } from './SceneSuggestion.js';
import type { Scene } from '../types/index.js';
import { ChatPanel } from './ChatPanel.js';

const ROOM_ICONS: Record<string, string> = {
  'Kitchen': '\u{1F373}',
  'Master Suite': '\u{1F6CF}\u{FE0F}',
  'Master Bedroom': '\u{1F6CF}\u{FE0F}',
  'Master Bath': '\u{1F6C1}',
  'Master Closet': '\u{1F455}',
  'Living Room': '\u{1F6CB}\u{FE0F}',
  'Family Room': '\u{1F4FA}',
  'Dining Room': '\u{1F37D}\u{FE0F}',
  'Office': '\u{1F4BB}',
  'Jason Office': '\u{1F4BB}',
  'Garage': '\u{1F697}',
  'Laundry': '\u{1F9FA}',
  'Bathroom': '\u{1F6BF}',
  'Hallway': '\u{1F6AA}',
  'Entry': '\u{1F6AA}',
  'Foyer': '\u{1F6AA}',
  'Patio': '\u{2600}\u{FE0F}',
  'Deck': '\u{2600}\u{FE0F}',
  'Outdoor': '\u{1F333}',
  'Exterior': '\u{1F333}',
  'Nursery': '\u{1F476}',
  'Kids Room': '\u{1F9F8}',
  'Guest Room': '\u{1F6CF}\u{FE0F}',
  'Basement': '\u{1F3DA}\u{FE0F}',
  'Theater': '\u{1F3AC}',
  'Media Room': '\u{1F3AC}',
  'Gym': '\u{1F3CB}\u{FE0F}',
  'Pool': '\u{1F3CA}',
  'Stairway': '\u{1F4F6}',
  'Powder Room': '\u{1F6BF}',
};

function getRoomIcon(roomName: string): string {
  if (ROOM_ICONS[roomName]) return ROOM_ICONS[roomName];
  const lower = roomName.toLowerCase();
  for (const [key, icon] of Object.entries(ROOM_ICONS)) {
    if (lower.includes(key.toLowerCase())) return icon;
  }
  return '\u{1F3E0}';
}

function StatusChip({ wsConnected, processorConnected }: { wsConnected: boolean; processorConnected: boolean }) {
  const connected = wsConnected && processorConnected;
  const color = connected ? 'success' : wsConnected ? 'warning' : 'error';
  const label = connected ? 'Connected' : wsConnected ? 'Server only' : 'Disconnected';

  return (
    <Chip
      icon={<FiberManualRecordIcon sx={{ fontSize: 10, '&&': { color: `${color}.main` } }} />}
      label={label}
      size="small"
      variant="outlined"
      sx={{
        borderColor: 'rgba(255,255,255,0.15)',
        color: 'text.secondary',
        '& .MuiChip-icon': { ml: 0.5 },
      }}
    />
  );
}

// Small pill for "Lights On" section: brightness fill, tap-to-off, drag-to-dim
function LightOnPill({ device, displayName, onTurnOff, onSetLevel }: {
  device: { integrationId: number; level: number; name: string };
  displayName: string;
  onTurnOff: () => void;
  onSetLevel: (v: number) => void;
}) {
  const [localLevel, setLocalLevel] = useState(device.level);
  const pillRef = useRef<HTMLDivElement>(null);
  const isDragging = useRef(false);
  const pointerDownX = useRef<number | null>(null);
  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    if (!isDragging.current) setLocalLevel(device.level);
  }, [device.level]);

  const handlePointerDown = (e: React.PointerEvent) => {
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
    debounceRef.current = setTimeout(() => onSetLevel(snapped), 50);
  };

  const handlePointerUp = (e: React.PointerEvent) => {
    if (isDragging.current) {
      const rect = pillRef.current?.getBoundingClientRect();
      if (rect) {
        const pct = Math.max(1, Math.min(100, ((e.clientX - rect.left) / rect.width) * 100));
        onSetLevel(Math.round(pct / 5) * 5);
      }
    } else if (pointerDownX.current !== null) {
      onTurnOff();
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
        height: 36,
        borderRadius: 1.5,
        overflow: 'hidden',
        border: '1px solid rgba(245,166,35,0.25)',
        cursor: 'pointer',
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
      <Box sx={{ position: 'relative', display: 'flex', alignItems: 'center', height: '100%', px: 1, gap: 0.75 }}>
        <LightbulbIcon sx={{ fontSize: 11, color: 'primary.main', flexShrink: 0 }} />
        <Typography variant="body2" sx={{ flex: 1, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', fontSize: 11, fontWeight: 500, color: 'primary.main' }}>
          {displayName}
        </Typography>
        <Typography variant="caption" sx={{ fontSize: 10, fontWeight: 600, color: 'rgba(245,166,35,0.7)', fontVariantNumeric: 'tabular-nums', flexShrink: 0 }}>
          {Math.round(localLevel)}%
        </Typography>
      </Box>
    </Box>
  );
}

// Quick action button definitions
const QUICK_ACTIONS = [
  { id: 'main-off', label: 'Main Floor All Off', icon: <PowerOffIcon /> },
  { id: 'upstairs-off', label: 'Upstairs All Off', icon: <PowerOffIcon /> },
  { id: 'shades-down', label: 'Family & Dining Shades Down', icon: <BlindsClosedIcon /> },
  { id: 'evening', label: 'Evening', icon: <NightlightIcon /> },
];

export function Dashboard({ onSetup }: { onSetup?: () => void }) {
  const { devices, connectionStatus, processorConnected, setLevel, trackDevice, trackScene: trackSceneAction, getUsageEvents, doors, myqConnected, triggerGarage, dishwashers, laundry, heatPumps } = useLutron();
  const { devices, connectionStatus, processorConnected, setLevel, trackDevice, trackScene: trackSceneAction, getUsageEvents, doors, myqConnected, triggerGarage, panels, alarmConnected } = useLutron();
  const [selectedRoom, setSelectedRoom] = useState<string | null>(null);
  const { scenes, createScene, updateScene, deleteScene, activateScene, captureCurrentState } = useScenes();
  const [editorOpen, setEditorOpen] = useState(false);
  const [editingScene, setEditingScene] = useState<Scene | null>(null);
  const [settingsOpen, setSettingsOpen] = useState(false);

  const rooms = useMemo(() => {
    const map = new Map<string, typeof deviceList>();
    const deviceList = Array.from(devices.values());
    for (const device of deviceList) {
      const list = map.get(device.room) || [];
      list.push(device);
      map.set(device.room, list);
    }
    return map;
  }, [devices]);

  const usageEvents = useMemo(() => getUsageEvents(), [getUsageEvents]);
  const { sortedRoomNames, suggestedActions, dynamicQuickActions } = useAdaptiveDashboard(usageEvents, rooms, scenes);
  const detectedPatterns = usePatternDetector(usageEvents);
  const [dismissedPatterns, setDismissedPatterns] = useState<Set<string>>(new Set());
  const visiblePatterns = detectedPatterns.filter((p) => !dismissedPatterns.has(p.hash));

  // Get all lights that are currently on, grouped by room
  const lightsOn = useMemo(() => {
    return Array.from(devices.values())
      .filter((d) => d.type === 'light' && d.level > 0)
      .sort((a, b) => a.room.localeCompare(b.room) || a.name.localeCompare(b.name));
  }, [devices]);

  const lightsOnByRoom = useMemo(() => {
    const map = new Map<string, typeof lightsOn>();
    for (const d of lightsOn) {
      const list = map.get(d.room) ?? [];
      list.push(d);
      map.set(d.room, list);
    }
    return map;
  }, [lightsOn]);

  const handleQuickAction = useCallback(async (actionId: string) => {
    // Find the matching scene
    const scene = scenes.find((s) => {
      const normalName = s.name.toLowerCase().replace(/[^a-z0-9]/g, '');
      if (actionId === 'main-off' && normalName.includes('mainfloor')) return true;
      if (actionId === 'upstairs-off' && normalName.includes('upstairs')) return true;
      if (actionId === 'shades-down' && normalName.includes('shade')) return true;
      if (actionId === 'evening' && normalName.includes('evening')) return true;
      return false;
    });
    if (scene) {
      await activateScene(scene.id);
      trackSceneAction(scene.id, scene.name);
    }
  }, [scenes, activateScene, trackSceneAction]);

  const handleTurnOff = useCallback((integrationId: number) => {
    setLevel(integrationId, 0, 1);
    const device = devices.get(integrationId);
    trackDevice(integrationId, 'turnOff', device?.room);
  }, [setLevel, devices, trackDevice]);

  const handleNewScene = useCallback(() => {
    setEditingScene(null);
    setEditorOpen(true);
  }, []);

  const handleSaveScene = useCallback(async (data: { name: string; icon: string; targets: Scene['targets'] }) => {
    if (editingScene) {
      await updateScene(editingScene.id, data);
    } else {
      await createScene(data);
    }
    setEditorOpen(false);
    setEditingScene(null);
  }, [editingScene, updateScene, createScene]);

  // Room detail view
  if (selectedRoom) {
    const roomDevices = rooms.get(selectedRoom) || [];
    return (
      <Box sx={{ minHeight: '100vh' }}>
        <AppBar position="sticky" elevation={0} sx={{ bgcolor: 'rgba(18,18,18,0.85)', backdropFilter: 'blur(16px)', borderBottom: '1px solid rgba(255,255,255,0.06)' }}>
          <Toolbar>
            <IconButton edge="start" color="primary" onClick={() => setSelectedRoom(null)} sx={{ mr: 1 }}>
              <ArrowBackIcon />
            </IconButton>
            <Typography variant="h6" sx={{ flexGrow: 1 }}>
              {getRoomIcon(selectedRoom)} {selectedRoom}
            </Typography>
            <StatusChip wsConnected={connectionStatus === 'connected'} processorConnected={processorConnected} />
            <Tooltip title="Settings">
              <IconButton color="inherit" onClick={() => setSettingsOpen(true)} sx={{ ml: 1, color: 'text.secondary' }}>
                <SettingsIcon fontSize="small" />
              </IconButton>
            </Tooltip>
          </Toolbar>
        </AppBar>
        <RoomDetail devices={roomDevices} />
        <SettingsDialog open={settingsOpen} onClose={() => setSettingsOpen(false)} onSetup={onSetup} />
      </Box>
    );
  }

  // Dashboard view
  return (
    <Box sx={{ minHeight: '100vh' }}>
      <AppBar position="sticky" elevation={0} sx={{ bgcolor: 'rgba(18,18,18,0.85)', backdropFilter: 'blur(16px)', borderBottom: '1px solid rgba(255,255,255,0.06)' }}>
        <Toolbar>
          <Typography variant="h6" sx={{ flexGrow: 1 }}>
            Lutron Home
          </Typography>
          <StatusChip wsConnected={connectionStatus === 'connected'} processorConnected={processorConnected} />
          <Tooltip title="Settings">
            <IconButton color="inherit" onClick={() => setSettingsOpen(true)} sx={{ ml: 1, color: 'text.secondary' }}>
              <SettingsIcon fontSize="small" />
            </IconButton>
          </Tooltip>
        </Toolbar>
      </AppBar>

      <Box sx={{ px: { xs: 2, sm: 3 }, py: 2.5, maxWidth: 1200, mx: 'auto' }}>
        {/* For You — personalized suggestions based on usage patterns */}
        {suggestedActions.length > 0 && (
          <>
            <Box sx={{ display: 'flex', alignItems: 'center', gap: 1, mb: 1.5 }}>
              <AutoAwesomeIcon sx={{ fontSize: 16, color: 'primary.main' }} />
              <Typography variant="subtitle2" color="text.secondary">
                For You
              </Typography>
            </Box>
            <Grid container spacing={1.5} sx={{ mb: 3 }}>
              {suggestedActions.map((action) => (
                <Grid size={{ xs: 6, sm: 3 }} key={`${action.type}-${action.id}`}>
                  <Button
                    fullWidth
                    variant="outlined"
                    startIcon={action.type === 'scene' ? <PlayArrowIcon /> : <LightbulbIcon />}
                    onClick={() => {
                      if (action.type === 'scene') {
                        activateScene(String(action.id));
                        trackSceneAction(String(action.id));
                      } else {
                        const dev = devices.get(action.id as number);
                        if (dev) {
                          setLevel(dev.integrationId, dev.level > 0 ? 0 : 100, 1);
                          trackDevice(dev.integrationId, dev.level > 0 ? 'turnOff' : 'setLevel', dev.room);
                        }
                      }
                    }}
                    sx={{
                      py: 1.5,
                      px: 2,
                      borderColor: 'rgba(245,166,35,0.2)',
                      color: 'text.primary',
                      bgcolor: 'rgba(245,166,35,0.04)',
                      borderRadius: 2,
                      textAlign: 'left',
                      justifyContent: 'flex-start',
                      fontSize: 13,
                      fontWeight: 600,
                      lineHeight: 1.3,
                      whiteSpace: 'normal',
                      '&:hover': {
                        bgcolor: 'rgba(245,166,35,0.1)',
                        borderColor: 'primary.main',
                        transform: 'translateY(-1px)',
                        boxShadow: '0 4px 12px rgba(245,166,35,0.15)',
                      },
                      transition: 'all 0.2s ease',
                    }}
                  >
                    {action.label}
                  </Button>
                </Grid>
              ))}
            </Grid>
          </>
        )}

        {/* Scene Suggestions from detected patterns */}
        {visiblePatterns.slice(0, 2).map((pattern) => (
          <SceneSuggestion
            key={pattern.hash}
            pattern={pattern}
            devices={devices}
            onCreateScene={(targets) => {
              // Pre-fill scene editor with detected pattern
              setEditingScene(null);
              setEditorOpen(true);
              // The SceneEditor will receive these as initial targets
              createScene({ name: '', icon: '', targets }).catch(() => {});
            }}
            onDismiss={(hash) => setDismissedPatterns((prev) => new Set([...prev, hash]))}
          />
        ))}

        {/* Quick Actions */}
        <Typography variant="subtitle2" color="text.secondary" sx={{ mb: 1.5 }}>
          Quick Actions
        </Typography>
        <Grid container spacing={1.5} sx={{ mb: 4 }}>
          {(dynamicQuickActions || QUICK_ACTIONS).map((action) => (
            <Grid size={{ xs: 6, sm: 3 }} key={action.id}>
              <Button
                fullWidth
                variant="outlined"
                startIcon={dynamicQuickActions ? <PlayArrowIcon /> : (action as typeof QUICK_ACTIONS[0]).icon}
                onClick={() => {
                  if (dynamicQuickActions) {
                    activateScene(action.id);
                    trackSceneAction(action.id);
                  } else {
                    handleQuickAction(action.id);
                  }
                }}
                sx={{
                  py: 2,
                  px: 2,
                  borderColor: 'rgba(255,255,255,0.12)',
                  color: 'text.primary',
                  bgcolor: 'background.paper',
                  borderRadius: 2,
                  textAlign: 'left',
                  justifyContent: 'flex-start',
                  fontSize: 13,
                  fontWeight: 600,
                  lineHeight: 1.3,
                  whiteSpace: 'normal',
                  '&:hover': {
                    bgcolor: 'rgba(255,255,255,0.06)',
                    borderColor: 'primary.main',
                    transform: 'translateY(-1px)',
                    boxShadow: '0 4px 12px rgba(0,0,0,0.3)',
                  },
                  transition: 'all 0.2s ease',
                }}
              >
                {action.label}
              </Button>
            </Grid>
          ))}
        </Grid>

        {/* Lights Currently On */}
        <Box sx={{ display: 'flex', alignItems: 'center', gap: 1, mb: 1.5 }}>
          <Typography variant="subtitle2" color="text.secondary">
            Lights On
          </Typography>
          <Chip
            label={lightsOn.length}
            size="small"
            sx={{
              height: 20,
              fontSize: 11,
              fontWeight: 700,
              bgcolor: lightsOn.length > 0 ? 'rgba(245,166,35,0.15)' : 'rgba(255,255,255,0.08)',
              color: lightsOn.length > 0 ? 'primary.main' : 'text.secondary',
            }}
          />
        </Box>

        {lightsOn.length === 0 ? (
          <Paper
            sx={{
              p: 4,
              textAlign: 'center',
              bgcolor: 'background.paper',
              border: '1px solid rgba(255,255,255,0.06)',
            }}
          >
            <Typography color="text.secondary" variant="body2">
              All lights are off
            </Typography>
          </Paper>
        ) : (
          <Box sx={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
            {Array.from(lightsOnByRoom.entries()).map(([room, roomLights]) => {
              const stripRoomPrefix = (name: string) => {
                if (name.toLowerCase().startsWith(room.toLowerCase())) {
                  const stripped = name.slice(room.length).trimStart();
                  if (stripped) return stripped;
                }
                return name;
              };
              return (
                <Box key={room}>
                  <Box sx={{ display: 'flex', alignItems: 'center', gap: 1, mb: 0.75 }}>
                    <Typography variant="caption" sx={{ fontWeight: 600, color: 'text.secondary', textTransform: 'uppercase', letterSpacing: '0.08em', fontSize: 10 }}>
                      {getRoomIcon(room)} {room}
                    </Typography>
                    <Chip
                      label={roomLights.length}
                      size="small"
                      sx={{ height: 16, fontSize: 10, fontWeight: 700, bgcolor: 'rgba(245,166,35,0.15)', color: 'primary.main', '& .MuiChip-label': { px: 0.75 } }}
                    />
                  </Box>
                  <Box sx={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 0.75 }}>
                    {roomLights.map((device) => (
                      <LightOnPill
                        key={device.integrationId}
                        device={device}
                        displayName={stripRoomPrefix(device.name)}
                        onTurnOff={() => handleTurnOff(device.integrationId)}
                        onSetLevel={(v) => setLevel(device.integrationId, v)}
                      />
                    ))}
                  </Box>
                </Box>
              );
            })}
          </Box>
        )}

        {/* Garage */}
        {doors.size > 0 && (
          <>
            <Box sx={{ display: 'flex', alignItems: 'center', gap: 1, mt: 4, mb: 1.5 }}>
              <Typography variant="subtitle2" color="text.secondary">Garage</Typography>
              {!myqConnected && (
                <Chip label="offline" size="small" sx={{ height: 18, fontSize: 10, color: 'error.main', borderColor: 'error.main' }} variant="outlined" />
              )}
            </Box>
            <Box sx={{ display: 'flex', flexDirection: 'column', gap: 1 }}>
              {Array.from(doors.values()).map((door) => (
                <GarageDoorControl
                  key={door.serial}
                  door={door}
                  onAction={triggerGarage}
                  disabled={!myqConnected}
                />
              ))}
            </Box>
          </>
        )}

        {/* Appliances — dishwasher, laundry, heat pump */}
        <AppliancesSection dishwashers={dishwashers} laundry={laundry} heatPumps={heatPumps} />
        {/* Alarm */}
        {(alarmConnected || panels.size > 0) && (
          <>
            <Box sx={{ display: 'flex', alignItems: 'center', gap: 1, mt: 4, mb: 1.5 }}>
              <Typography variant="subtitle2" color="text.secondary">Security</Typography>
              {!alarmConnected && (
                <Chip label="offline" size="small" sx={{ height: 18, fontSize: 10, color: 'error.main', borderColor: 'error.main' }} variant="outlined" />
              )}
            </Box>
            <AlarmControl />
          </>
        )}

        {/* Rooms */}
        <Typography variant="subtitle2" color="text.secondary" sx={{ mt: 4, mb: 1.5 }}>
          Rooms
        </Typography>
        <Grid container spacing={1.5}>
          {sortedRoomNames.filter((room) => rooms.has(room)).map((room) => {
            const roomDevices = rooms.get(room)!;
            const roomLightsOn = roomDevices.filter((d) => d.type === 'light' && d.level > 0).length;
            const totalLights = roomDevices.filter((d) => d.type === 'light').length;
            const shades = roomDevices.filter((d) => d.type === 'shade');
            const avgShade = shades.length > 0
              ? Math.round(shades.reduce((sum, d) => sum + d.level, 0) / shades.length)
              : null;
            const lightRatio = totalLights > 0 ? (roomLightsOn / totalLights) * 100 : 0;
            const isActive = roomLightsOn > 0;

            return (
              <Grid size={{ xs: 6, sm: 4, md: 3 }} key={room}>
                <Card
                  sx={{
                    height: '100%',
                    ...(isActive && {
                      borderColor: 'rgba(245,166,35,0.3)',
                      boxShadow: '0 4px 20px rgba(245,166,35,0.12)',
                      background: 'linear-gradient(135deg, rgba(245,166,35,0.06) 0%, #1e1e1e 60%)',
                    }),
                    '&:hover': {
                      transform: 'translateY(-2px)',
                      boxShadow: '0 4px 16px rgba(0,0,0,0.4)',
                      borderColor: 'rgba(255,255,255,0.15)',
                    },
                  }}
                >
                  <CardActionArea
                    onClick={() => setSelectedRoom(room)}
                    sx={{ height: '100%', p: 2, display: 'flex', flexDirection: 'column', alignItems: 'flex-start', justifyContent: 'flex-start' }}
                  >
                    <Typography fontSize={24} lineHeight={1} mb={1}>{getRoomIcon(room)}</Typography>
                    <Typography variant="subtitle1" fontWeight={700} lineHeight={1.2} mb={0.5}>
                      {room}
                    </Typography>
                    <Box sx={{ color: 'text.secondary', fontSize: 12, mb: 0.5 }}>
                      {totalLights > 0 && <div>{roomLightsOn}/{totalLights} lights on</div>}
                      {avgShade !== null && <div>Shades {avgShade}%</div>}
                    </Box>
                    <Typography variant="caption" color="text.secondary">
                      {roomDevices.length} device{roomDevices.length !== 1 ? 's' : ''}
                    </Typography>
                    {totalLights > 0 && (
                      <LinearProgress
                        variant="determinate"
                        value={lightRatio}
                        sx={{
                          width: '100%',
                          mt: 1.5,
                          height: 3,
                          borderRadius: 2,
                          bgcolor: 'rgba(255,255,255,0.06)',
                          '& .MuiLinearProgress-bar': { bgcolor: 'primary.main', borderRadius: 2 },
                        }}
                      />
                    )}
                  </CardActionArea>
                </Card>
              </Grid>
            );
          })}
        </Grid>
      </Box>

      {editorOpen && (
        <SceneEditor
          scene={editingScene}
          rooms={rooms}
          onSave={handleSaveScene}
          onClose={() => { setEditorOpen(false); setEditingScene(null); }}
          onCapture={captureCurrentState}
        />
      )}
      <SettingsDialog
        open={settingsOpen}
        onClose={() => setSettingsOpen(false)}
        onSetup={onSetup}
      />
      <ChatPanel />
    </Box>
  );
}
