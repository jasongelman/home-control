import SwiftUI
import UIKit

// MARK: - Horizontal Adjust Gesture
//
// Drag-to-dim rows live inside vertical ScrollViews. A SwiftUI DragGesture claims the
// touch before the scroll view can, so a vertical swipe with a little sideways drift
// changed light levels. This UIKit pan only *begins* when the motion is clearly
// horizontal, and the enclosing scroll view's pan is made to wait for it to fail —
// so vertical swipes always scroll and never touch a light.

struct HorizontalAdjustGesture: UIGestureRecognizerRepresentable {
    /// Called with the touch's x position in the view's local space while adjusting.
    var onChanged: (CGFloat) -> Void
    var onEnded: (CGFloat) -> Void
    var onCancelled: () -> Void = {}

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let x = context.converter.localLocation.x
        switch recognizer.state {
        case .began, .changed: onChanged(x)
        case .ended: onEnded(x)
        case .cancelled, .failed: onCancelled()
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let t = pan.translation(in: pan.view)
            return abs(t.x) > abs(t.y) * 2
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other is UIPanGestureRecognizer && other.view is UIScrollView
        }
    }
}

struct DimmablePill: View {
    @Environment(LutronStore.self) var store
    let device: DeviceState
    var fadeTime: Double? = nil
    var dimsWhenOff: Bool = false

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
        store.setLevel(device.integrationId, level: snapped, fadeTime: fadeTime ?? 0, track: false)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(EditorialTheme.cardBackground)

                Rectangle()
                    .fill(EditorialTheme.accent.opacity(0.15))
                    .frame(width: geo.size.width * (displayLevel / 100))
                    .animation(isDragging ? nil : .easeOut(duration: 0.15), value: displayLevel)

                // Marker as top/bottom gauge ticks so it never strikes through the label
                VStack(spacing: 0) {
                    Rectangle().fill(EditorialTheme.accent).frame(width: 2, height: 11)
                    Spacer(minLength: 0)
                    Rectangle().fill(EditorialTheme.accent).frame(width: 2, height: 11)
                }
                .offset(x: geo.size.width * (displayLevel / 100) - 1)
                .animation(isDragging ? nil : .easeOut(duration: 0.15), value: displayLevel)

                Rectangle()
                    .stroke(EditorialTheme.cardBorder, lineWidth: 0.5)

                HStack(spacing: 6) {
                    Text(deviceDisplayName(device).uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle((dimsWhenOff && !isOn) ? EditorialTheme.tertiaryText : EditorialTheme.primaryText)
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
            .gesture(HorizontalAdjustGesture(
                onChanged: { x in
                    if !isDragging {
                        isDragging = true
                        dragLevel = device.level
                        lastSentLevel = device.level
                    }
                    let pct = max(0, min(100, (x / geo.size.width) * 100))
                    dragLevel = pct
                    sendIfNeeded(pct)
                },
                onEnded: { x in
                    if isDragging {
                        let pct = max(0, min(100, (x / geo.size.width) * 100))
                        let snapped = (pct / 5).rounded() * 5
                        store.setLevel(device.integrationId, level: snapped, fadeTime: fadeTime ?? 0)
                    }
                    isDragging = false
                },
                onCancelled: { isDragging = false }
            ))
        }
        .frame(height: 40)
    }
}

// MARK: - Room Card (one bordered card per room so it's obvious which room a control belongs to)

struct RoomCard<Actions: View, Content: View>: View {
    let name: String
    let activeCount: Int
    let total: Int
    var activeLabel: String = "ON"
    /// Tapping the room name (e.g. collapse on the Lights tab). Nil = not tappable.
    var onHeaderTap: (() -> Void)? = nil
    /// Shows a trailing chevron that opens the room detail page.
    var onOpenDetail: (() -> Void)? = nil
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var content: () -> Content

