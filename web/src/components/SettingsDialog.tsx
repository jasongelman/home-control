import { useState, useMemo } from 'react';
import {
  Dialog, DialogTitle, DialogContent, Tabs, Tab, Box, Typography,
  LinearProgress, Chip, IconButton, Button, Paper, TextField, Switch, FormControlLabel, Alert,
} from '@mui/material';
import CloseIcon from '@mui/icons-material/Close';
import AutoAwesomeIcon from '@mui/icons-material/AutoAwesome';
import GarageIcon from '@mui/icons-material/Garage';
import LocalLaundryServiceIcon from '@mui/icons-material/LocalLaundryService';
import AcUnitIcon from '@mui/icons-material/AcUnit';
import ChatBubbleOutlineIcon from '@mui/icons-material/ChatBubbleOutline';
import VisibilityIcon from '@mui/icons-material/Visibility';
import VisibilityOffIcon from '@mui/icons-material/VisibilityOff';
import SecurityIcon from '@mui/icons-material/Security';
import { useLutron } from '../context/LutronContext.js';
import { useScenes } from '../hooks/useScenes.js';
import { useAdaptiveDashboard } from '../hooks/useAdaptiveDashboard.js';
import { usePatternDetector } from '../hooks/usePatternDetector.js';
import {
  getTopDevices,
  getTopScenes,
  getRecentActions,
  getRoomScoresForBucket,
  getTimeBucket,
  type UsageEvent,
  type TimeBucket,
} from '../hooks/useUsageTracker.js';
import type { DeviceState } from '../types/index.js';

// ── Constants ────────────────────────────────────────────────────────────────

const TIME_BUCKETS: TimeBucket[] = ['morning', 'afternoon', 'evening', 'night'];

const BUCKET_LABELS: Record<TimeBucket, string> = {
  morning: '🌅 Morning (5–12)',
  afternoon: '☀️ Afternoon (12–6)',
  evening: '🌆 Evening (6pm–2am)',
  night: '🌙 Night (2–5)',
};

const BUCKET_COLORS: Record<TimeBucket, string> = {
  morning: 'rgba(255,200,80,0.85)',
  afternoon: 'rgba(255,140,40,0.85)',
  evening: 'rgba(160,90,255,0.85)',
  night: 'rgba(70,110,255,0.85)',
};

const BUCKET_BAR_COLORS: Record<TimeBucket, string> = {
  morning: 'rgba(255,200,80,0.7)',
  afternoon: 'rgba(255,140,40,0.7)',
  evening: 'rgba(160,90,255,0.7)',
  night: 'rgba(70,110,255,0.7)',
};

// ── Small reusable pieces ────────────────────────────────────────────────────

function StatCard({ label, value }: { label: string; value: string | number }) {
  return (
    <Paper sx={{
      p: 1.5, flex: 1, minWidth: 90, textAlign: 'center',
      bgcolor: 'rgba(255,255,255,0.04)', border: '1px solid rgba(255,255,255,0.06)',
    }}>
      <Typography variant="h5" fontWeight={700} color="primary.main" lineHeight={1.2}>{value}</Typography>
      <Typography variant="caption" color="text.secondary" sx={{ fontSize: 11 }}>{label}</Typography>
    </Paper>
  );
}

function SectionTitle({ children }: { children: React.ReactNode }) {
  return (
    <Typography
      variant="caption"
      color="text.disabled"
      sx={{ display: 'block', mt: 3, mb: 1.25, textTransform: 'uppercase', letterSpacing: 1.2, fontWeight: 700 }}
    >
      {children}
    </Typography>
  );
}

function BarRow({
  label, value, max, color, badge,
}: {
  label: string; value: number; max: number; color?: string; badge?: string;
}) {
  const pct = max > 0 ? Math.max(2, (value / max) * 100) : 0;
  return (
    <Box sx={{ mb: 1.25 }}>
      <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', mb: 0.35 }}>
        <Typography variant="body2" fontWeight={500} noWrap sx={{ maxWidth: '70%' }}>{label}</Typography>
        <Box sx={{ display: 'flex', alignItems: 'center', gap: 0.5 }}>
          {badge && (
            <Chip label={badge} size="small" sx={{ height: 16, fontSize: 9, fontWeight: 700, bgcolor: 'rgba(245,166,35,0.15)', color: 'primary.main', px: 0 }} />
          )}
          <Typography variant="caption" color="text.secondary" fontWeight={600}>{value}×</Typography>
        </Box>
      </Box>
      <LinearProgress
        variant="determinate"
        value={pct}
        sx={{
          height: 5, borderRadius: 3,
          bgcolor: 'rgba(255,255,255,0.06)',
          '& .MuiLinearProgress-bar': { bgcolor: color || 'primary.main', borderRadius: 3 },
        }}
      />
    </Box>
  );
}

// ── Personalization tab ──────────────────────────────────────────────────────

interface PersonalizationInsightsProps {
  events: UsageEvent[];
  devices: Map<number, DeviceState>;
  scenes: { id: string; name: string }[];
  rooms: Map<string, DeviceState[]>;
}

