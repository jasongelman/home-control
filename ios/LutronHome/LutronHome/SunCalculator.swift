import Foundation
import SwiftUI

/// Lightweight sunrise/sunset calculator using the NOAA solar equations.
/// No external dependencies needed.
struct SunCalculator {

    /// Location of the home (Larchmont, NY)
    static let latitude  = 40.93  // Larchmont, NY
    static let longitude = -73.75 // Larchmont, NY

    /// Time periods for the app
    enum TimePeriod: String {
        case earlyMorning   // Before sunrise
        case morning        // Sunrise to 10am
        case midday         // 10am to 4pm
        case evening        // 4pm to sunset
        case night          // After sunset

        var greeting: String {
            switch self {
            case .earlyMorning: return "Good Morning"
            case .morning: return "Good Morning"
            case .midday: return "Good Afternoon"
            case .evening: return "Good Evening"
            case .night: return "Good Night"
            }
        }

        var icon: String {
            switch self {
            case .earlyMorning: return "sunrise"
            case .morning: return "sun.and.horizon"
            case .midday: return "sun.max.fill"
            case .evening: return "sunset"
            case .night: return "moon.stars"
            }
        }
    }

    /// Theme colors that shift with time of day
    struct TimeTheme {
        let accent: Color
        let headerGradient: [Color]
        let backgroundTint: Color
        let cardTint: Color
        let sectionHeaderColor: Color

        static let earlyMorning = TimeTheme(
            accent: Color(red: 0.45, green: 0.35, blue: 0.85),  // Rich violet
            headerGradient: [
                Color(red: 0.10, green: 0.07, blue: 0.28).opacity(0.75),
                Color(red: 0.25, green: 0.18, blue: 0.55).opacity(0.40),
                Color.clear
            ],
            backgroundTint: Color(red: 0.08, green: 0.06, blue: 0.22).opacity(0.12),
            cardTint: Color(red: 0.30, green: 0.20, blue: 0.65).opacity(0.08),
            sectionHeaderColor: Color(red: 0.55, green: 0.45, blue: 0.90)
        )
        static let morning = TimeTheme(
            accent: Color(red: 0.95, green: 0.60, blue: 0.15),  // Golden amber
            headerGradient: [
                Color(red: 0.90, green: 0.55, blue: 0.10).opacity(0.55),
                Color(red: 0.98, green: 0.80, blue: 0.30).opacity(0.25),
                Color.clear
            ],
            backgroundTint: Color(red: 0.95, green: 0.75, blue: 0.20).opacity(0.07),
            cardTint: Color(red: 0.95, green: 0.70, blue: 0.15).opacity(0.06),
            sectionHeaderColor: Color(red: 0.90, green: 0.55, blue: 0.10)
        )
        static let midday = TimeTheme(
            accent: Color(red: 0.10, green: 0.55, blue: 0.95),  // Sky blue
            headerGradient: [
                Color(red: 0.35, green: 0.70, blue: 0.98).opacity(0.45),
                Color(red: 0.20, green: 0.55, blue: 0.90).opacity(0.20),
                Color.clear
            ],
            backgroundTint: Color(red: 0.15, green: 0.55, blue: 0.95).opacity(0.06),
            cardTint: Color(red: 0.20, green: 0.60, blue: 0.95).opacity(0.05),
            sectionHeaderColor: Color(red: 0.10, green: 0.50, blue: 0.90)
        )
        static let evening = TimeTheme(
            accent: Color(red: 0.95, green: 0.40, blue: 0.15),  // Burnt orange
            headerGradient: [
                Color(red: 0.75, green: 0.22, blue: 0.10).opacity(0.65),
                Color(red: 0.95, green: 0.50, blue: 0.15).opacity(0.35),
                Color.clear
            ],
            backgroundTint: Color(red: 0.70, green: 0.20, blue: 0.08).opacity(0.10),
            cardTint: Color(red: 0.85, green: 0.35, blue: 0.10).opacity(0.07),
            sectionHeaderColor: Color(red: 0.90, green: 0.40, blue: 0.12)
        )
        static let night = TimeTheme(
            accent: Color(red: 0.40, green: 0.65, blue: 1.0),   // Cool blue-white
            headerGradient: [
                Color(red: 0.05, green: 0.10, blue: 0.30).opacity(0.80),
                Color(red: 0.10, green: 0.22, blue: 0.55).opacity(0.40),
                Color.clear
            ],
            backgroundTint: Color(red: 0.04, green: 0.08, blue: 0.25).opacity(0.14),
            cardTint: Color(red: 0.08, green: 0.18, blue: 0.45).opacity(0.08),
            sectionHeaderColor: Color(red: 0.45, green: 0.65, blue: 0.95)
        )

