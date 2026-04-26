import SwiftUI

struct EditorialShadesSection: View {
    @Environment(LutronStore.self) var store

    var body: some View {
        let shadeRooms = self.shadeRooms
        if !shadeRooms.isEmpty {
            VStack(alignment: .leading, spacing: EditorialTheme.gridSpacing) {
                EditorialSectionHeader(
                    title: "SHADES",
                    trailing: "\(shadeRooms.flatMap(\.shades).count) DEVICES"
                )

                ForEach(shadeRooms, id: \.name) { room in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(room.name.uppercased())
                            .font(.system(size: 9, weight: .medium))
                            .tracking(0.8)
                            .foregroundStyle(EditorialTheme.secondaryText)

                        ForEach(room.shades) { shade in
                            DimmablePill(device: shade, fadeTime: 2)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Data

    private struct ShadeRoom {
        let name: String
        let shades: [DeviceState]
    }

    private var shadeRooms: [ShadeRoom] {
        let shadeDevices = store.devices.values.filter { $0.category == .shadesAndDrapes }
        let grouped = Dictionary(grouping: shadeDevices, by: \.room)
        return grouped.map { ShadeRoom(name: $0.key, shades: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.name < $1.name }
    }
}