function PersonalizationInsights({ events, devices, scenes, rooms }: PersonalizationInsightsProps) {
  const currentBucket = getTimeBucket();
  const { suggestedActions, dynamicQuickActions } = useAdaptiveDashboard(events, rooms, scenes);
  const patterns = usePatternDetector(events);

  // Overview stats
  const totalEvents = events.length;
  const deviceEvents = events.filter((e) => e.type === 'device').length;
  const sceneEvents = events.filter((e) => e.type === 'scene').length;
  const daysTracked = totalEvents > 0
    ? Math.max(1, Math.ceil((Date.now() - events[0].timestamp) / (24 * 60 * 60 * 1000)))
    : 0;

  // Top devices / scenes
  const topDevices = getTopDevices(events, 10);
  const maxDeviceCount = topDevices[0]?.count || 1;
  const topScenes = getTopScenes(events, 8);
  const maxSceneCount = topScenes[0]?.count || 1;

  // Time-of-day distribution
  const bucketCounts = useMemo(() => {
    const counts: Record<TimeBucket, number> = { morning: 0, afternoon: 0, evening: 0, night: 0 };
    for (const e of events) {
      counts[getTimeBucket(new Date(e.timestamp))]++;
    }
    return counts;
  }, [events]);
  const maxBucketCount = Math.max(...Object.values(bucketCounts), 1);

  // Room × time heatmap data
  const roomBucketScores = useMemo(() => ({
    morning: getRoomScoresForBucket(events, 'morning'),
    afternoon: getRoomScoresForBucket(events, 'afternoon'),
    evening: getRoomScoresForBucket(events, 'evening'),
    night: getRoomScoresForBucket(events, 'night'),
  }), [events]);

  const activeRooms = useMemo(() => {
    const set = new Set<string>();
    for (const e of events) { if (e.room) set.add(e.room); }
    return Array.from(set).sort();
  }, [events]);

  const maxHeatmapVal = useMemo(() => {
    let max = 1;
    for (const b of TIME_BUCKETS) {
      for (const v of roomBucketScores[b].values()) { if (v > max) max = v; }
    }
    return max;
  }, [roomBucketScores]);

  // Recent activity
  const recentActivity = getRecentActions(events, 25);

  if (totalEvents === 0) {
    return (
      <Box sx={{ textAlign: 'center', py: 6 }}>
        <AutoAwesomeIcon sx={{ fontSize: 48, color: 'text.disabled', mb: 2 }} />
        <Typography color="text.secondary" gutterBottom>No usage data yet.</Typography>
        <Typography variant="caption" color="text.disabled">
          Use lights and scenes to build personalization data.
        </Typography>
      </Box>
    );
  }

  return (
    <Box>
      {/* Overview */}
      <Box sx={{ display: 'flex', gap: 1, flexWrap: 'wrap' }}>
        <StatCard label="Total Actions" value={totalEvents} />
        <StatCard label="Device Actions" value={deviceEvents} />
        <StatCard label="Scene Activations" value={sceneEvents} />
        <StatCard label="Days Tracked" value={daysTracked} />
      </Box>

      {/* Current bucket */}
      <Box sx={{ mt: 2, display: 'flex', alignItems: 'center', gap: 1 }}>
        <Typography variant="body2" color="text.secondary">Now:</Typography>
        <Chip
          label={BUCKET_LABELS[currentBucket]}
          size="small"
          sx={{ bgcolor: BUCKET_COLORS[currentBucket], color: '#111', fontWeight: 700, fontSize: 11 }}
        />
      </Box>

      {/* Time-of-day distribution */}
      <SectionTitle>Activity by Time of Day</SectionTitle>
      {TIME_BUCKETS.map((bucket) => (
        <BarRow
          key={bucket}
          label={BUCKET_LABELS[bucket]}
          value={bucketCounts[bucket]}
          max={maxBucketCount}
          color={BUCKET_BAR_COLORS[bucket]}
        />
      ))}

      {/* For You — current suggestions with scores */}
      <SectionTitle>For You — Current Suggestions</SectionTitle>
      {suggestedActions.length === 0 ? (
        <Typography variant="body2" color="text.secondary">
          Need at least 5 events to generate suggestions ({totalEvents}/5 so far).
        </Typography>
      ) : (
        suggestedActions.map((action, i) => (
          <Box key={`${action.type}-${action.id}`} sx={{ mb: 1.25, display: 'flex', alignItems: 'flex-start', gap: 1.5 }}>
            <Box sx={{
              width: 22, height: 22, borderRadius: '50%', flexShrink: 0, mt: 0.25,
              bgcolor: 'rgba(245,166,35,0.15)', display: 'flex', alignItems: 'center',
              justifyContent: 'center', fontSize: 10, fontWeight: 700, color: 'primary.main',
            }}>
              {i + 1}
            </Box>
            <Box sx={{ flex: 1, minWidth: 0 }}>
              <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', mb: 0.35 }}>
                <Typography variant="body2" fontWeight={600} noWrap sx={{ maxWidth: '60%' }}>{action.label}</Typography>
                <Box sx={{ display: 'flex', gap: 0.5 }}>
                  <Chip label={action.type} size="small" sx={{ height: 16, fontSize: 9 }} />
                  <Chip
                    label={`${action.score}×`}
                    size="small"
                    sx={{ height: 16, fontSize: 9, fontWeight: 700, bgcolor: 'rgba(245,166,35,0.15)', color: 'primary.main' }}
                  />
                </Box>
              </Box>
              <LinearProgress
                variant="determinate"
                value={Math.max(4, (action.score / (suggestedActions[0]?.score || 1)) * 100)}
                sx={{
                  height: 4, borderRadius: 2,
                  bgcolor: 'rgba(255,255,255,0.06)',
                  '& .MuiLinearProgress-bar': { bgcolor: 'rgba(245,166,35,0.55)', borderRadius: 2 },
                }}
              />
            </Box>
          </Box>
        ))
      )}

      {/* Quick Actions status */}
      <SectionTitle>Quick Actions</SectionTitle>
      {dynamicQuickActions ? (
        <>
          <Typography variant="caption" color="success.main" sx={{ mb: 1.25, display: 'block' }}>
            ✓ Personalized — using your most-used scenes
          </Typography>
          {dynamicQuickActions.map((a) => (
            <BarRow
              key={a.id}
              label={a.label}
              value={a.count}
              max={dynamicQuickActions[0].count}
              color="rgba(80,200,120,0.7)"
            />
          ))}
        </>
      ) : (
        <Typography variant="body2" color="text.secondary">
          Using defaults — need 10+ events to personalize ({totalEvents}/10 so far).
        </Typography>
      )}

      {/* Top Devices */}
      <SectionTitle>Most Used Devices (All Time)</SectionTitle>
      {topDevices.length === 0 ? (
        <Typography variant="body2" color="text.secondary">No device data yet.</Typography>
      ) : (
        topDevices.map((d) => {
          const dev = devices.get(d.id as number);
          const label = dev ? `${dev.name}` : `Device ${d.id}`;
          const sub = dev?.room || d.room;
          return (
            <BarRow
              key={String(d.id)}
              label={label}
              value={d.count}
              max={maxDeviceCount}
              badge={sub}
            />
          );
        })
      )}

      {/* Top Scenes */}
      {topScenes.length > 0 && (
        <>
          <SectionTitle>Most Activated Scenes</SectionTitle>
          {topScenes.map((s) => {
            const scene = scenes.find((sc) => sc.id === s.id);
            return (
              <BarRow
                key={s.id}
                label={scene?.name || `Scene ${s.id.slice(0, 8)}`}
                value={s.count}
                max={maxSceneCount}
                color="rgba(160,90,255,0.7)"
              />
            );
          })}
        </>
      )}

      {/* Room × Time Heatmap */}
      {activeRooms.length > 0 && (
        <>
          <SectionTitle>Room Usage Heatmap</SectionTitle>
          <Box sx={{ overflowX: 'auto', pb: 0.5 }}>
            <Box sx={{ minWidth: 340 }}>
              {/* Column headers */}
              <Box sx={{ display: 'grid', gridTemplateColumns: '110px repeat(4, 1fr)', gap: 0.5, mb: 0.75 }}>
                <Box />
                {TIME_BUCKETS.map((b) => (
                  <Typography key={b} variant="caption" color="text.disabled" sx={{ textAlign: 'center', fontSize: 10, fontWeight: 600 }}>
                    {b === 'morning' ? '🌅' : b === 'afternoon' ? '☀️' : b === 'evening' ? '🌆' : '🌙'}
                    <br />{b}
                  </Typography>
                ))}
              </Box>
              {/* Rows */}
              {activeRooms.map((room) => (
                <Box key={room} sx={{ display: 'grid', gridTemplateColumns: '110px repeat(4, 1fr)', gap: 0.5, mb: 0.5, alignItems: 'center' }}>
                  <Typography variant="caption" fontWeight={500} noWrap sx={{ pr: 0.5 }}>{room}</Typography>
                  {TIME_BUCKETS.map((b) => {
                    const val = roomBucketScores[b].get(room) || 0;
                    const intensity = val / maxHeatmapVal;
                    return (
                      <Box
                        key={b}
                        title={`${room} · ${b}: ${val} actions`}
                        sx={{
                          height: 26, borderRadius: 1,
                          bgcolor: intensity > 0
                            ? `rgba(245,166,35,${0.08 + intensity * 0.72})`
                            : 'rgba(255,255,255,0.04)',
                          display: 'flex', alignItems: 'center', justifyContent: 'center',
                        }}
                      >
                        {val > 0 && (
                          <Typography sx={{ fontSize: 10, fontWeight: 700, color: intensity > 0.55 ? '#1a1000' : 'primary.main' }}>
                            {val}
                          </Typography>
                        )}
                      </Box>
                    );
                  })}
                </Box>
              ))}
            </Box>
          </Box>
        </>
      )}

      {/* Detected Patterns */}
      {patterns.length > 0 && (
        <>
          <SectionTitle>Detected Patterns ({patterns.length})</SectionTitle>
          {patterns.map((p) => (
            <Paper
              key={p.hash}
              sx={{ p: 1.5, mb: 1, bgcolor: 'rgba(255,255,255,0.03)', border: '1px solid rgba(255,255,255,0.07)' }}
            >
              <Box sx={{ display: 'flex', alignItems: 'center', gap: 1, mb: 0.75 }}>
                {p.timeOfDay && (
                  <Chip label={p.timeOfDay} size="small" sx={{ height: 18, fontSize: 10 }} />
                )}
                <Typography variant="caption" color="text.secondary">
                  observed {p.frequency}×
                </Typography>
              </Box>
              <Box sx={{ display: 'flex', flexWrap: 'wrap', gap: 0.5 }}>
                {p.devices.map((d) => {
                  const dev = devices.get(d.id);
                  const label = dev
                    ? `${dev.name}${d.avgLevel > 0 ? ` ${d.avgLevel}%` : ''}`
                    : `Device ${d.id}${d.avgLevel > 0 ? ` ${d.avgLevel}%` : ''}`;
                  return (
                    <Chip key={d.id} label={label} size="small" sx={{ height: 20, fontSize: 10 }} />
                  );
                })}
              </Box>
            </Paper>
          ))}
        </>
      )}

      {/* Recent Activity */}
      <SectionTitle>Recent Activity</SectionTitle>
      <Box sx={{ maxHeight: 260, overflowY: 'auto', pr: 0.5 }}>
        {recentActivity.map((e, i) => {
          const ts = new Date(e.timestamp);
          const timeStr = ts.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
          const dateStr = ts.toLocaleDateString([], { month: 'short', day: 'numeric' });
          const dev = e.type === 'device' ? devices.get(e.id as number) : null;
          const scene = e.type === 'scene' ? scenes.find((s) => s.id === e.id) : null;
          const label = dev
            ? `${dev.name}${e.level !== undefined ? ` → ${e.level}%` : e.action === 'turnOff' ? ' off' : ''}`
            : scene
              ? scene.name
              : String(e.id);
          const room = dev?.room || e.room;
          return (
            <Box
              key={i}
              sx={{
                display: 'flex', gap: 1, py: 0.75, alignItems: 'flex-start',
                borderBottom: '1px solid rgba(255,255,255,0.04)',
                '&:last-child': { borderBottom: 'none' },
              }}
            >
              <Typography sx={{ fontSize: 14, lineHeight: 1.4, flexShrink: 0 }}>
                {e.type === 'scene' ? '🎬' : '💡'}
              </Typography>
              <Box sx={{ flex: 1, minWidth: 0 }}>
                <Typography variant="body2" fontWeight={500} noWrap>{label}</Typography>
                {room && <Typography variant="caption" color="text.secondary">{room}</Typography>}
              </Box>
              <Box sx={{ textAlign: 'right', flexShrink: 0 }}>
                <Typography variant="caption" color="text.secondary" display="block">{timeStr}</Typography>
                <Typography variant="caption" color="text.disabled" display="block" sx={{ fontSize: 10 }}>{dateStr}</Typography>
              </Box>
            </Box>
          );
        })}
      </Box>
    </Box>
  );
}