    private var isActive: Bool { activeCount > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Button { onHeaderTap?() } label: {
                    HStack(spacing: 5) {
                        if onHeaderTap != nil {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(EditorialTheme.secondaryText)
                        }
                        Text(roomIcon(for: name))
                            .font(.system(size: 14))
                        Text(name.uppercased())
                            .font(.system(size: 11, weight: .bold))
                            .tracking(0.2)
                            .foregroundStyle(EditorialTheme.primaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                }
                .buttonStyle(.plain)
                .disabled(onHeaderTap == nil)
                .layoutPriority(1)

                Spacer(minLength: 2)

                // Full "2/4 ON" when the card is wide (Shades tab); "2/4" in half-width cards.
                ViewThatFits(in: .horizontal) {
                    statusText(isActive ? "\(activeCount)/\(total) \(activeLabel)" : "OFF")
                    statusText(isActive ? "\(activeCount)/\(total)" : "OFF")
                }

                actions()

                if let onOpenDetail {
                    Button(action: onOpenDetail) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(EditorialTheme.tertiaryText)
                            .frame(width: 18, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            content()
        }
        .padding(8)
        .background(EditorialTheme.background)
        .overlay(alignment: .leading) {
            if isActive {
                Rectangle().fill(EditorialTheme.accent).frame(width: 3)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: EditorialTheme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: EditorialTheme.cardRadius)
                // Inactive rooms still get a clearly visible outline (cardBorder is near-invisible on white)
                .stroke(isActive ? EditorialTheme.accent.opacity(0.45) : Color(UIColor.systemGray3),
                        lineWidth: 1)
        )
    }
}

extension RoomCard {
    fileprivate func statusText(_ text: String) -> some View {
        Text(text)
            .font(EditorialTheme.monoValue(size: 9))
            .foregroundStyle(activeCount > 0 ? EditorialTheme.accent : EditorialTheme.tertiaryText)
            .lineLimit(1)
            .fixedSize()
    }
}

extension RoomCard where Actions == EmptyView {
    init(name: String, activeCount: Int, total: Int, activeLabel: String = "ON",
         onHeaderTap: (() -> Void)? = nil, onOpenDetail: (() -> Void)? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(name: name, activeCount: activeCount, total: total, activeLabel: activeLabel,
                  onHeaderTap: onHeaderTap, onOpenDetail: onOpenDetail,
                  actions: { EmptyView() }, content: content)
    }
}

/// Device name without a redundant room prefix ("Kitchen Island" inside the Kitchen card → "Island").
func deviceDisplayName(_ device: DeviceState) -> String {
    let name = device.name
    guard !device.room.isEmpty, name.lowercased().hasPrefix(device.room.lowercased()) else { return name }
    let stripped = name.dropFirst(device.room.count).trimmingCharacters(in: .whitespaces)
    return stripped.isEmpty ? name : stripped
}

// MARK: - Shade Preset Row (Close / 25 / 50 / 75 / Open — no granular slider)

struct ShadePresetRow: View {
    @Environment(LutronStore.self) var store
    /// Shades this row drives. One shade = per-device row; several = room-wide "ALL" row.
    let shades: [DeviceState]
    let label: String

    private static let presets: [Double] = [0, 25, 50, 75, 100]

    private var level: Double {
        guard !shades.isEmpty else { return 0 }
        return shades.reduce(0.0) { $0 + $1.level } / Double(shades.count)
    }

    private var levelText: String {
        let l = Int(level.rounded())
        return l == 0 ? "CLOSED" : l == 100 ? "OPEN" : "\(l)%"
    }

    private func isSelected(_ preset: Double) -> Bool {
        shades.allSatisfy { abs($0.level - preset) <= 2 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(EditorialTheme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(levelText)
                    .font(EditorialTheme.monoValue(size: 10))
                    .foregroundStyle(level > 0 ? EditorialTheme.accent : EditorialTheme.secondaryText)
            }

            HStack(spacing: 4) {
                ForEach(Self.presets, id: \.self) { preset in
                    let selected = isSelected(preset)
                    Button {
                        for shade in shades {
                            store.setLevel(shade.integrationId, level: preset, fadeTime: 2)
                        }
                    } label: {
                        Text(preset == 0 ? "CLOSE" : preset == 100 ? "OPEN" : "\(Int(preset))%")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.4)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity)
                            .frame(height: 34)
                            .background(selected ? EditorialTheme.accent : EditorialTheme.cardBackground)
                            .foregroundStyle(selected ? Color.white : EditorialTheme.primaryText)
                            .overlay(
                                Rectangle().stroke(EditorialTheme.cardBorder, lineWidth: 0.5)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Room Group Slider (collapsed-room control: drag the row to set every light in the room together)

struct RoomGroupSlider: View {
    @Environment(LutronStore.self) var store
    let room: (name: String, devices: [DeviceState])
    let icon: String
    let summary: String
    let onTap: () -> Void

    @State private var isDragging = false
    @State private var dragLevel: Double = 0
    @State private var lastSentLevel: Double = -1
    @State private var lastSendTime: Date = .distantPast

    private var avgLevel: Double {
        guard !room.devices.isEmpty else { return 0 }
        return room.devices.reduce(0.0) { $0 + $1.level } / Double(room.devices.count)
    }

    private var displayLevel: Double { isDragging ? dragLevel : avgLevel }
    private var isOn: Bool { displayLevel > 0 }
    private var isShade: Bool {
        room.devices.contains { $0.category == .shadesAndDrapes || $0.category == .window }
    }
    private var fadeTime: Double { isShade ? 2.0 : 0.0 }

    private func sendIfNeeded(_ level: Double) {
        let snapped = (level / 5).rounded() * 5
        let now = Date()
        guard abs(snapped - lastSentLevel) >= 5,
              now.timeIntervalSince(lastSendTime) >= 0.1 else { return }
        lastSentLevel = snapped
        lastSendTime = now
        for device in room.devices {
            store.setLevel(device.integrationId, level: snapped, fadeTime: fadeTime, track: false)
        }
    }

    private func commit(_ level: Double) {
        let snapped = (level / 5).rounded() * 5
        for device in room.devices {
            store.setLevel(device.integrationId, level: snapped, fadeTime: fadeTime)
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(EditorialTheme.cardBackground)

                Rectangle()
                    .fill(EditorialTheme.accent.opacity(0.15))
                    .frame(width: geo.size.width * (displayLevel / 100))
                    .animation(isDragging ? nil : .easeOut(duration: 0.15), value: displayLevel)

                VStack(spacing: 0) {
                    Rectangle().fill(EditorialTheme.accent).frame(width: 1.5, height: 8)
                    Spacer(minLength: 0)
                    Rectangle().fill(EditorialTheme.accent).frame(width: 1.5, height: 8)
                }
                .offset(x: geo.size.width * (displayLevel / 100) - 0.75)
                .animation(isDragging ? nil : .easeOut(duration: 0.15), value: displayLevel)

                Rectangle()
                    .stroke(EditorialTheme.cardBorder, lineWidth: 0.5)

                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(EditorialTheme.secondaryText)
                    Text(icon)
                        .font(.system(size: 13))
                    Text(room.name.uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(isOn ? EditorialTheme.primaryText : EditorialTheme.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if !summary.isEmpty {
                        Text(summary)
                            .font(EditorialTheme.monoValue(size: 9))
                            .tracking(0.6)
                            .foregroundStyle(EditorialTheme.tertiaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if isOn {
                        Text("\(Int(displayLevel))%")
                            .font(EditorialTheme.monoValue(size: 10))
                            .foregroundStyle(EditorialTheme.accent)
                    }
                }
                .padding(.horizontal, 8)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .gesture(HorizontalAdjustGesture(
                onChanged: { x in
                    if !isDragging {
                        isDragging = true
                        dragLevel = avgLevel
                        lastSentLevel = avgLevel
                    }
                    let pct = max(0, min(100, (x / geo.size.width) * 100))
                    dragLevel = pct
                    sendIfNeeded(pct)
                },
                onEnded: { x in
                    if isDragging {
                        commit(max(0, min(100, (x / geo.size.width) * 100)))
                    }
                    isDragging = false
                },
                onCancelled: { isDragging = false }
            ))
        }
        .frame(height: 38)
    }
}

// MARK: - Color Keypad Pill (colored circle buttons)

struct ColorKeypadPill: View {
    @Environment(LutronStore.self) var store
    let entry: LutronStore.ColorKeypadEntry

    private static let colorMap: [String: Color] = [
        "white": .white,
        "blue": .blue,
        "red": .red,
        "green": .green,
        "purple": .purple,
        "pink": .pink,
        "aqua": .cyan,
        "yellow": .yellow,
        "orange": .orange,
    ]

    var body: some View {
        let colorButtons = entry.buttons.filter { !$0.isOff }
        let offBtn = entry.buttons.first(where: { $0.isOff })
        HStack(spacing: 2) {
            ForEach(colorButtons) { btn in
                let isActive = entry.activeButtonId == btn.id
                let color = Self.colorMap[btn.engraving.lowercased()] ?? .gray
                Button {
                    store.pressKeypadButton(btn.id)
                    if let i = store.colorKeypads.firstIndex(where: { $0.id == entry.id }) {
                        store.colorKeypads[i].activeButtonId = btn.id
                    }
                } label: {
                    Rectangle()
                        .fill(color)
                        .overlay(
                            Rectangle()
                                .stroke(isActive ? EditorialTheme.accent : Color.clear, lineWidth: 2.5)
                        )
                        .overlay(
                            Rectangle()
                                .stroke(btn.engraving.lowercased() == "white" ? EditorialTheme.cardBorder : Color.clear, lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
            }

            if let offBtn {
                Button {
                    store.pressKeypadButton(offBtn.id)
                    if let i = store.colorKeypads.firstIndex(where: { $0.id == entry.id }) {
                        store.colorKeypads[i].activeButtonId = nil
                    }
                } label: {
                    Rectangle()
                        .fill(EditorialTheme.cardBackground)
                        .overlay(
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(EditorialTheme.secondaryText)
                        )
                        .overlay(
                            Rectangle()
                                .stroke(EditorialTheme.cardBorder, lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 40)
    }
}

// MARK: - Lights Section (Homepage)

struct EditorialLightsSection: View {
    @Environment(LutronStore.self) var store
    @Environment(\.scenePhase) private var scenePhase

    /// Lights currently shown, including recently turned-off ones that linger until
    /// the settle timer compacts the section. `nil` = unseeded (section empty/hidden).
    @State private var displayedIds: Set<Int>? = nil
    /// Sticky column assignment per room: rooms never hop columns while on screen.
    @State private var roomColumn: [String: Int] = [:]
    @State private var settleTask: Task<Void, Never>? = nil

    private static let settleDelay: Duration = .seconds(2.5)

    var body: some View {
        let allLights = store.devices.values.filter { $0.category == .light }
        let onIds = Set(store.lightsOn.map(\.integrationId))
        let effectiveIds = (displayedIds ?? onIds).union(onIds)
        let displayed = allLights
            .filter { effectiveIds.contains($0.integrationId) }
            .sorted { ($0.room, $0.name) < ($1.room, $1.name) }
        let levelsById = Dictionary(uniqueKeysWithValues: allLights.map { ($0.integrationId, $0.level) })

        if !displayed.isEmpty {
            let byRoom = Dictionary(grouping: displayed, by: \.room)
            let sortedRooms = byRoom.keys.sorted()
            let columns = assignColumns(sortedRooms: sortedRooms, byRoom: byRoom)

            VStack(alignment: .leading, spacing: EditorialTheme.gridSpacing) {
                EditorialSectionHeader(
                    title: "LIGHTS ON",
                    trailing: "\(onIds.count) ACTIVE",
                    actionLabel: "ALL OFF",
                    action: {
                        store.performBulk("all_off", action: .turnOff) {
                            for device in displayed where device.level > 0 {
                                store.setLevel(device.integrationId, level: 0, fadeTime: 1)
                            }
                        }
                    }
                )

                HStack(alignment: .top, spacing: EditorialTheme.gridSpacing) {
                    ForEach([0, 1], id: \.self) { col in
                        VStack(alignment: .leading, spacing: EditorialTheme.gridSpacing) {
                            ForEach(sortedRooms.filter { columns[$0] == col }, id: \.self) { room in
                                roomGroup(room: room, lights: byRoom[room]!)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }
            .onAppear {
                if displayedIds == nil { displayedIds = onIds }
                persistColumns(columns)
            }
            .onChange(of: sortedRooms) {
                persistColumns(assignColumns(sortedRooms: sortedRooms, byRoom: byRoom))
            }
            .onChange(of: levelsById) { _, newLevels in
                let on = Set(newLevels.filter { $0.value > 0 }.keys)
                displayedIds = (displayedIds ?? on).union(on)
                settleTask?.cancel()
                settleTask = nil
                // Only linger-compact when something displayed is actually off.
                guard !(displayedIds ?? []).subtracting(on).isEmpty else { return }
                settleTask = Task {
                    try? await Task.sleep(for: Self.settleDelay)
                    guard !Task.isCancelled else { return }
                    compact(animated: true)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    settleTask?.cancel()
                    settleTask = nil
                    compact(animated: false)
                }
            }
            .onDisappear {
                settleTask?.cancel()
                settleTask = nil
                displayedIds = nil
                roomColumn = [:]
            }
        }
    }

    private func roomGroup(room: String, lights: [DeviceState]) -> some View {
        let roomLights = store.devices.values.filter { $0.room == room && $0.category == .light }
        let onCount = roomLights.filter { $0.level > 0 }.count
        return RoomCard(name: room, activeCount: onCount, total: roomLights.count) {
            if onCount > 0 {
                Button {
                    store.performBulk("room_off", room: room, action: .turnOff) {
                        for device in roomLights where device.level > 0 {
                            store.setLevel(device.integrationId, level: 0, fadeTime: 1)
                        }
                    }
                } label: {
                    Image(systemName: "lightbulb.slash")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(EditorialTheme.secondaryText)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } content: {
            VStack(spacing: 6) {
                ForEach(lights) { device in
                    DimmablePill(device: device, dimsWhenOff: true)
                }
            }
        }
    }

    private func compact(animated: Bool) {
        let on = Set(store.lightsOn.map(\.integrationId))
        if animated {
            withAnimation(.easeInOut(duration: 0.25)) {
                displayedIds = on.isEmpty ? nil : on
            }
        } else {
            displayedIds = on.isEmpty ? nil : on
        }
        settleTask = nil
    }

    /// Deterministic: persisted assignments win; new rooms go to the shorter column.
    private func assignColumns(sortedRooms: [String], byRoom: [String: [DeviceState]]) -> [String: Int] {
        var assignment: [String: Int] = [:]
        var heights: [CGFloat] = [0, 0]
        for room in sortedRooms {
            if let col = roomColumn[room] {
                assignment[room] = col
                heights[col] += estimatedHeight(pillCount: byRoom[room]!.count)
            }
        }
        for room in sortedRooms where assignment[room] == nil {
            let col = heights[0] <= heights[1] ? 0 : 1
            assignment[room] = col
            heights[col] += estimatedHeight(pillCount: byRoom[room]!.count)
        }
        return assignment
    }

    private func estimatedHeight(pillCount: Int) -> CGFloat {
        // card padding + header + header spacing + 40pt pills with 6pt gaps + inter-group gap
        16 + 22 + 8 + CGFloat(pillCount) * 40 + CGFloat(max(0, pillCount - 1)) * 6 + EditorialTheme.gridSpacing
    }

    private func persistColumns(_ columns: [String: Int]) {
        roomColumn.merge(columns) { existing, _ in existing }
    }
}