        static func current() -> TimeTheme {
            switch SunCalculator.currentPeriod() {
            case .earlyMorning: return .earlyMorning
            case .morning: return .morning
            case .midday: return .midday
            case .evening: return .evening
            case .night: return .night
            }
        }
    }

    // MARK: - Public API

    /// Get today's sunrise time
    static func sunrise(date: Date = Date()) -> Date? {
        calculateSunEvent(date: date, isSunrise: true)
    }

    /// Get today's sunset time
    static func sunset(date: Date = Date()) -> Date? {
        calculateSunEvent(date: date, isSunrise: false)
    }

    /// Determine current time period
    static func currentPeriod(date: Date = Date()) -> TimePeriod {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)

        guard let rise = sunrise(date: date), let set = sunset(date: date) else {
            // Fallback if calculation fails
            if hour < 6 { return .earlyMorning }
            if hour < 10 { return .morning }
            if hour < 16 { return .midday }
            if hour < 20 { return .evening }
            return .night
        }

        if date < rise { return .earlyMorning }
        if hour < 10 { return .morning }
        if hour < 16 { return .midday }
        if date < set { return .evening }
        return .night
    }

    /// Get contextual quick actions for the current time
    static func contextualActions() -> [(title: String, icon: String, id: String)] {
        switch currentPeriod() {
        case .earlyMorning:
            return [
                (title: "Rise & Shine", icon: "sunrise", id: "rise_and_shine"),
                (title: "Morning Lights", icon: "lightbulb", id: "morning"),
            ]
        case .morning:
            return [
                (title: "Rise & Shine", icon: "sunrise", id: "rise_and_shine"),
                (title: "All Lights Off", icon: "lightbulb.slash", id: "all_off"),
            ]
        case .midday:
            return [
                (title: "Block Out The Sun", icon: "sun.max.trianglebadge.exclamationmark", id: "block_sun"),
            ]
        case .evening:
            return [
                (title: "Evening", icon: "moon.fill", id: "evening"),
                (title: "Close Shades", icon: "blinds.vertical.closed", id: "shades_close"),
            ]
        case .night:
            return [
                (title: "Goodnight", icon: "moon.zzz", id: "goodnight"),
                (title: "All Lights Off", icon: "lightbulb.slash", id: "all_off"),
            ]
        }
    }

    // MARK: - Sun Position (azimuth + altitude)

    /// Current sun azimuth in degrees clockwise from true north (0=N, 90=E, 180=S, 270=W).
    static func sunAzimuth(date: Date = Date()) -> Double {
        sunPosition(date: date).azimuth
    }

    /// Current sun altitude in degrees above the horizon. Negative when the sun is below the horizon.
    static func sunAltitude(date: Date = Date()) -> Double {
        sunPosition(date: date).altitude
    }

    /// Returns true when the sun is currently shining through the west-facing windows.
    /// Trigger window: azimuth 200°–290° (SSW through WNW) and altitude ≥ 5°.
    static func isSunInWestWindow(date: Date = Date()) -> Bool {
        let pos = sunPosition(date: date)
        return pos.altitude >= 5 && pos.azimuth >= 200 && pos.azimuth <= 290
    }

    /// Raw (azimuth, altitude) for a given date using NOAA equations.
    static func sunPosition(date: Date = Date()) -> (azimuth: Double, altitude: Double) {
        let calendar = Calendar.current
        let dayOfYear = Double(calendar.ordinality(of: .day, in: .year, for: date) ?? 1)
        let utcHour = Double(Calendar(identifier: .gregorian).component(.hour, from: date))

        // Fractional year in radians (UTC noon referenced)
        let gamma = 2.0 * .pi / 365.0 * (dayOfYear - 1.0 + (utcHour - 12.0) / 24.0)

        // Equation of time (minutes)
        let eqtime = 229.18 * (0.000075
            + 0.001868 * cos(gamma)
            - 0.032077 * sin(gamma)
            - 0.014615 * cos(2 * gamma)
            - 0.040849 * sin(2 * gamma))

        // Solar declination (radians)
        let decl = 0.006918
            - 0.399912 * cos(gamma)
            + 0.070257 * sin(gamma)
            - 0.006758 * cos(2 * gamma)
            + 0.000907 * sin(2 * gamma)
            - 0.002697 * cos(3 * gamma)
            + 0.00148 * sin(3 * gamma)

        // UTC time in minutes
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(identifier: "UTC")!
        let utcMin = Double(utcCal.component(.hour, from: date)) * 60.0
            + Double(utcCal.component(.minute, from: date))
            + Double(utcCal.component(.second, from: date)) / 60.0

        // True solar time and hour angle
        let trueSolarMin = utcMin + eqtime + 4.0 * longitude
        let hourAngleDeg = trueSolarMin / 4.0 - 180.0
        let ha = hourAngleDeg * .pi / 180.0

        let latRad = latitude * .pi / 180.0

        // Altitude
        let sinAlt = sin(latRad) * sin(decl) + cos(latRad) * cos(decl) * cos(ha)
        let altRad = asin(max(-1.0, min(1.0, sinAlt)))
        let altitude = altRad * 180.0 / .pi

        // Azimuth (clockwise from north) via atan2
        let cosAlt = cos(altRad)
        guard cosAlt > 1e-10 else { return (azimuth: 0, altitude: altitude) }

        let sinAz = (-cos(decl) * sin(ha)) / cosAlt
        let cosAz = (sin(decl) - sin(latRad) * sinAlt) / (cos(latRad) * cosAlt)
        let rawAz = atan2(sinAz, cosAz) * 180.0 / .pi
        let azimuth = (rawAz + 360.0).truncatingRemainder(dividingBy: 360.0)

        return (azimuth: azimuth, altitude: altitude)
    }

    // MARK: - NOAA Solar Calculation

    private static func calculateSunEvent(date: Date, isSunrise: Bool) -> Date? {
        let calendar = Calendar.current
        let dayOfYear = Double(calendar.ordinality(of: .day, in: .year, for: date) ?? 1)
        _ = calendar.component(.year, from: date)

        // Time zone offset in hours
        let tzOffset = Double(TimeZone.current.secondsFromGMT(for: date)) / 3600.0

        let lat = latitude
        let lng = longitude

        // Fractional year (gamma) in radians
        let gamma = 2.0 * .pi / 365.0 * (dayOfYear - 1.0 + (12.0 - 12.0) / 24.0)

        // Equation of time (minutes)
        let eqtime = 229.18 * (0.000075
            + 0.001868 * cos(gamma)
            - 0.032077 * sin(gamma)
            - 0.014615 * cos(2 * gamma)
            - 0.040849 * sin(2 * gamma))

        // Solar declination (radians)
        let decl = 0.006918
            - 0.399912 * cos(gamma)
            + 0.070257 * sin(gamma)
            - 0.006758 * cos(2 * gamma)
            + 0.000907 * sin(2 * gamma)
            - 0.002697 * cos(3 * gamma)
            + 0.00148 * sin(3 * gamma)

        // Hour angle for sunrise/sunset (degrees)
        let latRad = lat * .pi / 180.0
        let zenith = 90.833 * .pi / 180.0 // Official sunrise/sunset

        let cosHA = (cos(zenith) / (cos(latRad) * cos(decl))) - tan(latRad) * tan(decl)

        // Check for polar day/night
        guard cosHA >= -1.0 && cosHA <= 1.0 else { return nil }

        var ha = acos(cosHA) * 180.0 / .pi // degrees

        if isSunrise {
            ha = -ha
        }

        // Solar noon (minutes from midnight UTC)
        let solarNoon = 720.0 - 4.0 * lng - eqtime

        // Sunrise/sunset time in minutes from midnight UTC
        let timeUTC = solarNoon + ha * 4.0

        // Convert to local time
        let timeLocal = timeUTC + tzOffset * 60.0

        // Build date
        let hours = Int(timeLocal / 60.0)
        let minutes = Int(timeLocal.truncatingRemainder(dividingBy: 60.0))

        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = hours
        components.minute = minutes
        components.second = 0

        return calendar.date(from: components)
    }
}
