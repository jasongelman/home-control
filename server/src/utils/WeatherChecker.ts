/**
 * WeatherChecker
 *
 * Fetches current cloud cover from Open-Meteo (free, no API key required).
 * Results are cached for 15 minutes to avoid hitting the API every 60 seconds.
 *
 * "Sunny" is defined as cloud cover below a configurable threshold (default 75%).
 * If the API is unreachable the check fails open — automation proceeds normally
 * and a warning is logged.
 */

const CACHE_TTL_MS = 15 * 60 * 1000; // 15 minutes
const OPEN_METEO_URL = 'https://api.open-meteo.com/v1/forecast';

interface WeatherCache {
  cloudCover: number;
  fetchedAt: number;
}

export interface WeatherStatus {
  cloudCover: number;        // 0–100 %
  isSunny: boolean;
  cloudCoverThreshold: number;
  fetchedAt: number | null;  // epoch ms, null if never successfully fetched
  source: 'live' | 'cached' | 'unavailable';
}

export class WeatherChecker {
  private cache: WeatherCache | null = null;

  constructor(
    private readonly lat: number,
    private readonly lon: number,
    /** Cloud cover percentage above which the sun is considered blocked (default 75). */
    private readonly cloudCoverThreshold: number = 75,
  ) {}

  /** Returns true if the sun is visible enough to warrant lowering shades. */
  async isSunny(): Promise<boolean> {
    const status = await this.getStatus();
    return status.isSunny;
  }

  async getStatus(): Promise<WeatherStatus> {
    const now = Date.now();

    // Return cached value if still fresh
    if (this.cache && now - this.cache.fetchedAt < CACHE_TTL_MS) {
      return {
        cloudCover: this.cache.cloudCover,
        isSunny: this.cache.cloudCover < this.cloudCoverThreshold,
        cloudCoverThreshold: this.cloudCoverThreshold,
        fetchedAt: this.cache.fetchedAt,
        source: 'cached',
      };
    }

    try {
      const url =
        `${OPEN_METEO_URL}?latitude=${this.lat}&longitude=${this.lon}` +
        `&current=cloud_cover&timezone=auto&forecast_days=1`;

      const res = await fetch(url, { signal: AbortSignal.timeout(8_000) });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);

      const data = (await res.json()) as { current?: { cloud_cover?: number } };
      const cloudCover = data.current?.cloud_cover ?? 0;

      this.cache = { cloudCover, fetchedAt: now };

      return {
        cloudCover,
        isSunny: cloudCover < this.cloudCoverThreshold,
        cloudCoverThreshold: this.cloudCoverThreshold,
        fetchedAt: now,
        source: 'live',
      };
    } catch (err) {
      console.warn(
        `[SunShade] Weather check failed (${(err as Error).message}) — assuming sunny`,
      );
      // Fail open: if we can't reach the API, don't block the automation
      return {
        cloudCover: 0,
        isSunny: true,
        cloudCoverThreshold: this.cloudCoverThreshold,
        fetchedAt: this.cache?.fetchedAt ?? null,
        source: 'unavailable',
      };
    }
  }
}
