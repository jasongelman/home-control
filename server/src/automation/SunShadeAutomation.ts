/**
 * SunShadeAutomation
 *
 * Checks every 60 seconds whether the sun is shining through west-facing
 * windows AND the sky is clear enough to warrant it. On transition into the
 * active state it lowers the configured shades; on transition out it raises
 * them back. Commands are sent only on state change — not every tick.
 *
 * Active = sun azimuth/altitude in trigger window AND cloud cover below threshold.
 */

import { getSunPosition, isSunInWestWindow } from '../utils/SunPosition.js';
import { WeatherChecker } from '../utils/WeatherChecker.js';
import type { LEAPConnection } from '../lutron/LEAPConnection.js';
import type { AutomationConfig } from '../lutron/types.js';
import type { SunPosition } from '../utils/SunPosition.js';
import type { WeatherStatus } from '../utils/WeatherChecker.js';

export interface AutomationStatus {
  id: string;
  name: string;
  enabled: boolean;
  isActive: boolean;
  sunPosition: SunPosition;
  weather: WeatherStatus;
  trigger: AutomationConfig['trigger'];
  shadeCount: number;
  lastChecked: number | null;
  nextCheckIn: number; // seconds
}

const CHECK_INTERVAL_MS = 60_000; // 1 minute

export class SunShadeAutomation {
  private wasActive = false;
  private timer: ReturnType<typeof setInterval> | null = null;
  private lastSunPos: SunPosition = { azimuth: 0, altitude: -90 };
  private lastWeather: WeatherStatus = {
    cloudCover: 0,
    isSunny: true,
    cloudCoverThreshold: 75,
    fetchedAt: null,
    source: 'unavailable',
  };
  private lastChecked: number | null = null;
  private readonly weather: WeatherChecker;

  constructor(
    private readonly config: AutomationConfig,
    private readonly leap: LEAPConnection,
  ) {
    this.weather = new WeatherChecker(
      config.location.lat,
      config.location.lon,
      config.weather?.cloudCoverThreshold ?? 75,
    );
  }

  start(): void {
    if (this.timer) return;
    void this.tick();
    this.timer = setInterval(() => void this.tick(), CHECK_INTERVAL_MS);
    console.log(`[SunShade] "${this.config.name}" automation started`);
  }

  stop(): void {
    if (this.timer) {
      clearInterval(this.timer);
      this.timer = null;
    }
    console.log(`[SunShade] "${this.config.name}" automation stopped`);
  }

  getStatus(): AutomationStatus {
    const secondsSinceCheck =
      this.lastChecked !== null
        ? Math.floor((Date.now() - this.lastChecked) / 1000)
        : null;
    return {
      id: this.config.id,
      name: this.config.name,
      enabled: this.config.enabled,
      isActive: this.wasActive,
      sunPosition: this.lastSunPos,
      weather: this.lastWeather,
      trigger: this.config.trigger,
      shadeCount: this.config.shades.length,
      lastChecked: this.lastChecked,
      nextCheckIn:
        secondsSinceCheck !== null
          ? Math.max(0, CHECK_INTERVAL_MS / 1000 - secondsSinceCheck)
          : 0,
    };
  }

  private async tick(): Promise<void> {
    if (!this.config.enabled) return;

    const { lat, lon } = this.config.location;
    const { trigger, shades, fadeSeconds } = this.config;

    const [pos, weatherStatus] = await Promise.all([
      Promise.resolve(getSunPosition(new Date(), lat, lon)),
      this.weather.getStatus(),
    ]);

    this.lastSunPos = pos;
    this.lastWeather = weatherStatus;
    this.lastChecked = Date.now();

    const sunInWindow = isSunInWestWindow(
      pos,
      trigger.azimuthMin,
      trigger.azimuthMax,
      trigger.altitudeMin,
    );

    const isActive = sunInWindow && weatherStatus.isSunny;

    const changed = isActive !== this.wasActive;
    this.wasActive = isActive;

    if (!changed) return;

    if (isActive) {
      console.log(
        `[SunShade] Sun entered west window — sunny (${weatherStatus.cloudCover}% cloud cover), ` +
          `az=${pos.azimuth.toFixed(1)}° alt=${pos.altitude.toFixed(1)}° — lowering ${shades.length} shade(s)`,
      );
    } else if (sunInWindow && !weatherStatus.isSunny) {
      console.log(
        `[SunShade] Sky too overcast (${weatherStatus.cloudCover}% cloud cover) — raising ${shades.length} shade(s)`,
      );
    } else {
      console.log(
        `[SunShade] Sun left west window ` +
          `(az=${pos.azimuth.toFixed(1)}° alt=${pos.altitude.toFixed(1)}°) — raising ${shades.length} shade(s)`,
      );
    }

    if (!this.leap.isConnected) {
      console.warn('[SunShade] Processor not connected — skipping shade commands');
      return;
    }

    await Promise.allSettled(
      shades.map((shade) => {
        const level = isActive ? shade.downLevel : shade.upLevel;
        return this.leap.setLevel(shade.deviceId, level, fadeSeconds).catch((err: Error) => {
          console.error(
            `[SunShade] Failed to set device ${shade.deviceId} to ${level}%:`,
            err.message,
          );
        });
      }),
    );
  }
}