// ── Alarm / Total Connect settings tab ───────────────────────────────────────

function AlarmSettings() {
  const { panels, alarmConnected } = useLutron();
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [userCode, setUserCode] = useState('');
  const [enabled, setEnabled] = useState(false);
  const [loaded, setLoaded] = useState(false);
  const [saving, setSaving] = useState(false);
  const [saveOk, setSaveOk] = useState(false);
  const [saveError, setSaveError] = useState('');

  useMemo(() => {
    if (loaded) return;
    setLoaded(true);
    fetch('/api/alarm/config')
      .then((r) => r.json())
      .then((data: { username?: string; enabled?: boolean }) => {
        setUsername(data.username ?? '');
        setEnabled(data.enabled ?? false);
      })
      .catch(() => {});
  }, [loaded]);

  const save = async () => {
    setSaving(true); setSaveOk(false); setSaveError('');
    try {
      const body: Record<string, unknown> = { username, enabled };
      if (password) body.password = password;
      if (userCode) body.userCode = userCode;
      const res = await fetch('/api/alarm/config', {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      setSaveOk(true);
      setPassword('');
      setUserCode('');
      setTimeout(() => setSaveOk(false), 3000);
    } catch (err) {
      setSaveError(String(err));
    } finally {
      setSaving(false);
    }
  };

  return (
    <Box>
      {/* Status */}
      <Box sx={{ display: 'flex', alignItems: 'center', gap: 1.5, mb: 3 }}>
        <SecurityIcon sx={{ fontSize: 18, color: alarmConnected ? 'success.main' : 'text.disabled' }} />
        <Chip
          size="small"
          label={alarmConnected ? `Connected — ${panels.size} panel${panels.size !== 1 ? 's' : ''}` : 'Not connected'}
          color={alarmConnected ? 'success' : 'default'}
          variant="outlined"
        />
      </Box>

      <Typography variant="caption" color="text.disabled" sx={{ display: 'block', mb: 1.5, textTransform: 'uppercase', letterSpacing: 1 }}>
        Total Connect 2.0 Account
      </Typography>

      <FormControlLabel
        control={<Switch checked={enabled} onChange={(e) => setEnabled(e.target.checked)} size="small" />}
        label={<Typography variant="body2">Enable alarm integration</Typography>}
        sx={{ mb: 2, ml: 0 }}
      />

      <TextField
        label="Username"
        value={username}
        onChange={(e) => setUsername(e.target.value)}
        fullWidth
        size="small"
        sx={{ mb: 2 }}
        disabled={saving}
        autoComplete="off"
      />
      <TextField
        label="Password"
        type="password"
        value={password}
        onChange={(e) => setPassword(e.target.value)}
        fullWidth
        size="small"
        placeholder={alarmConnected ? '(saved — enter to change)' : ''}
        helperText="Leave blank to keep existing password"
        sx={{ mb: 2 }}
        disabled={saving}
      />
      <TextField
        label="User Code (PIN)"
        type="password"
        value={userCode}
        onChange={(e) => setUserCode(e.target.value)}
        fullWidth
        size="small"
        placeholder={alarmConnected ? '(saved — enter to change)' : ''}
        helperText="The numeric PIN used to arm/disarm your panel. Leave blank to keep existing."
        sx={{ mb: 2 }}
        disabled={saving}
        inputProps={{ inputMode: 'numeric', pattern: '[0-9]*' }}
      />

      {saveError && <Alert severity="error" sx={{ mb: 1.5, fontSize: 12 }}>{saveError}</Alert>}
      {saveOk && <Alert severity="success" sx={{ mb: 1.5, fontSize: 12 }}>Saved — alarm will connect shortly.</Alert>}

      <Button
        variant="contained"
        onClick={save}
        disabled={saving || !username}
        size="small"
      >
        {saving ? 'Saving…' : 'Save'}
      </Button>
    </Box>
  );
}

// ── Garage / MyQ settings tab ────────────────────────────────────────────────

function GarageSettings() {
  const { doors, myqConnected } = useLutron();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [enabled, setEnabled] = useState(false);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState('');
  const [saveOk, setSaveOk] = useState(false);
  const [loaded, setLoaded] = useState(false);

  // Load current config once on mount
  useMemo(() => {
    if (loaded) return;
    setLoaded(true);
    fetch('/api/myq/config')
      .then((r) => r.json())
      .then((data: { email?: string; enabled?: boolean }) => {
        setEmail(data.email ?? '');
        setEnabled(data.enabled ?? false);
      })
      .catch(() => {});
  }, [loaded]);

  const handleSave = async () => {
    setSaving(true);
    setSaveError('');
    setSaveOk(false);
    try {
      const body: Record<string, unknown> = { email, enabled };
      if (password) body.password = password; // only send if changed
      const res = await fetch('/api/myq/config', {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });
      if (!res.ok) throw new Error(`${res.status}`);
      setSaveOk(true);
      setPassword(''); // clear password field after save
    } catch (err) {
      setSaveError(String(err));
    } finally {
      setSaving(false);
    }
  };

  return (
    <Box>
      {/* Status */}
      <Box sx={{ display: 'flex', alignItems: 'center', gap: 1.5, mb: 3 }}>
        <GarageIcon sx={{ fontSize: 18, color: myqConnected ? 'success.main' : 'text.disabled' }} />
        <Chip
          size="small"
          label={myqConnected ? `Connected — ${doors.size} door${doors.size !== 1 ? 's' : ''}` : 'Not connected'}
          color={myqConnected ? 'success' : 'default'}
          variant="outlined"
        />
      </Box>

      {/* Doors list */}
      {doors.size > 0 && (
        <Box sx={{ mb: 3 }}>
          <Typography variant="caption" color="text.disabled" sx={{ display: 'block', mb: 1, textTransform: 'uppercase', letterSpacing: 1 }}>
            Discovered Doors
          </Typography>
          {Array.from(doors.values()).map((door) => (
            <Box key={door.serial} sx={{ display: 'flex', justifyContent: 'space-between', py: 0.75, borderBottom: '1px solid rgba(255,255,255,0.05)' }}>
              <Typography variant="body2">{door.name}</Typography>
              <Typography variant="caption" color="text.secondary" sx={{ textTransform: 'capitalize' }}>{door.state}</Typography>
            </Box>
          ))}
        </Box>
      )}

      {/* Credentials form */}
      <Typography variant="caption" color="text.disabled" sx={{ display: 'block', mb: 1.5, textTransform: 'uppercase', letterSpacing: 1 }}>
        MyQ Account
      </Typography>

      <FormControlLabel
        control={<Switch checked={enabled} onChange={(e) => setEnabled(e.target.checked)} size="small" />}
        label={<Typography variant="body2">Enable MyQ integration</Typography>}
        sx={{ mb: 2, ml: 0 }}
      />

      <TextField
        label="MyQ Email"
        value={email}
        onChange={(e) => setEmail(e.target.value)}
        fullWidth
        size="small"
        sx={{ mb: 1.5 }}
        disabled={saving}
      />
      <TextField
        label="Password"
        type="password"
        value={password}
        onChange={(e) => setPassword(e.target.value)}
        fullWidth
        size="small"
        placeholder={myqConnected ? '(saved — enter to change)' : ''}
        helperText="Leave blank to keep existing password"
        sx={{ mb: 2 }}
        disabled={saving}
      />

      {saveError && <Alert severity="error" sx={{ mb: 1.5, fontSize: 12 }}>{saveError}</Alert>}
      {saveOk && <Alert severity="success" sx={{ mb: 1.5, fontSize: 12 }}>Saved — MyQ will connect shortly.</Alert>}

      <Button
        variant="contained"
        onClick={handleSave}
        disabled={saving || !email}
        sx={{ textTransform: 'none' }}
      >
        {saving ? 'Saving…' : 'Save'}
      </Button>
    </Box>
  );
}

// ── HomeConnect settings tab ──────────────────────────────────────────────────

function HomeConnectSettings() {
  const { dishwashers, homeConnectLinked } = useLutron();
  const [clientId, setClientId] = useState('');
  const [clientSecret, setClientSecret] = useState('');
  const [loaded, setLoaded] = useState(false);
  const [saving, setSaving] = useState(false);
  const [saveOk, setSaveOk] = useState(false);
  const [saveError, setSaveError] = useState('');

  useMemo(() => {
    if (loaded) return;
    setLoaded(true);
    fetch('/api/homeconnect/config').then((r) => r.json()).then((d: { clientId?: string }) => {
      setClientId(d.clientId ?? '');
    }).catch(() => {});
  }, [loaded]);

  const handleSave = async () => {
    setSaving(true); setSaveOk(false); setSaveError('');
    try {
      const res = await fetch('/api/homeconnect/config', {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ clientId, clientSecret: clientSecret || undefined, enabled: true }),
      });
      if (!res.ok) throw new Error(`${res.status}`);
      setSaveOk(true);
      setClientSecret('');
    } catch (err) { setSaveError(String(err)); }
    finally { setSaving(false); }
  };

  return (
    <Box>
      <Box sx={{ display: 'flex', alignItems: 'center', gap: 1.5, mb: 3 }}>
        <Typography sx={{ fontSize: 20 }}>🍽️</Typography>
        <Chip size="small" label={homeConnectLinked ? `Linked — ${dishwashers.length} appliance${dishwashers.length !== 1 ? 's' : ''}` : 'Not linked'} color={homeConnectLinked ? 'success' : 'default'} variant="outlined" />
      </Box>

      {dishwashers.length > 0 && (
        <Box sx={{ mb: 3 }}>
          <Typography variant="caption" color="text.disabled" sx={{ display: 'block', mb: 1, textTransform: 'uppercase', letterSpacing: 1 }}>Appliances</Typography>
          {dishwashers.map((dw) => (
            <Box key={dw.applianceId} sx={{ display: 'flex', justifyContent: 'space-between', py: 0.75, borderBottom: '1px solid rgba(255,255,255,0.05)' }}>
              <Typography variant="body2">{dw.applianceName}</Typography>
              <Typography variant="caption" color="text.secondary">{dw.operationState}</Typography>
            </Box>
          ))}
        </Box>
      )}

      <Typography variant="caption" color="text.disabled" sx={{ display: 'block', mb: 1.5, textTransform: 'uppercase', letterSpacing: 1 }}>Home Connect OAuth2 App</Typography>
      <TextField label="Client ID" value={clientId} onChange={(e) => setClientId(e.target.value)} fullWidth size="small" sx={{ mb: 1.5 }} disabled={saving} />
      <TextField label="Client Secret" type="password" value={clientSecret} onChange={(e) => setClientSecret(e.target.value)} fullWidth size="small" placeholder={homeConnectLinked ? '(saved)' : ''} helperText="Leave blank to keep existing secret" sx={{ mb: 2 }} disabled={saving} />

      {saveError && <Alert severity="error" sx={{ mb: 1.5, fontSize: 12 }}>{saveError}</Alert>}
      {saveOk && <Alert severity="success" sx={{ mb: 1.5, fontSize: 12 }}>Saved. Click Link to authorize.</Alert>}

      <Box sx={{ display: 'flex', gap: 1, flexWrap: 'wrap' }}>
        <Button variant="contained" onClick={handleSave} disabled={saving || !clientId} sx={{ textTransform: 'none' }}>
          {saving ? 'Saving…' : 'Save'}
        </Button>
        {clientId && (
          <Button variant="outlined" onClick={() => window.open('/api/homeconnect/oauth/start', '_blank')} sx={{ textTransform: 'none' }}>
            Link Account
          </Button>
        )}
        {homeConnectLinked && (
          <Button variant="outlined" color="error" onClick={() => fetch('/api/homeconnect/unlink', { method: 'POST' })} sx={{ textTransform: 'none' }}>
            Unlink
          </Button>
        )}
      </Box>
    </Box>
  );
}

