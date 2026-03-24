/**
 * NOAA Solar Position Algorithm
 *
 * Computes sun azimuth and altitude for a given date/time and location.
 * Extends the same NOAA equations used in SunCalculator.swift (which
 * handles sunrise/sunset) to also output azimuth and altitude.
 *
 * Reference: https://gml.noaa.gov/grad/solcalc/solareqns.PDF
 *
 * Conventions:
 *   azimuth  — degrees clockwise from true north (0=N, 90=E, 180=S, 270=W)
 *   altitude — degrees above horizon (negative = below horizon / sun is down)
 */

export interface SunPosition {
  /** Degrees clockwise from true north (0–360). */
  azimuth: number;
  /** Degrees above the horizon. Negative when the sun is below the horizon. */
  altitude: number;
}

export function getSunPosition(date: Date, lat: number, lon: number): SunPosition {
  const toRad = (d: number) => (d * Math.PI) / 180;
  const toDeg = (r: number) => (r * 180) / Math.PI;

  // Day of year (1-based)
  const start = new Date(Date.UTC(date.getUTCFullYear(), 0, 0));
  const dayOfYear = Math.floor((date.getTime() - start.getTime()) / 86_400_000);

  // Fractional year in radians (referenced to UTC noon)
  const gamma =
    ((2 * Math.PI) / 365) * (dayOfYear - 1 + (date.getUTCHours() - 12) / 24);

  // Equation of time (minutes) — matches SunCalculator.swift exactly
  const eqtime =
    229.18 *
    (0.000075 +
      0.001868 * Math.cos(gamma) -
      0.032077 * Math.sin(gamma) -
      0.014615 * Math.cos(2 * gamma) -
      0.040849 * Math.sin(2 * gamma));

  // Solar declination (radians) — matches SunCalculator.swift exactly
  const decl =
    0.006918 -
    0.399912 * Math.cos(gamma) +
    0.070257 * Math.sin(gamma) -
    0.006758 * Math.cos(2 * gamma) +
    0.000907 * Math.sin(2 * gamma) -
    0.002697 * Math.cos(3 * gamma) +
    0.00148 * Math.sin(3 * gamma);

  // True solar time (minutes from midnight UTC)
  // Longitude adds 4 min per degree; negative (west) shifts earlier.
  const utcMin =
    date.getUTCHours() * 60 + date.getUTCMinutes() + date.getUTCSeconds() / 60;
  const trueSolarMin = utcMin + eqtime + 4 * lon;

  // Hour angle in degrees: 0 at solar noon, negative morning, positive afternoon
  const hourAngleDeg = trueSolarMin / 4 - 180;
  const ha = toRad(hourAngleDeg);

  const latRad = toRad(lat);

  // ── Altitude ──────────────────────────────────────────────────────────────

  const sinAlt =
    Math.sin(latRad) * Math.sin(decl) +
    Math.cos(latRad) * Math.cos(decl) * Math.cos(ha);
  const altitudeRad = Math.asin(saturate(sinAlt));
  const altitude = toDeg(altitudeRad);

  // ── Azimuth (clockwise from north) ────────────────────────────────────────
  // Using atan2 form which handles all quadrants correctly:
  //   sinAz = -cos(decl)*sin(ha) / cos(alt)     [negative in afternoon → west]
  //   cosAz = (sin(decl) - sin(lat)*sin(alt)) / (cos(lat)*cos(alt))
  //   azimuth = atan2(sinAz, cosAz), normalised to [0, 360)

  const cosAlt = Math.cos(altitudeRad);
  let azimuth: number;
  if (cosAlt < 1e-10) {
    // Sun is at/near zenith — azimuth is undefined; return 0
    azimuth = 0;
  } else {
    const sinAz = (-Math.cos(decl) * Math.sin(ha)) / cosAlt;
    const cosAz =
      (Math.sin(decl) - Math.sin(latRad) * sinAlt) /
      (Math.cos(latRad) * cosAlt);
    azimuth = (toDeg(Math.atan2(sinAz, cosAz)) + 360) % 360;
  }

  return { azimuth, altitude };
}

/**
 * Returns true when the sun is shining through west-facing windows.
 * Default window: azimuth 200°–290° (SSW through WNW), altitude ≥ 5°.
 * Corresponds roughly to 1–2 PM through sunset at Larchmont's latitude.
 */
export function isSunInWestWindow(
  pos: SunPosition,
  azimuthMin = 200,
  azimuthMax = 290,
  altitudeMin = 5,
): boolean {
  return (
    pos.altitude >= altitudeMin &&
    pos.azimuth >= azimuthMin &&
    pos.azimuth <= azimuthMax
  );
}

function saturate(v: number): number {
  return Math.min(1, Math.max(-1, v));
}
