import SwiftUI

struct EditorialTopBar: View {
    @Environment(LutronStore.self) var store
    var onTalkToMe: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            // Left: HOME · N°40.93 with connection dot
            HStack(spacing: 6) {
                Circle()
                    .fill(connectionColor)
                    .frame(width: 6, height: 6)
                Text("HOME · N°\(String(format: "%.2f", SunCalculator.latitude))")
                    .font(.system(size: 10, weight: .medium))
                    .tracking(1.0)
                    .textCase(.uppercase)
                    .foregroundStyle(EditorialTheme.secondaryText)
            }

            Spacer()

            // Center-right: date
            Text(dateString)
                .font(.system(size: 10, weight: .medium))
                .tracking(1.0)
                .textCase(.uppercase)
                .foregroundStyle(EditorialTheme.secondaryText)

            Spacer()

            // Right: talk to me + settings gear
            HStack(spacing: 12) {
                Button(action: onTalkToMe) {
                    Text("TALK TO ME")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(EditorialTheme.accent)
                }
                .buttonStyle(.plain)

                NavigationLink(destination: SettingsView()) {
                    Image(systemName: "gear")
                        .font(.system(size: 13))
                        .foregroundStyle(EditorialTheme.tertiaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 4)
    }

    private var connectionColor: Color {
        store.isConnected ? .green : .red
    }

    private var dateString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE MMM d"
        return formatter.string(from: Date()).uppercased()
    }
}
