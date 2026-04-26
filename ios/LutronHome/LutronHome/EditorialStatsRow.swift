import SwiftUI

struct EditorialStatsRow: View {
    @Environment(MyUplinkManager.self) var myUplink
    @Environment(LutronStore.self) var store
    @Environment(EcobeeManager.self) var ecobee
    @Environment(WeatherManager.self) var weather

    var body: some View {
        HStack(spacing: 0) {
            statCell(
                icon: weather.conditionIcon,
                label: outsideLabel,
                value: outsideValue
            )
            statCell(
                icon: sunEventIcon,
                label: sunEventLabel,
                value: sunEventValue
            )
            statCell(
                icon: "circle.grid.2x2",
                label: roomsLabel,
                value: roomsValue
            )
            statCell(
                icon: "thermometer.medium",
                label: "INSIDE",
                value: insideValue
            )
        }
        .padding(.vertical, 8)
        .overlay(
            Rectangle()
                .fill(EditorialTheme.cardBorder)
                .frame(height: 0.5),
            alignment: .top
        )
        .overlay(
            Rectangle()
                .fill(EditorialTheme.cardBorder)
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    private func statCell(icon: String, label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 8))
                Text(label)
                    .font(.system(size: 8, weight: .medium))
                    .tracking(0.6)
            }
            .foregroundStyle(EditorialTheme.secondaryText)

            Text(value)
                .font(EditorialTheme.monoValue(size: 18))
                .foregroundStyle(EditorialTheme.primaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Data

    private var outsideLabel: String {
        if let _ = myUplink.heatPump.outdoorTemp {
            return myUplink.heatPump.connected ? "CLEAR" : "OUTSIDE"
        }
        return weather.conditionLabel
    }

    private var outsideValue: String {
        // Prefer MyUplink heat pump outdoor temp
        if let temp = myUplink.heatPump.outdoorTemp {
            return "\(Int(temp))°"
        }
        // Fall back to WeatherKit
        if let temp = weather.currentTemp {
            return "\(Int(temp))°"
        }
        return "—"
    }

    private var sunEventIcon: String {
        let period = SunCalculator.currentPeriod()
        return (period == .night || period == .evening) ? "sunset" : "sunrise"
    }

    private var sunEventLabel: String {
        let period = SunCalculator.currentPeriod()
        return (period == .night || period == .evening) ? "SUNSET" : "SUNRISE"
    }

    private var sunEventValue: String {
        let period = SunCalculator.currentPeriod()
        let date: Date?
        if period == .night || period == .evening {
            date = SunCalculator.sunset()
        } else {
            date = SunCalculator.sunrise()
        }
        guard let d = date else { return "—" }
        let f = DateFormatter()
        f.dateFormat = "h:mma"
        f.amSymbol = "A"
        f.pmSymbol = "P"
        return f.string(from: d)
    }

    private var roomsLabel: String {
        let total = Set(store.devices.values.filter { $0.category == .light }.map(\.room)).count
        return "\(total) RMS"
    }

    private var roomsValue: String {
        let on = store.lightsOn.count
        let total = store.devices.values.filter { $0.category == .light }.count
        return "\(on)/\(total)"
    }

    private var insideValue: String {
        if let thermo = ecobee.thermostats.first {
            return "\(Int(thermo.currentTemp))°"
        }
        return "—"
    }
}
