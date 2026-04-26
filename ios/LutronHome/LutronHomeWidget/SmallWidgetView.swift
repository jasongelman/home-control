import SwiftUI
import WidgetKit
import AppIntents

struct SmallWidgetView: View {
    let entry: LutronWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("LUTRON HOME")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Color.black)
                Spacer()
                Link(destination: URL(string: "lutronhome://voice")!) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(WidgetTheme.accent)
                }
            }

            // Thin accent rule
            Rectangle()
                .fill(WidgetTheme.accent)
                .frame(height: 1.5)
                .padding(.top, 6)

            Spacer()

            // Action 1
            if let first = entry.suggestions.first {
                actionButton(first)
            }

            // Divider
            Rectangle()
                .fill(WidgetTheme.border)
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
            Text(action.label.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Color.black)
                .lineLimit(1)
            Text(action.subtitle)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(WidgetTheme.secondaryText)
                .lineLimit(1)
        }
    }
}
