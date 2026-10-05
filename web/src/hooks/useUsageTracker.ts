import { useCallback, useRef } from 'react';

// ── Types ──────────────────────────────────────────────────────────────────

export interface UsageEvent {
  /** `bulk` = one multi-device action (e.g. All Off), logged once instead of per light. */
  type: 'device' | 'scene' | 'bulk';
  id: number | string;
  action: 'setLevel' | 'activate' | 'turnOff';
  level?: number;
  room?: string;
  timestamp: number;
}

interface DeviceScore {
  id: number | string;
  room?: string;
  count: number;
  lastUsed: number;
}

interface SceneScore {
  id: string;
  name?: string;
  count: number;
  lastUsed: number;
}

// ── Constants ──────────────────────────────────────────────────────────────

const STORAGE_KEY = 'lutron_usage_log';
/** Rooms renamed since events were logged; applied on load so habits aren't split. */
const ROOM_RENAMES: Record<string, string> = {
  'Master Suite': 'Primary Suite',
  'Primary Bedroom': 'Primary Suite',
};

/** Keep a year of history; the count cap keeps it under browsers' ~5 MB localStorage limit. */
const RETENTION_MS = 365 * 24 * 60 * 60 * 1000;
const MAX_EVENTS = 25_000;

// Time-of-day buckets (hour ranges)
export type TimeBucket = 'morning' | 'afternoon' | 'evening' | 'night';

export function getTimeBucket(date: Date = new Date()): TimeBucket {
  const hour = date.getHours();
  if (hour >= 5 && hour < 12) return 'morning';
  if (hour >= 12 && hour < 18) return 'afternoon';
  if (hour >= 18 || hour < 2) return 'evening';
  return 'night';
}

// ── Storage helpers ────────────────────────────────────────────────────────

function loadEvents(): UsageEvent[] {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    const events: UsageEvent[] = raw ? JSON.parse(raw) : [];
    for (const e of events) {
      if (e.room && ROOM_RENAMES[e.room]) e.room = ROOM_RENAMES[e.room];
    }
    return events;
  } catch {
    return [];
  }
}

function saveEvents(events: UsageEvent[]): UsageEvent[] {
  const cutoff = Date.now() - RETENTION_MS;
  let trimmed = events.filter((e) => e.timestamp >= cutoff);
  if (trimmed.length > MAX_EVENTS) trimmed = trimmed.slice(trimmed.length - MAX_EVENTS);
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(trimmed));
  } catch {
    // Quota exceeded: drop the oldest half and retry once.
    trimmed = trimmed.slice(Math.floor(trimmed.length / 2));
    try { localStorage.setItem(STORAGE_KEY, JSON.stringify(trimmed)); } catch { /* give up */ }
  }
  return trimmed;
}

// ── Query functions (pure, operate on event arrays) ────────────────────────

/** Get the most-used devices, optionally filtered to a time window (ms) */
export function getTopDevices(events: UsageEvent[], n: number, timeWindowMs?: number): DeviceScore[] {
  const now = Date.now();
  const filtered = events.filter((e) => {
    if (e.type !== 'device') return false;
    if (timeWindowMs && now - e.timestamp > timeWindowMs) return false;
    return true;
  });

  const counts = new Map<number | string, DeviceScore>();
  for (const e of filtered) {
    const existing = counts.get(e.id);
    if (existing) {
      existing.count++;
      if (e.timestamp > existing.lastUsed) existing.lastUsed = e.timestamp;
    } else {
      counts.set(e.id, { id: e.id, room: e.room, count: 1, lastUsed: e.timestamp });
    }
  }

  return Array.from(counts.values())
    .sort((a, b) => b.count - a.count)
    .slice(0, n);
}

/** Get the most-activated scenes */
export function getTopScenes(events: UsageEvent[], n: number): SceneScore[] {
  const filtered = events.filter((e) => e.type === 'scene');
  const counts = new Map<string, SceneScore>();
  for (const e of filtered) {
    const id = String(e.id);
    const existing = counts.get(id);
    if (existing) {
      existing.count++;
      if (e.timestamp > existing.lastUsed) existing.lastUsed = e.timestamp;
    } else {
      counts.set(id, { id, count: 1, lastUsed: e.timestamp });
    }
  }
  return Array.from(counts.values())
    .sort((a, b) => b.count - a.count)
    .slice(0, n);
}

/** Get most recent actions */
export function getRecentActions(events: UsageEvent[], n: number): UsageEvent[] {
  return events.slice(-n).reverse();
}

/** Get events filtered to a specific time-of-day bucket */
export function getEventsForTimeBucket(events: UsageEvent[], bucket: TimeBucket): UsageEvent[] {
  return events.filter((e) => getTimeBucket(new Date(e.timestamp)) === bucket);
}

/** Get device usage counts per room for a time bucket */
export function getRoomScoresForBucket(events: UsageEvent[], bucket: TimeBucket): Map<string, number> {
  const bucketEvents = getEventsForTimeBucket(events, bucket);
  const scores = new Map<string, number>();
  for (const e of bucketEvents) {
    if (e.room) {
      scores.set(e.room, (scores.get(e.room) || 0) + 1);
    }
  }
  return scores;
}

// ── Hook ───────────────────────────────────────────────────────────────────

export function useUsageTracker() {
  // Use ref to avoid re-renders when logging
  const eventsRef = useRef<UsageEvent[] | null>(null);

  const getEvents = useCallback((): UsageEvent[] => {
    if (eventsRef.current === null) {
      eventsRef.current = loadEvents();
    }
    return eventsRef.current;
  }, []);

  const trackAction = useCallback((event: Omit<UsageEvent, 'timestamp'>) => {
    const fullEvent: UsageEvent = { ...event, timestamp: Date.now() };
    const events = getEvents();
    events.push(fullEvent);
    eventsRef.current = saveEvents(events);
  }, [getEvents]);

  const trackDevice = useCallback((id: number, action: UsageEvent['action'], room?: string, level?: number) => {
    trackAction({ type: 'device', id, action, room, level });
  }, [trackAction]);

  const trackScene = useCallback((id: string, name?: string) => {
    trackAction({ type: 'scene', id, action: 'activate' });
  }, [trackAction]);

  const trackBulk = useCallback((label: string, action: UsageEvent['action'] = 'activate', room?: string) => {
    trackAction({ type: 'bulk', id: label, action, room });
  }, [trackAction]);

  return {
    trackAction,
    trackDevice,
    trackScene,
    trackBulk,
    getEvents,
  };
}
