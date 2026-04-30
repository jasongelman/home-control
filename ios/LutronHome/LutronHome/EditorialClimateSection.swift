import SwiftUI

struct EditorialClimateSection: View {
    @Environment(EcobeeManager.self) var ecobee
    @State private var selectedThermostat: EcobeeThermostat?

    var body: some View {
        if ecobee.hasThermostats {
            VStack(alignment: .leading, spacing: 10) {
                EditorialSectionHeader(
                    title: "CLIMATE",
                    trailing: "\(ecobee.thermostats.count) ZONES"
                )

                HStack(spacing: EditorialTheme.gridSpacing) {
                    ForEach(ecobee.thermostats, id: \.identifier) { thermo in
                        Button { selectedThermostat = thermo } label: {
                            compactClimateCard(thermo)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .sheet(item: $selectedThermostat) { thermo in
                ThermostatDetailView(thermostat: thermo, manager: ecobee)
            }
        }
    }

    private func compactClimateCard(_ thermo: EcobeeThermostat) -> some View {
        HStack(spacing: 0) {
            // Accent bar
            RoundedRectangle(cornerRadius: 2)
                .fill(accentColor(for: thermo))
                .frame(width: 3)
                .padding(.vertical, 6)
                .padding(.leading, 4)

            VStack(alignment: .leading, spacing: 2) {
                // Zone name
                Text(thermo.displayName.uppercased())
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(EditorialTheme.secondaryText)
                    .lineLimit(1)

                // Current temp → target
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(Int(thermo.currentTemp))°")
                        .font(EditorialTheme.monoValue(size: 22))
                        .foregroundStyle(EditorialTheme.primaryText)

                    Text("→\(Int(setpoint(thermo)))°")
                        .font(EditorialTheme.monoValue(size: 10, weight: .medium))
                        .foregroundStyle(EditorialTheme.secondaryText)
                }

                // Mode + humidity
                HStack(spacing: 3) {
                    if thermo.hvacMode == .heat || thermo.hvacMode == .auto {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 6, weight: .bold))
                            .foregroundStyle(EditorialTheme.heating)
                    } else if thermo.hvacMode == .cool {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 6, weight: .bold))
                            .foregroundStyle(EditorialTheme.cooling)
                    }
                    Text("\(thermo.hvacMode.label.uppercased()) · \(thermo.humidity ?? 0)%")
                        .font(.system(size: 7, weight: .medium))
                        .tracking(0.3)
                        .foregroundStyle(EditorialTheme.secondaryText)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .editorialCard(padding: 0)
    }

    private func setpoint(_ thermo: EcobeeThermostat) -> Double {
        switch thermo.hvacMode {
        case .heat: return thermo.desiredHeat
        case .cool: return thermo.desiredCool
        case .auto: return thermo.desiredHeat
        case .off: return thermo.currentTemp
        }
    }

    private func accentColor(for thermo: EcobeeThermostat) -> Color {
        switch thermo.hvacMode {
        case .heat: return EditorialTheme.heating
        case .cool: return EditorialTheme.cooling
        case .auto:
            if thermo.currentTemp < thermo.desiredHeat { return EditorialTheme.heating }
            if thermo.currentTemp > thermo.desiredCool { return EditorialTheme.cooling }
            return EditorialTheme.idle
        case .off: return EditorialTheme.idle
        }
    }
}
