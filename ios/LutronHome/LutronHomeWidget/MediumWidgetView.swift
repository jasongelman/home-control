import SwiftUI
import WidgetKit
import AppIntents

struct MediumWidgetView: View {
    let entry: LutronWidgetEntry

    private var statusText: String {
        let count = entry.lightsOnCount
        return count == 0 ? "All off" : "\(count) light\(count == 1 ? "" : "s") on"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(alignment: .firstTextBaseline) {
                Text("LUTRON HOME")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
                Text(statusText)
                    .font(.system(size: 10))
                    .foregroundStyle(.primary.opacity(0.3))
                Spacer()
                Link(destination: URL(string: "lutronhome://voice")!) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            // Bottom row: actions + optional appliance + all off
            HStack(alignment: .bottom, spacing: 0) {
                // Slot 1
                if let first = entry.suggestions.first {
                    actionButton(first)
                    divider()
                }

                // Slot 2
                if entry.suggestions.count > 1 {
                    actionButton(entry.suggestions[1])
                    divider()
                }

                // Slot 3: appliance override or 3rd recommendation
                if let appliance = entry.activeAppliance {
                    applianceSlot(appliance)
                } else if entry.suggestions.count > 2 {
                    actionButton(entry.suggestions[2])
                }

                divider()

                // All Off button
                Button(intent: AllLightsOffIntent()) {
                    VStack(spacing: 3) {
                        Image(systemName: "lightbulb.slash")
                            .font(.system(size: 14))
                        Text("All Off")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundStyle(.primary.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private func actionButton(_ action: SuggestedAction) -> some View {
        if action.type == .scene {
            Button(intent: ActivateSceneIntent(sceneName: action.label)) {
                actionLabel(action)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let level = action.level {
            Button(intent: SetDeviceLevelIntent(deviceName: action.label, level: Int(level))) {
                actionLabel(action)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            actionLabel(action)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func actionLabel(_ action: SuggestedAction) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(action.label)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary.opacity(0.92))
                .lineLimit(1)
            Text(action.subtitle)
                .font(.system(size: 10))
                .foregroundStyle(.primary.opacity(0.35))
                .lineLimit(1)
        }
    }

    private func applianceSlot(_ appliance: AppGroupManager.ApplianceInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(appliance.name)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary.opacity(0.55))
                .lineLimit(1)
            Text("\(appliance.remainingMinutes) min left")
                .font(.system(size: 10))
                .foregroundStyle(.primary.opacity(0.3))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func divider() -> some View {
        Rectangle()
            .fill(.quaternary)
            .frame(width: 0.5, height: 30)
            .padding(.horizontal, 6)
    }
}