// ── SmartHQ settings tab ──────────────────────────────────────────────────────

function SmartHQSettings() {
  const { laundry, smartHQLinked } = useLutron();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [loaded, setLoaded] = useState(false);
  const [saving, setSaving] = useState(false);
  const [saveOk, setSaveOk] = useState(false);
  const [saveError, setSaveError] = useState('');

  useMemo(() => {
    if (loaded) return;
    setLoaded(true);
    fetch('/api/smarthq/config').then((r) => r.json()).then((d: { email?: string }) => {
      setEmail(d.email ?? '');
    }).catch(() => {});
  }, [loaded]);

  const handleSignIn = async () => {
    setSaving(true); setSaveOk(false); setSaveError('');
    try {
      const res = await fetch('/api/smarthq/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, password }),
      });
      if (!res.ok) throw new Error(`Login failed: ${res.status}`);
      setSaveOk(true);
      setPassword('');
    } catch (err) { setSaveError(String(err)); }
    finally { setSaving(false); }
  };

  return (
    <Box>
      <Box sx={{ display: 'flex', alignItems: 'center', gap: 1.5, mb: 3 }}>
        <LocalLaundryServiceIcon sx={{ fontSize: 18, color: smartHQLinked ? 'success.main' : 'text.disabled' }} />
        <Chip size="small" label={smartHQLinked ? `Linked — ${laundry.length} appliance${laundry.length !== 1 ? 's' : ''}` : 'Not linked'} color={smartHQLinked ? 'success' : 'default'} variant="outlined" />
      </Box>

      {laundry.length > 0 && (
        <Box sx={{ mb: 3 }}>
          <Typography variant="caption" color="text.disabled" sx={{ display: 'block', mb: 1, textTransform: 'uppercase', letterSpacing: 1 }}>Appliances</Typography>
          {laundry.map((a) => (
            <Box key={a.applianceId} sx={{ display: 'flex', justifyContent: 'space-between', py: 0.75, borderBottom: '1px solid rgba(255,255,255,0.05)' }}>
              <Typography variant="body2">{a.applianceName}</Typography>
              <Typography variant="caption" color="text.secondary">{a.machineState}</Typography>
            </Box>
          ))}
        </Box>
      )}

      <Typography variant="caption" color="text.disabled" sx={{ display: 'block', mb: 1.5, textTransform: 'uppercase', letterSpacing: 1 }}>GE SmartHQ Account</Typography>
      <TextField label="Email" value={email} onChange={(e) => setEmail(e.target.value)} fullWidth size="small" sx={{ mb: 1.5 }} disabled={saving} />
      <TextField label="Password" type="password" value={password} onChange={(e) => setPassword(e.target.value)} fullWidth size="small" placeholder={smartHQLinked ? '(enter to re-login)' : ''} sx={{ mb: 2 }} disabled={saving} />

      {saveError && <Alert severity="error" sx={{ mb: 1.5, fontSize: 12 }}>{saveError}</Alert>}
      {saveOk && <Alert severity="success" sx={{ mb: 1.5, fontSize: 12 }}>Signed in! Fetching appliances…</Alert>}

      <Box sx={{ display: 'flex', gap: 1 }}>
        <Button variant="contained" onClick={handleSignIn} disabled={saving || !email || !password} sx={{ textTransform: 'none' }}>
          {saving ? 'Signing in…' : 'Sign In'}
        </Button>
        {smartHQLinked && (
          <Button variant="outlined" color="error" onClick={() => fetch('/api/smarthq/unlink', { method: 'POST' })} sx={{ textTransform: 'none' }}>
            Unlink
          </Button>
        )}
      </Box>
    </Box>
  );
}

