import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import type { ChargePointSession, ChargePointWeeklyStats } from './types.js';

// Persisted, gitignored on-disk history of completed charging sessions. Lives
// under server/data/ (already gitignored) so we retain long-term energy stats
// even after sessions age out of ChargePoint's charging-activities window.
const __dirname = dirname(fileURLToPath(import.meta.url));
const DATA_DIR = join(__dirname, '..', '..', 'data');
const STORE_PATH = join(DATA_DIR, 'chargepoint-sessions.json');

const WEEK_MS = 7 * 24 * 60 * 60 * 1000;
// How far back to consider when computing the rolling weekly average.
const WINDOW_MS = 26 * WEEK_MS;

interface StoredSession {
  sessionId: string;
  chargerId: string;
  startTime: number;
  endTime: number | null;
  energyKwh: number;
  cost: number | null;
  milesAdded: number | null;
}

function readStore(): StoredSession[] {
  if (!existsSync(STORE_PATH)) return [];
  try {
    const raw = readFileSync(STORE_PATH, 'utf-8');
    const parsed = JSON.parse(raw) as StoredSession[];
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

function writeStore(sessions: StoredSession[]): void {
  try {
    if (!existsSync(DATA_DIR)) mkdirSync(DATA_DIR, { recursive: true });
    writeFileSync(STORE_PATH, JSON.stringify(sessions, null, 2), 'utf-8');
  } catch (err) {
    console.error('ChargePoint: failed to persist session history:', (err as Error).message);
  }
}

/**
 * Merge freshly-fetched completed sessions into the persisted store, keyed by
 * sessionId (later fetches win — energy/cost finalize when a session ends).
 * In-progress sessions (endTime === null) are intentionally NOT persisted.
 */
export function recordSessions(sessions: ChargePointSession[]): void {
  const completed = sessions.filter(
    (s) => s.endTime != null && s.sessionId && s.energyKwh > 0,
  );
  if (completed.length === 0) return;

  const byId = new Map<string, StoredSession>();
  for (const s of readStore()) byId.set(s.sessionId, s);
  for (const s of completed) {
    byId.set(s.sessionId, {
      sessionId: s.sessionId,
      chargerId: s.chargerId,
      startTime: s.startTime,
      endTime: s.endTime,
      energyKwh: s.energyKwh,
      cost: s.cost,
      milesAdded: s.milesAdded,
    });
  }
  writeStore(Array.from(byId.values()).sort((a, b) => a.startTime - b.startTime));
}

/**
 * Rolling weekly-average energy stats from the persisted store. When
 * `chargerId` is given, only that charger's sessions count. `weeks` is the
 * number of distinct calendar weeks (within the trailing window) that had at
 * least one session, so the average isn't diluted by idle weeks.
 */
export function weeklyStats(chargerId?: string): ChargePointWeeklyStats {
  const cutoff = Date.now() - WINDOW_MS;
  const inWindow = readStore().filter((s) => s.startTime >= cutoff);
  // Prefer this charger's sessions; fall back to all (session device_id can
  // differ from the configuration `id`, same reason pickLiveSession falls back).
  let rows = chargerId ? inWindow.filter((s) => s.chargerId === chargerId) : inWindow;
  if (rows.length === 0) rows = inWindow;

  if (rows.length === 0) {
    return { weeklyAvgKwh: 0, weeks: 0, totalKwh: 0, sessionCount: 0 };
  }

  const weekBuckets = new Set<number>();
  let totalKwh = 0;
  for (const s of rows) {
    totalKwh += s.energyKwh;
    weekBuckets.add(Math.floor(s.startTime / WEEK_MS));
  }
  const weeks = Math.max(1, weekBuckets.size);
  return {
    weeklyAvgKwh: totalKwh / weeks,
    weeks,
    totalKwh,
    sessionCount: rows.length,
  };
}
