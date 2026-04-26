import SwiftUI

private enum DragIntent { case undecided, adjusting, scrolling }

struct DimmablePill: View {
    @Environment(LutronStore.self) var store
    let device: DeviceState
    var fadeTime: Double? = nil

    @State private var dragIntent: DragIntent = .undecided
    @State private var isDragging = false
    @State private var dragLevel: Double = 0
    @State private var lastSentLevel: Double = -1
    @State private var lastSendTime: Date = .distantPast

    private var displayLevel: Double { isDragging ? dragLevel : device.level }
    private var isOn: Bool { displayLevel > 0 }

    private func sendIfNeeded(_ level: Double) {
        let snapped = (level / 5).rounded() * 5
        let now = Date()
        guard abs(snapped - lastSentLevel) >= 5,
              now.timeIntervalSince(lastSendTime) >= 0.1 else { return }
        lastSentLevel = snapped
        lastSendTime = now
        store.setLevel(device.integrationId, level: snapped, fadeTime: fadeTime ?? 0)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Background
                Rectangle()
                    .fill(EditorialTheme.cardBackground)

                // Fill bar from left edge to current level
                Rectangle()
                    .fill(EditorialTheme.accent.opacity(0.15))
                    .frame(width: geo.size.width * (displayLevel / 100))
                    .animation(isDragging ? nil : .easeOut(duration: 0.15), value: displayLevel)

                // Vertical line at current level position
                Rectangle()
                    .fill(EditorialTheme.accent)
                    .frame(width: 2)
                    .offset(x: geo.size.width * (displayLevel / 100) - 1)
                    .animation(isDragging ? nil : .easeOut(duration: 0.15), value: displayLevel)

                // Border
                Rectangle()
                    .stroke(EditorialTheme.cardBorder, lineWidth: 0.5)

                // Content — name left-aligned, percentage right-aligned
                HStack(spacing: 6) {
                    Text(device.name.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(EditorialTheme.primaryText)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Text("\(Int(displayLevel))%")
                        .font(EditorialTheme.monoValue(size: 12))
                        .foregroundStyle(isOn ? EditorialTheme.accent : EditorialTheme.secondaryText)
                }
                .padding(.horizontal, 10)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                let newLevel: Double = device.level > 0 ? 0 : 100
                store.setLevel(device.integrationId, level: newLevel, fadeTime: fadeTime ?? 1)
            }
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        if dragIntent == .undecided {
                            let h = abs(value.translation.width)
                            let v = abs(value.translation.height)
                            if h > v * 1.5 { dragIntent = .adjusting }
                            else if v > h * 1.5 { dragIntent = .scrolling }
                        }
                        guard dragIntent == .adjusting else { return }
                        if !isDragging {
                            isDragging = true
                            dragLevel = device.level
                            lastSentLevel = device.level
                        }
                        let pct = max(0, min(100, (value.location.x / geo.size.width) * 100))
                        dragLevel = pct
                        sendIfNeeded(pct)
                    }
                    .onEnded { value in
                        if dragIntent == .adjusting && isDragging {
                            let pct = max(0, min(100, (value.location.x / geo.size.width) * 100))
                            let snapped = (pct / 5).rounded() * 5
                            store.setLevel(device.integrationId, level: snapped, fadeTime: fadeTime ?? 0)
                        }
                        dragIntent = .undecided
                        isDragging = false
                    }
            )
        }
        .frame(height: 40)
    }
}

// MARK: - Lights Section (Homepage)

struct EditorialLightsSection: View {
    @Environment(LutronStore.self) var store

    var body: some View {
        let lights = store.lightsOn
        if !lights.isEmpty {
            VStack(alignment: .leading, spacing: EditorialTheme.gridSpacing) {
                EditorialSectionHeader(
                    title: "LIGHTS ON",
                    trailing: "\(lights.count) ACTIVE"
                )

                let byRoom = Dictionary(grouping: lights, by: \.room)
                let sortedRooms = byRoom.keys.sorted()

                ForEach(sortedRooms, id: \.self) { room in
                    let roomLights = byRoom[room]!
                    VStack(alignment: .leading, spacing: 6) {
                        Text(room.uppercased())
                            .font(.system(size: 9, weight: .medium))
                            .tracking(0.8)
                            .foregroundStyle(EditorialTheme.secondaryText)

                        ForEach(roomLights) { device in
                            DimmablePill(device: device)
                        }
                    }
                }
            }
        }
    }
}