// ── myUplink settings tab ────────────────────────────────────────────────────

function MyUplinkSettings() {
  const { heatPumps, myUplinkLinked } = useLutron();
  const [clientId, setClientId] = useState('');
  const [clientSecret, setClientSecret] = useState('');
  const [loaded, setLoaded] = useState(false);
  const [saving, setSaving] = useState(false);
  const [saveOk, setSaveOk] = useState(false);
  const [saveError, setSaveError] = useState('');

  useMemo(() => {
    if (loaded) return;
    setLoaded(true);
    fetch('/api/myuplink/config').then((r) => r.json()).then((d: { clientId?: string }) => {
      setClientId(d.clientId ?? '');
    }).catch(() => {});
  }, [loaded]);

  const handleSave = async () => {
    setSaving(true); setSaveOk(false); setSaveError('');
    try {
      const res = await fetch('/api/myuplink/config', {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ clientId, clientSecret: clientSecret || undefined, enabled: true }),
      });
      if (!res.ok) throw new Error(`${res.status}`);
      setSaveOk(true);
      setClientSecret('');
    } catch (err) { setSaveError(String(err)); }
    finally { setSaving(false); }
  };

  return (
    <Box>
      <Box sx={{ display: 'flex', alignItems: 'center', gap: 1.5, mb: 3 }}>
        <AcUnitIcon sx={{ fontSize: 18, color: myUplinkLinked ? 'success.main' : 'text.disabled' }} />
        <Chip size="small" label={myUplinkLinked ? `Linked — ${heatPumps.length} device${heatPumps.length !== 1 ? 's' : ''}` : 'Not linked'} color={myUplinkLinked ? 'success' : 'default'} variant="outlined" />
      </Box>

      {heatPumps.length > 0 && (
        <Box sx={{ mb: 3 }}>
          <Typography variant="caption" color="text.disabled" sx={{ display: 'block', mb: 1, textTransform: 'uppercase', letterSpacing: 1 }}>Heat Pumps</Typography>
          {heatPumps.map((hp) => (
            <Box key={hp.deviceId} sx={{ display: 'flex', justifyContent: 'space-between', py: 0.75, borderBottom: '1px solid rgba(255,255,255,0.05)' }}>
              <Typography variant="body2">{hp.deviceName}</Typography>
              <Typography variant="caption" color="text.secondary">{hp.mode}{hp.outdoorTemp !== null ? ` · ${hp.outdoorTemp}°F` : ''}</Typography>
            </Box>
          ))}
        </Box>
      )}

      <Typography variant="caption" color="text.disabled" sx={{ display: 'block', mb: 1.5, textTransform: 'uppercase', letterSpacing: 1 }}>myUplink OAuth2 App</Typography>
      <TextField label="Client ID" value={clientId} onChange={(e) => setClientId(e.target.value)} fullWidth size="small" sx={{ mb: 1.5 }} disabled={saving} />
      <TextField label="Client Secret" type="password" value={clientSecret} onChange={(e) => setClientSecret(e.target.value)} fullWidth size="small" placeholder={myUplinkLinked ? '(saved)' : ''} helperText="Leave blank to keep existing secret" sx={{ mb: 2 }} disabled={saving} />

      {saveError && <Alert severity="error" sx={{ mb: 1.5, fontSize: 12 }}>{saveError}</Alert>}
      {saveOk && <Alert severity="success" sx={{ mb: 1.5, fontSize: 12 }}>Saved. Click Link to authorize.</Alert>}

      <Box sx={{ display: 'flex', gap: 1, flexWrap: 'wrap' }}>
        <Button variant="contained" onClick={handleSave} disabled={saving || !clientId} sx={{ textTransform: 'none' }}>
          {saving ? 'Saving…' : 'Save'}
        </Button>
        {clientId && (
          <Button variant="outlined" onClick={() => window.open('/api/myuplink/oauth/start', '_blank')} sx={{ textTransform: 'none' }}>
            Link Account
          </Button>
        )}
        {myUplinkLinked && (
          <Button variant="outlined" color="error" onClick={() => fetch('/api/myuplink/unlink', { method: 'POST' })} sx={{ textTransform: 'none' }}>
            Unlink
          </Button>
        )}
      </Box>
    </Box>
  );
}

