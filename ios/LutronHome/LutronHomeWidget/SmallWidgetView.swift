import SwiftUI
import WidgetKit
import AppIntents

struct SmallWidgetView: View {
    let entry: LutronWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("LUTRON HOME")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
                Spacer()
                Link(destination: URL(string: "lutronhome://voice")!) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            // Action 1
            if let first = entry.suggestions.first {
                actionButton(first)
            }

            // Divider
            Rectangle()
                .fill(.quaternary)
                .frame(height: 0.5)
                .padding(.vertical, 6)

            // Action 2
            if entry.suggestions.count > 1 {
                actionButton(entry.suggestions[1])
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
        } else if let level = action.level {
            Button(intent: SetDeviceLevelIntent(deviceName: action.label, level: Int(level))) {
                actionLabel(action)
            }
            .buttonStyle(.plain)
        } else {
            actionLabel(action)
        }
    }

    private func actionLabel(_ action: SuggestedAction) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(action.label)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary.opacity(0.92))
                .lineLimit(1)
            Text(action.subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.primary.opacity(0.35))
                .lineLimit(1)
        }
    }
}
