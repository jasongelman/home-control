import SwiftUI

private enum DragIntent { case undecided, adjusting, scrolling }

struct DimmablePill: View {
    @Environment(LutronStore.self) var store
    let device: DeviceState
    var fadeTime: Double? = nil
    var dimsWhenOff: Bool = false

    @State private var dragIntent: DragIntent = .undecided
    @State private var isDragging = false
    @State private var dragLevel: Double = 0
    @State private var lastSentLevel: Double = -1
    @State private var lastSendTime: Date = .distantPast
    @State private var showColorSheet = false

    private var displayLevel: Double { isDragging ? dragLevel : device.level }
    private var isOn: Bool { displayLevel > 0 }
    private var isColorCapable: Bool { store.isColorCapable(device) }
    private var swatchColor: Color {
        let hsv = store.deviceHSV[device.integrationId] ?? HSVColor(hue: 210, saturation: 80)
        return Color(hue: hsv.hue / 360, saturation: hsv.saturation / 100, brightness: 1)
    }

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
                    Text(device.name.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle((dimsWhenOff && !isOn) ? EditorialTheme.tertiaryText : EditorialTheme.primaryText)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    if isColorCapable {
                        Button { showColorSheet = true } label: {
                            Circle()
                                .fill(swatchColor)
                                .frame(width: 16, height: 16)
                                .overlay(Circle().stroke(EditorialTheme.cardBorder, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }

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
        .sheet(isPresented: $showColorSheet) {
            ColorLightSheet(device: device)
                .presentationDetents([.medium])
        }
    }
}

// MARK: - Color Light Sheet (full RGB color wheel + brightness)

struct ColorLightSheet: View {
    @Environment(LutronStore.self) var store
    @Environment(\.dismiss) private var dismiss
    let device: DeviceState

    @State private var pickerColor: Color = .blue
    @State private var brightness: Double = 100

    // Preset shortcuts mirror the physical "Colors" keypad palette.
    private static let presets: [(name: String, hue: Double, saturation: Double)] = [
        ("Red", 0, 100), ("Orange", 30, 100), ("Yellow", 55, 100),
        ("Green", 120, 100), ("Aqua", 180, 100), ("Blue", 220, 100),
        ("Purple", 275, 100), ("Pink", 320, 90), ("White", 0, 0),
    ]

    private func hueSat(from color: Color) -> (hue: Double, saturation: Double) {
        let ui = UIColor(color)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (Double(h) * 360, Double(s) * 100)
    }

    private func presetColor(_ hue: Double, _ sat: Double) -> Color {
        Color(hue: hue / 360, saturation: sat / 100, brightness: 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("\(device.room.uppercased()) · \(device.name.uppercased())")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(EditorialTheme.secondaryText)
                Spacer()
                Button("Done") { dismiss() }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(EditorialTheme.accent)
            }

            ColorPicker("Color", selection: $pickerColor, supportsOpacity: false)
                .font(.system(size: 14, weight: .medium))
                .onChange(of: pickerColor) { _, newColor in
                    let hs = hueSat(from: newColor)
                    store.setColor(device.integrationId, hue: hs.hue, saturation: hs.saturation,
                                   level: brightness)
                }

            // Preset shortcuts
            HStack(spacing: 8) {
                ForEach(Self.presets, id: \.name) { preset in
                    Button {
                        pickerColor = presetColor(preset.hue, preset.saturation)
                        store.setColor(device.integrationId, hue: preset.hue,
                                       saturation: preset.saturation, level: brightness)
                    } label: {
                        Circle()
                            .fill(presetColor(preset.hue, preset.saturation))
                            .frame(width: 28, height: 28)
                            .overlay(Circle().stroke(EditorialTheme.cardBorder, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }

            // Brightness slider
            VStack(alignment: .leading, spacing: 6) {
                Text("BRIGHTNESS · \(Int(brightness))%")
                    .font(.system(size: 10, weight: .medium))
                    .tracking(0.8)
                    .foregroundStyle(EditorialTheme.secondaryText)
                Slider(value: $brightness, in: 0...100, step: 1) { editing in
                    guard !editing else { return }
                    let hs = hueSat(from: pickerColor)
                    store.setColor(device.integrationId, hue: hs.hue, saturation: hs.saturation,
                                   level: brightness)
                }
                .tint(EditorialTheme.accent)
            }

            Spacer()
        }
        .padding(20)
        .background(EditorialTheme.background.ignoresSafeArea())
        .onAppear {
            let hsv = store.deviceHSV[device.integrationId] ?? HSVColor(hue: 210, saturation: 80)
            pickerColor = Color(hue: hsv.hue / 360, saturation: hsv.saturation / 100, brightness: 1)
            brightness = device.level > 0 ? device.level : 100
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

    @State private var dragIntent: DragIntent = .undecided
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
            store.setLevel(device.integrationId, level: snapped, fadeTime: fadeTime)
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
                        .font(.system(size: 12))
                    Text(room.name.uppercased())
                        .font(.system(size: 9, weight: .medium))
                        .tracking(0.8)
                        .foregroundStyle(EditorialTheme.secondaryText)
                        .lineLimit(1)
                    if !summary.isEmpty {
                        Text(summary)
                            .font(.system(size: 9, weight: .medium))
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
                            dragLevel = avgLevel
                            lastSentLevel = avgLevel
                        }
                        let pct = max(0, min(100, (value.location.x / geo.size.width) * 100))
                        dragLevel = pct
                        sendIfNeeded(pct)
                    }
                    .onEnded { value in
                        if dragIntent == .adjusting && isDragging {
                            let pct = max(0, min(100, (value.location.x / geo.size.width) * 100))
                            commit(pct)
                        }
                        dragIntent = .undecided
                        isDragging = false
                    }
            )
        }
        .frame(height: 32)
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
                        for device in displayed where device.level > 0 {
                            store.setLevel(device.integrationId, level: 0, fadeTime: 1)
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
        VStack(alignment: .leading, spacing: 6) {
            Text(room.uppercased())
                .font(.system(size: 9, weight: .medium))
                .tracking(0.8)
                .foregroundStyle(EditorialTheme.secondaryText)

            ForEach(lights) { device in
                DimmablePill(device: device, dimsWhenOff: true)
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
        // room label + label spacing + 40pt pills with 6pt gaps + inter-group gap
        12 + 6 + CGFloat(pillCount) * 40 + CGFloat(max(0, pillCount - 1)) * 6 + EditorialTheme.gridSpacing
    }

    private func persistColumns(_ columns: [String: Int]) {
        roomColumn.merge(columns) { existing, _ in existing }
    }
}