// ── AI Assistant settings tab ────────────────────────────────────────────────

function AIAssistantSettings() {
  const [apiKey, setApiKey] = useState('');
  const [showKey, setShowKey] = useState(false);
  const [configured, setConfigured] = useState(false);
  const [loaded, setLoaded] = useState(false);
  const [saving, setSaving] = useState(false);
  const [saveOk, setSaveOk] = useState(false);
  const [saveError, setSaveError] = useState('');

  useMemo(() => {
    if (loaded) return;
    setLoaded(true);
    fetch('/api/chat/config').then((r) => r.json()).then((d: { configured?: boolean }) => {
      setConfigured(d.configured ?? false);
    }).catch(() => {});
  }, [loaded]);

  const handleSave = async () => {
    setSaving(true); setSaveOk(false); setSaveError('');
    try {
      const res = await fetch('/api/chat/config', {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ apiKey }),
      });
      if (!res.ok) throw new Error(`${res.status}`);
      setSaveOk(true);
      setConfigured(!!apiKey);
      setApiKey('');
    } catch (err) { setSaveError(String(err)); }
    finally { setSaving(false); }
  };

  return (
    <Box>
      <Box sx={{ display: 'flex', alignItems: 'center', gap: 1.5, mb: 3 }}>
        <ChatBubbleOutlineIcon sx={{ fontSize: 18, color: configured ? 'success.main' : 'text.disabled' }} />
        <Chip size="small" label={configured ? 'API Key Configured' : 'Not configured'} color={configured ? 'success' : 'default'} variant="outlined" />
      </Box>

      <Typography variant="caption" color="text.disabled" sx={{ display: 'block', mb: 1.5, textTransform: 'uppercase', letterSpacing: 1 }}>
        Anthropic API Key
      </Typography>
      <Typography variant="caption" color="text.secondary" sx={{ display: 'block', mb: 2 }}>
        Enter your Anthropic API key to enable the natural language chat assistant. Your key is stored securely on the server and never sent to the browser.
      </Typography>

      <TextField
        label="API Key"
        type={showKey ? 'text' : 'password'}
        value={apiKey}
        onChange={(e) => setApiKey(e.target.value)}
        fullWidth
        size="small"
        placeholder={configured ? '(key saved — enter new to replace)' : 'sk-ant-...'}
        sx={{ mb: 2 }}
        disabled={saving}
        slotProps={{
          input: {
            endAdornment: (
              <IconButton size="small" onClick={() => setShowKey(!showKey)} edge="end">
                {showKey ? <VisibilityOffIcon sx={{ fontSize: 18 }} /> : <VisibilityIcon sx={{ fontSize: 18 }} />}
              </IconButton>
            ),
          },
        }}
      />

      {saveError && <Alert severity="error" sx={{ mb: 1.5, fontSize: 12 }}>{saveError}</Alert>}
      {saveOk && <Alert severity="success" sx={{ mb: 1.5, fontSize: 12 }}>API key saved.</Alert>}

      <Box sx={{ display: 'flex', gap: 1 }}>
        <Button variant="contained" onClick={handleSave} disabled={saving || !apiKey} sx={{ textTransform: 'none' }}>
          {saving ? 'Saving…' : 'Save Key'}
        </Button>
        {configured && (
          <Button
            variant="outlined"
            color="error"
            onClick={async () => {
              await fetch('/api/chat/config', {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ apiKey: '' }),
              });
              setConfigured(false);
            }}
            sx={{ textTransform: 'none' }}
          >
            Remove Key
          </Button>
        )}
      </Box>
    </Box>
  );
}

