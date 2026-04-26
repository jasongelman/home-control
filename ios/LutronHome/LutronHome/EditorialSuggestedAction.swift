import SwiftUI

struct EditorialSuggestedAction: View {
    @Environment(LutronStore.self) var store

    private let actions = SunCalculator.contextualActions()

    var body: some View {
        if let action = actions.first {
            Button {
                handleAction(action.id)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SUGGESTED · TAP TO RUN")
                        .font(.system(size: 8, weight: .medium))
                        .tracking(0.8)
                        .foregroundStyle(.white.opacity(0.7))

                    HStack {
                        Text(action.title.uppercased())
                            .font(EditorialTheme.bebasNeue(size: 36))
                            .foregroundStyle(.white)
                        Spacer()
                        Image(systemName: "arrow.right")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                    Text(actionSubtitle(action.id))
                        .font(.system(size: 9, weight: .medium))
                        .tracking(0.6)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: EditorialTheme.cardRadius)
                        .fill(EditorialTheme.accent)
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func actionSubtitle(_ id: String) -> String {
        switch id {
        case "evening":
            let lightCount = store.devices.values.filter { $0.category == .light && $0.level > 0 }.count
            return "\(lightCount) LIGHTS · SHADES ▼ · WARM DIM"
        case "morning":
            return "KITCHEN · FAMILY ROOM · BRIGHT"
        case "shades_open":
            return "DINING · FAMILY ROOM · FULL OPEN"
        case "shades_close":
            return "DINING · FAMILY ROOM · FULL CLOSE"
        case "all_off":
            let lightCount = store.devices.values.filter { $0.category == .light && $0.level > 0 }.count
            return "\(lightCount) LIGHTS OFF · EXCEPT SEBASTIAN"
        case "goodnight":
            return "ALL LIGHTS OFF · EXCEPT SEBASTIAN"
        case "rise_and_shine":
            return "ALL DOWNSTAIRS SHADES · FULL OPEN"
        case "block_sun":
            return "FAMILY REAR · DINING · JASON OFFICE SOLAR"
        default:
            return ""
        }
    }

    private func handleAction(_ id: String) {
        switch id {
        case "morning":
            store.setRoomLights("Kitchen", level: 60)
            store.setRoomLights("Family Room", level: 40)
        case "shades_open", "shades_close":
            store.toggleMainShades()
        case "all_off":
            store.turnOffAllLights(excludingNames: ["Bed 2 Entry"])
        case "evening":
            store.activateEveningScene()
        case "goodnight":
            store.turnOffAllLights(excludingRooms: ["Sebastian's Room"])
        case "rise_and_shine":
            store.raiseDownstairsShades()
        case "block_sun":
            store.blockOutTheSun()
        default:
            break
        }
    }
}
