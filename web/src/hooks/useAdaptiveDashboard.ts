import { useMemo } from 'react';
import type { DeviceState } from '../types/index.js';
import type { UsageEvent } from './useUsageTracker.js';
import {
  getTimeBucket,
  getRoomScoresForBucket,
  getTopDevices,
  getTopScenes,
} from './useUsageTracker.js';

// ── Types ──────────────────────────────────────────────────────────────────

export interface SuggestedAction {
  type: 'device' | 'scene';
  id: number | string;
  room?: string;
  label: string;
  score: number;
}

// ── Constants ──────────────────────────────────────────────────────────────

const SEVEN_DAYS_MS = 7 * 24 * 60 * 60 * 1000;
const THIRTY_DAYS_MS = 30 * 24 * 60 * 60 * 1000;

// ── Hook ───────────────────────────────────────────────────────────────────

export function useAdaptiveDashboard(
  events: UsageEvent[],
  rooms: Map<string, DeviceState[]>,
  scenes: { id: string; name: string }[],
) {
  const currentBucket = getTimeBucket();

  /** Sort rooms by relevance: time-of-day frequency (60%) + recent usage (40%) */
  const sortedRoomNames = useMemo(() => {
    if (events.length === 0) return Array.from(rooms.keys()).sort();

    // Time-of-day scores (how often this room is used in the current time bucket)
    const bucketScores = getRoomScoresForBucket(events, currentBucket);

    // Recent usage scores (last 7 days)
    const now = Date.now();
    const recentEvents = events.filter((e) => e.room && now - e.timestamp < SEVEN_DAYS_MS);
    const recentScores = new Map<string, number>();
    for (const e of recentEvents) {
      if (e.room) {
        recentScores.set(e.room, (recentScores.get(e.room) || 0) + 1);
      }
    }

    // Normalize scores
    const maxBucket = Math.max(1, ...bucketScores.values());
    const maxRecent = Math.max(1, ...recentScores.values());

    const roomNames = Array.from(rooms.keys());
    const scored = roomNames.map((name) => ({
      name,
      score:
        ((bucketScores.get(name) || 0) / maxBucket) * 0.6 +
        ((recentScores.get(name) || 0) / maxRecent) * 0.4,
    }));

    // Rooms with scores sort by score desc; rooms with no usage go alphabetical at the end
    const withScore = scored.filter((r) => r.score > 0).sort((a, b) => b.score - a.score);
    const noScore = scored.filter((r) => r.score === 0).sort((a, b) => a.name.localeCompare(b.name));

    return [...withScore, ...noScore].map((r) => r.name);
  }, [events, rooms, currentBucket]);

  /** "For You" suggested actions based on current time + historical patterns */
  const suggestedActions = useMemo((): SuggestedAction[] => {
    const suggestions: SuggestedAction[] = [];

    // Always surface the Evening scene during evening hours (6pm–2am)
    if (currentBucket === 'evening') {
      const eveningScene = scenes.find((s) =>
        s.name.toLowerCase().replace(/[^a-z0-9]/g, '').includes('evening'),
      );
      if (eveningScene) {
        suggestions.push({ type: 'scene', id: eveningScene.id, label: eveningScene.name, score: Infinity });
      }
    }

    if (events.length < 5) return suggestions; // Need minimum data for history-based suggestions

    // Top devices for this time of day (last 30 days)
    const bucketEvents = events.filter(
      (e) =>
        e.type === 'device' &&
        getTimeBucket(new Date(e.timestamp)) === currentBucket &&
        Date.now() - e.timestamp < THIRTY_DAYS_MS,
    );
    const deviceCounts = new Map<number | string, { count: number; room?: string; lastLevel?: number }>();
    for (const e of bucketEvents) {
      const existing = deviceCounts.get(e.id);
      if (existing) {
        existing.count++;
        if (e.level !== undefined) existing.lastLevel = e.level;
      } else {
        deviceCounts.set(e.id, { count: 1, room: e.room, lastLevel: e.level });
      }
    }

    // Top 4 devices for this time bucket
    const topDevices = Array.from(deviceCounts.entries())
      .sort((a, b) => b[1].count - a[1].count)
      .slice(0, 4);

    for (const [id, data] of topDevices) {
      const levelStr = data.lastLevel !== undefined ? ` to ${data.lastLevel}%` : '';
      suggestions.push({
        type: 'device',
        id,
        room: data.room,
        label: `${data.room || 'Device'} ${levelStr}`.trim(),
        score: data.count,
      });
    }

    // Top scenes overall (skip any already pinned)
    const pinnedIds = new Set(suggestions.map((s) => String(s.id)));
    const topScenes = getTopScenes(events, 2);
    for (const s of topScenes) {
      if (pinnedIds.has(String(s.id))) continue;
      const scene = scenes.find((sc) => sc.id === s.id);
      if (scene) {
        suggestions.push({
          type: 'scene',
          id: s.id,
          label: scene.name,
          score: s.count,
        });
      }
    }

    // Sort by score and take top 4
    return suggestions.sort((a, b) => b.score - a.score).slice(0, 4);
  }, [events, scenes, currentBucket]);

  /** Dynamic quick actions — replace hardcoded ones when we have data */
  const dynamicQuickActions = useMemo(() => {
    if (events.length < 10) return null; // Not enough data, use defaults

    const topScenes = getTopScenes(events, 4);
    if (topScenes.length === 0) return null;

    return topScenes.map((s) => {
      const scene = scenes.find((sc) => sc.id === s.id);
      return {
        id: s.id,
        label: scene?.name || `Scene ${s.id.slice(0, 6)}`,
        count: s.count,
      };
    });
  }, [events, scenes]);

  return {
    sortedRoomNames,
    suggestedActions,
    dynamicQuickActions,
    currentBucket,
  };
}
