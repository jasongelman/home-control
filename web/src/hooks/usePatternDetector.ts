import { useMemo } from 'react';
import type { UsageEvent } from './useUsageTracker.js';

// ── Types ──────────────────────────────────────────────────────────────────

export interface DetectedPattern {
  /** Hash for dedup/dismiss tracking */
  hash: string;
  /** Devices involved and their average levels */
  devices: { id: number; avgLevel: number; room?: string }[];
  /** Approximate time of day this pattern occurs */
  timeOfDay?: string;
  /** How many times this pattern was observed */
  frequency: number;
}

// ── Constants ──────────────────────────────────────────────────────────────

const SESSION_GAP_MS = 5 * 60 * 1000; // 5 minutes
const MIN_SESSION_DEVICES = 2;
const MIN_PATTERN_FREQUENCY = 3;
const LEVEL_TOLERANCE = 10; // ±10% considered same level
const DISMISSED_KEY = 'lutron_dismissed_patterns';

// ── Helpers ────────────────────────────────────────────────────────────────

interface Session {
  devices: Map<number, { levels: number[]; room?: string }>;
  startTime: number;
}

function buildSessions(events: UsageEvent[]): Session[] {
  const deviceEvents = events.filter((e) => e.type === 'device' && typeof e.id === 'number');
  if (deviceEvents.length === 0) return [];

  const sessions: Session[] = [];
  let current: Session = { devices: new Map(), startTime: deviceEvents[0].timestamp };

  for (const e of deviceEvents) {
    // Start new session if gap is too large
    if (e.timestamp - current.startTime > SESSION_GAP_MS && current.devices.size > 0) {
      sessions.push(current);
      current = { devices: new Map(), startTime: e.timestamp };
    }

    const id = e.id as number;
    const existing = current.devices.get(id);
    if (existing) {
      if (e.level !== undefined) existing.levels.push(e.level);
    } else {
      current.devices.set(id, {
        levels: e.level !== undefined ? [e.level] : [],
        room: e.room,
      });
    }
  }
  if (current.devices.size > 0) sessions.push(current);

  return sessions.filter((s) => s.devices.size >= MIN_SESSION_DEVICES);
}

/** Create a normalized fingerprint for a session (sorted device IDs + bucketed levels) */
function sessionFingerprint(session: Session): string {
  const parts = Array.from(session.devices.entries())
    .sort((a, b) => a[0] - b[0])
    .map(([id, data]) => {
      const avgLevel = data.levels.length > 0
        ? Math.round(data.levels.reduce((a, b) => a + b, 0) / data.levels.length / LEVEL_TOLERANCE) * LEVEL_TOLERANCE
        : 0;
      return `${id}:${avgLevel}`;
    });
  return parts.join('|');
}

function hashString(str: string): string {
  let hash = 0;
  for (let i = 0; i < str.length; i++) {
    const char = str.charCodeAt(i);
    hash = ((hash << 5) - hash) + char;
    hash |= 0;
  }
  return Math.abs(hash).toString(36);
}

function getHourLabel(timestamp: number): string {
  const hour = new Date(timestamp).getHours();
  if (hour >= 5 && hour < 12) return 'morning';
  if (hour >= 12 && hour < 18) return 'afternoon';
  if (hour >= 18 || hour < 2) return 'evening';
  return 'night';
}

function getDismissedPatterns(): Set<string> {
  try {
    const raw = localStorage.getItem(DISMISSED_KEY);
    return raw ? new Set(JSON.parse(raw)) : new Set();
  } catch {
    return new Set();
  }
}

export function dismissPattern(hash: string) {
  const dismissed = getDismissedPatterns();
  dismissed.add(hash);
  localStorage.setItem(DISMISSED_KEY, JSON.stringify(Array.from(dismissed)));
}

// ── Hook ───────────────────────────────────────────────────────────────────

export function usePatternDetector(events: UsageEvent[]): DetectedPattern[] {
  return useMemo(() => {
    if (events.length < 10) return [];

    const sessions = buildSessions(events);
    if (sessions.length < MIN_PATTERN_FREQUENCY) return [];

    // Group sessions by fingerprint
    const groups = new Map<string, Session[]>();
    for (const session of sessions) {
      const fp = sessionFingerprint(session);
      const group = groups.get(fp) || [];
      group.push(session);
      groups.set(fp, group);
    }

    const dismissed = getDismissedPatterns();
    const patterns: DetectedPattern[] = [];

    for (const [fp, group] of groups) {
      if (group.length < MIN_PATTERN_FREQUENCY) continue;

      const hash = hashString(fp);
      if (dismissed.has(hash)) continue;

      // Compute average levels across all occurrences
      const deviceIds = Array.from(group[0].devices.keys());
      const devices = deviceIds.map((id) => {
        const allLevels: number[] = [];
        let room: string | undefined;
        for (const session of group) {
          const data = session.devices.get(id);
          if (data) {
            allLevels.push(...data.levels);
            if (data.room) room = data.room;
          }
        }
        const avgLevel = allLevels.length > 0
          ? Math.round(allLevels.reduce((a, b) => a + b, 0) / allLevels.length)
          : 0;
        return { id, avgLevel, room };
      });

      // Most common time of day
      const timeCounts = new Map<string, number>();
      for (const session of group) {
        const label = getHourLabel(session.startTime);
        timeCounts.set(label, (timeCounts.get(label) || 0) + 1);
      }
      const timeOfDay = Array.from(timeCounts.entries())
        .sort((a, b) => b[1] - a[1])[0]?.[0];

      patterns.push({
        hash,
        devices,
        timeOfDay,
        frequency: group.length,
      });
    }

    return patterns.sort((a, b) => b.frequency - a.frequency);
  }, [events]);
}