// ── Main dialog export ───────────────────────────────────────────────────────

export function SettingsDialog({
  open, onClose, onSetup,
}: {
  open: boolean;
  onClose: () => void;
  onSetup?: () => void;
}) {
  const [tab, setTab] = useState(0);
  const { devices, connectionStatus, processorConnected, getUsageEvents } = useLutron();
  const { scenes } = useScenes();

  // Snapshot events when dialog opens
  const events = useMemo(() => (open ? getUsageEvents() : []), [open, getUsageEvents]);

  const rooms = useMemo(() => {
    const map = new Map<string, DeviceState[]>();
    for (const device of devices.values()) {
      const list = map.get(device.room) || [];
      list.push(device);
      map.set(device.room, list);
    }
    return map;
  }, [devices]);

  return (
    <Dialog
      open={open}
      onClose={onClose}
      maxWidth="sm"
      fullWidth
      PaperProps={{ sx: { maxHeight: '88vh', bgcolor: 'background.default' } }}
    >
      <DialogTitle sx={{ pb: 0, display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <Typography variant="h6" fontWeight={700}>Settings</Typography>
        <IconButton size="small" onClick={onClose} sx={{ color: 'text.secondary' }}>
          <CloseIcon fontSize="small" />
        </IconButton>
      </DialogTitle>
      <Tabs
        value={tab}
        onChange={(_, v) => setTab(v)}
        variant="scrollable"
        scrollButtons="auto"
        sx={{ px: 2, borderBottom: '1px solid rgba(255,255,255,0.08)', minHeight: 40 }}
      >
        <Tab label="Connection" sx={{ minHeight: 40, fontSize: 12 }} />
        <Tab label={<Box sx={{ display: 'flex', alignItems: 'center', gap: 0.5 }}><GarageIcon sx={{ fontSize: 12 }} />Garage</Box>} sx={{ minHeight: 40, fontSize: 12 }} />
        <Tab label="Dishwasher" sx={{ minHeight: 40, fontSize: 12 }} />
        <Tab label={<Box sx={{ display: 'flex', alignItems: 'center', gap: 0.5 }}><LocalLaundryServiceIcon sx={{ fontSize: 12 }} />Laundry</Box>} sx={{ minHeight: 40, fontSize: 12 }} />
        <Tab label={<Box sx={{ display: 'flex', alignItems: 'center', gap: 0.5 }}><AcUnitIcon sx={{ fontSize: 12 }} />Heat Pump</Box>} sx={{ minHeight: 40, fontSize: 12 }} />
        <Tab label={<Box sx={{ display: 'flex', alignItems: 'center', gap: 0.5 }}><ChatBubbleOutlineIcon sx={{ fontSize: 12 }} />AI Assistant</Box>} sx={{ minHeight: 40, fontSize: 12 }} />
        <Tab label={<Box sx={{ display: 'flex', alignItems: 'center', gap: 0.5 }}><SecurityIcon sx={{ fontSize: 12 }} />Alarm</Box>} sx={{ minHeight: 40, fontSize: 12 }} />
        <Tab label={<Box sx={{ display: 'flex', alignItems: 'center', gap: 0.5 }}><AutoAwesomeIcon sx={{ fontSize: 12 }} />For You</Box>} sx={{ minHeight: 40, fontSize: 12 }} />
      </Tabs>

      <DialogContent sx={{ pt: 2 }}>
        {/* Connection tab */}
        {tab === 0 && (
          <Box>
            <Box sx={{ display: 'flex', alignItems: 'center', gap: 1.5, mb: 3 }}>
              <Typography variant="body2" color="text.secondary">Status:</Typography>
              <Chip
                size="small"
                label={
                  processorConnected
                    ? 'Processor Connected'
                    : connectionStatus === 'connected'
                      ? 'Server Only'
                      : 'Disconnected'
                }
                color={processorConnected ? 'success' : connectionStatus === 'connected' ? 'warning' : 'error'}
                variant="outlined"
              />
            </Box>
            <Button
              variant="outlined"
              onClick={() => { onClose(); onSetup?.(); }}
              sx={{ textTransform: 'none' }}
            >
              Reconfigure Connection
            </Button>
          </Box>
        )}

        {/* Garage / MyQ tab */}
        {tab === 1 && <GarageSettings />}

        {/* HomeConnect / Dishwasher tab */}
        {tab === 2 && <HomeConnectSettings />}

        {/* SmartHQ / Laundry tab */}
        {tab === 3 && <SmartHQSettings />}

        {/* myUplink / Heat Pump tab */}
        {tab === 4 && <MyUplinkSettings />}

        {/* AI Assistant tab */}
        {tab === 5 && <AIAssistantSettings />}

        {/* Alarm / Total Connect tab */}
        {tab === 6 && <AlarmSettings />}

        {/* Personalization tab */}
        {tab === 7 && (
          <PersonalizationInsights
            events={events}
            devices={devices}
            scenes={scenes}
            rooms={rooms}
          />
        )}
      </DialogContent>
    </Dialog>
  );
}
