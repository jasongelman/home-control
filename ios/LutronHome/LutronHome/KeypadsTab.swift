import SwiftUI

// MARK: - Data Models

struct KeypadButton: Identifiable, Codable {
    let id: Int
    let buttonNumber: Int
    let name: String
    let engraving: String
    let ledId: Int?
    var ledState: String // "On", "Off", "Unknown"
}

struct KeypadInfo: Identifiable, Codable {
    let deviceId: Int
    let deviceType: String
    let name: String
    let areaName: String
    let modelNumber: String
    var buttons: [KeypadButton]

    var id: Int { deviceId }
}

// MARK: - Keypads Section (embeddable in CategoryTab)

struct KeypadsSection: View {
    @Environment(LutronStore.self) var store
    @State private var keypads: [KeypadInfo] = []
    @State private var isLoading = false
    @State private var expandedKeypad: Int?
    @State private var ledMode = false

    private var keypadsByRoom: [(room: String, keypads: [KeypadInfo])] {
        let grouped = Dictionary(grouping: keypads) { $0.areaName }
        return grouped
            .map { (room: $0.key, keypads: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.room < $1.room }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: EditorialTheme.gridSpacing) {
            // Section header with mode toggle
            HStack(alignment: .firstTextBaseline) {
                EditorialSectionHeader(
                    title: "KEYPADS",
                    trailing: keypads.isEmpty ? nil : "\(keypads.count) DEVICES"
                )
            }

            // Mode toggle pill
            HStack(spacing: 0) {
                modeButton("BUTTON PRESS", isActive: !ledMode) { ledMode = false }
                modeButton("LED CONTROL", isActive: ledMode) { ledMode = true }
            }
            .background(EditorialTheme.cardBackground)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(EditorialTheme.cardBorder, lineWidth: 0.5))

            if isLoading && keypads.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text("DISCOVERING KEYPADS…")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(EditorialTheme.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else if keypads.isEmpty {
                Text("CONNECT TO PROCESSOR TO SEE KEYPADS")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(EditorialTheme.secondaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else {
                ForEach(keypadsByRoom, id: \.room) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.room.uppercased())
                            .font(EditorialTheme.sectionLabel(size: 10))
                            .tracking(0.8)
                            .foregroundStyle(EditorialTheme.secondaryText)

                        ForEach(group.keypads) { keypad in
                            EditorialKeypadCard(
                                keypad: keypad,
                                isExpanded: expandedKeypad == keypad.deviceId,
                                ledMode: ledMode,
                                onToggle: {
                                    withAnimation(.easeInOut(duration: 0.25)) {
                                        expandedKeypad = expandedKeypad == keypad.deviceId ? nil : keypad.deviceId
                                    }
                                },
                                onButtonTap: { button in
                                    if ledMode {
                                        toggleLED(keypad: keypad, button: button)
                                    } else {
                                        pressButton(button: button)
                                    }
                                }
                            )
                        }
                    }
                }
            }
        }
        .task { await loadKeypads() }
    }

    private func modeButton(_ label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(isActive ? .white : EditorialTheme.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isActive ? EditorialTheme.accent : Color.clear)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Keypad Cache

    private static var cacheURL: URL? {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("lutron-keypads.json")
    }

    private func loadCachedKeypads() -> [KeypadInfo]? {
        guard let url = Self.cacheURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let cached = try? JSONDecoder().decode([KeypadInfo].self, from: data),
              !cached.isEmpty else { return nil }
        return cached
    }

    private func saveCachedKeypads(_ keypads: [KeypadInfo]) {
        guard let url = Self.cacheURL else { return }
        // Strip LED state before caching — it's ephemeral
        let stripped = keypads.map { kp in
            var k = kp
            k.buttons = k.buttons.map { b in
                KeypadButton(id: b.id, buttonNumber: b.buttonNumber, name: b.name,
                             engraving: b.engraving, ledId: b.ledId, ledState: "Unknown")
            }
            return k
        }
        if let data = try? JSONEncoder().encode(stripped) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - LEAP Discovery

    private func loadKeypads() async {
        // Load from cache immediately so UI appears fast
        if keypads.isEmpty, let cached = loadCachedKeypads() {
            keypads = cached
        }

        // Then do a full LEAP fetch if connected
        guard store.isConnected else { return }
        guard let client = store.leapClientForKeypads else { return }
        isLoading = true
        defer { isLoading = false }

        var discovered: [KeypadInfo] = []

        var leafAreas: [(id: Int, name: String)] = []
        do {
            let resp = try await client.send(LEAPMessagePayload(
                CommuniqueType: "ReadRequest",
                Header: LEAPMessageHeader(Url: "/area")
            ))
            if let rawAreas = resp.Body?.Areas {
                for a in rawAreas {
                    let href = a["href"]?.stringValue ?? ""
                    let id = Self.hrefToId(href)
                    let name = a["Name"]?.stringValue ?? "Area \(id)"
                    let isLeaf = a["IsLeaf"]?.boolValue ?? true
                    if id > 0 && isLeaf { leafAreas.append((id, name)) }
                }
            }
        } catch { return }

        for area in leafAreas {
            do {
                let csResp = try await client.send(LEAPMessagePayload(
                    CommuniqueType: "ReadRequest",
                    Header: LEAPMessageHeader(Url: "/area/\(area.id)/associatedcontrolstation")
                ))

                guard let stationsAC = csResp.Body?.additionalValues?["ControlStations"]?.arrayValue else { continue }
                for csAC in stationsAC {
                    guard let cs = csAC.dictValue else { continue }
                    let csName = cs["Name"]?.stringValue ?? ""
                    guard let gangedAC = cs["AssociatedGangedDevices"]?.arrayValue else { continue }

                    for gAC in gangedAC {
                        guard let g = gAC.dictValue else { continue }
                        guard let dev = g["Device"]?.dictValue else { continue }
                        let deviceType = dev["DeviceType"]?.stringValue ?? ""
                        guard deviceType.contains("Keypad") || deviceType.contains("Sunnata") else { continue }

                        let deviceHref = dev["href"]?.stringValue ?? ""
                        let deviceId = Self.hrefToId(deviceHref)

                        let buttons = await loadKeypadButtons(client: client, deviceHref: deviceHref)

                        var model = ""
                        if let devResp = try? await client.send(LEAPMessagePayload(
                            CommuniqueType: "ReadRequest",
                            Header: LEAPMessageHeader(Url: deviceHref)
                        )) {
                            if let device = devResp.Body?.additionalValues?["Device"]?.dictValue {
                                model = device["ModelNumber"]?.stringValue ?? ""
                            }
                        }

                        discovered.append(KeypadInfo(
                            deviceId: deviceId,
                            deviceType: deviceType,
                            name: csName,
                            areaName: area.name,
                            modelNumber: model,
                            buttons: buttons
                        ))
                    }
                }
            } catch { continue }
        }

        let sorted = discovered.sorted { ($0.areaName, $0.name) < ($1.areaName, $1.name) }
        await MainActor.run {
            self.keypads = sorted
        }
        saveCachedKeypads(sorted)
    }

    private func loadKeypadButtons(client: LEAPClient, deviceHref: String) async -> [KeypadButton] {
        var buttons: [KeypadButton] = []

        do {
            let bgResp = try await client.send(LEAPMessagePayload(
                CommuniqueType: "ReadRequest",
                Header: LEAPMessageHeader(Url: "\(deviceHref)/buttongroup")
            ))

            guard let groupsAC = bgResp.Body?.additionalValues?["ButtonGroups"]?.arrayValue else { return [] }

            for groupAC in groupsAC {
                guard let group = groupAC.dictValue else { continue }
                let groupHref = group["href"]?.stringValue ?? ""
                guard !groupHref.isEmpty else { continue }

                let btnsResp = try await client.send(LEAPMessagePayload(
                    CommuniqueType: "ReadRequest",
                    Header: LEAPMessageHeader(Url: "\(groupHref)/button")
                ))

                guard let rawBtnsAC = btnsResp.Body?.additionalValues?["Buttons"]?.arrayValue else { continue }

                for bAC in rawBtnsAC {
                    guard let b = bAC.dictValue else { continue }
                    let btnHref = b["href"]?.stringValue ?? ""
                    let btnId = Self.hrefToId(btnHref)
                    let btnNumber = b["ButtonNumber"]?.intValue ?? 0
                    let btnName = b["Name"]?.stringValue ?? ""
                    let engraving = b["Engraving"]?.dictValue?["Text"]?.stringValue ?? ""
                    let ledHref = b["AssociatedLED"]?.dictValue?["href"]?.stringValue
                    let ledId = ledHref.map { Self.hrefToId($0) }

                    var ledState = "Unknown"
                    if let lh = ledHref {
                        if let ledResp = try? await client.send(LEAPMessagePayload(
                            CommuniqueType: "ReadRequest",
                            Header: LEAPMessageHeader(Url: "\(lh)/status")
                        )) {
                            if let status = ledResp.Body?.additionalValues?["LEDStatus"]?.dictValue {
                                ledState = status["State"]?.stringValue ?? "Unknown"
                            }
                        }
                    }

                    buttons.append(KeypadButton(
                        id: btnId,
                        buttonNumber: btnNumber,
                        name: btnName,
                        engraving: engraving,
                        ledId: ledId,
                        ledState: ledState
                    ))
                }
            }
        } catch {}

        return buttons
    }

    // MARK: - Actions

    private func pressButton(button: KeypadButton) {
        guard let client = store.leapClientForKeypads else { return }
        Task {
            _ = try? await client.send(LEAPMessagePayload(
                CommuniqueType: "CreateRequest",
                Header: LEAPMessageHeader(Url: "/button/\(button.id)/commandprocessor"),
                Body: LEAPBodyPayload(Command: LEAPCommand(
                    CommandType: "PressAndRelease"
                ))
            ))
        }
    }

    private func toggleLED(keypad: KeypadInfo, button: KeypadButton) {
        guard let ledId = button.ledId, let client = store.leapClientForKeypads else { return }
        let newState = button.ledState == "On" ? "Off" : "On"

        // Optimistic update
        if let kpIdx = keypads.firstIndex(where: { $0.deviceId == keypad.deviceId }),
           let btnIdx = keypads[kpIdx].buttons.firstIndex(where: { $0.id == button.id }) {
            keypads[kpIdx].buttons[btnIdx].ledState = newState
        }

        Task {
            do {
                _ = try await client.send(LEAPMessagePayload(
                    CommuniqueType: "UpdateRequest",
                    Header: LEAPMessageHeader(Url: "/led/\(ledId)/status"),
                    Body: LEAPBodyPayload(LEDStatus: LEAPLEDStatus(State: newState))
                ))
            } catch {
                await MainActor.run {
                    if let kpIdx = keypads.firstIndex(where: { $0.deviceId == keypad.deviceId }),
                       let btnIdx = keypads[kpIdx].buttons.firstIndex(where: { $0.id == button.id }) {
                        keypads[kpIdx].buttons[btnIdx].ledState = button.ledState
                    }
                }
            }
        }
    }

    private static func hrefToId(_ href: String) -> Int {
        guard let last = href.split(separator: "/").last else { return 0 }
        return Int(last) ?? 0
    }
}

// MARK: - Editorial Keypad Card

struct EditorialKeypadCard: View {
    let keypad: KeypadInfo
    let isExpanded: Bool
    let ledMode: Bool
    let onToggle: () -> Void
    let onButtonTap: (KeypadButton) -> Void

    private var deviceIcon: String {
        if keypad.deviceType.contains("Alisse") { return "rectangle.split.2x2" }
        if keypad.deviceType.contains("Sunnata") { return "rectangle.split.1x2" }
        if keypad.deviceType.contains("Homeowner") { return "rectangle.grid.1x2" }
        return "square.grid.2x2"
    }

    private var activeCount: Int {
        keypad.buttons.filter { $0.ledState == "On" }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            Button(action: onToggle) {
                HStack(spacing: 10) {
                    Image(systemName: deviceIcon)
                        .font(.system(size: 14))
                        .foregroundStyle(EditorialTheme.accent)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(keypad.name.uppercased())
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(EditorialTheme.primaryText)
                            .lineLimit(1)

                        HStack(spacing: 4) {
                            Text(keypad.deviceType)
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(EditorialTheme.secondaryText)
                            if !keypad.modelNumber.isEmpty {
                                Text("·")
                                    .font(.system(size: 8))
                                    .foregroundStyle(EditorialTheme.secondaryText)
                                Text(keypad.modelNumber)
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundStyle(EditorialTheme.secondaryText)
                            }
                        }
                    }

                    Spacer()

                    if activeCount > 0 {
                        Text("\(activeCount)")
                            .font(EditorialTheme.monoValue(size: 10))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(EditorialTheme.accent, in: Capsule())
                    }

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(EditorialTheme.secondaryText)
                }
                .padding(10)
            }
            .buttonStyle(.plain)

            // Expanded button list
            if isExpanded {
                Rectangle()
                    .fill(EditorialTheme.cardBorder)
                    .frame(height: 0.5)
                    .padding(.horizontal, 10)

                VStack(spacing: 0) {
                    ForEach(keypad.buttons.filter { !$0.engraving.isEmpty || !$0.name.isEmpty }) { button in
                        EditorialLEDButtonRow(
                            button: button,
                            ledMode: ledMode,
                            onTap: { onButtonTap(button) }
                        )
                    }
                }
                .padding(.bottom, 6)
            }
        }
        .editorialCard(padding: 0)
    }
}

// MARK: - Editorial LED Button Row

struct EditorialLEDButtonRow: View {
    let button: KeypadButton
    let ledMode: Bool
    let onTap: () -> Void

    private var displayName: String {
        if !button.engraving.isEmpty { return button.engraving }
        return button.name
    }

    var body: some View {
        HStack(spacing: 10) {
            // LED indicator
            Circle()
                .fill(button.ledId != nil && button.ledState == "On" ? EditorialTheme.accent : EditorialTheme.cardBorder)
                .frame(width: 6, height: 6)

            Text(displayName.uppercased())
                .font(.system(size: 10, weight: .medium))
                .tracking(0.4)
                .foregroundStyle(EditorialTheme.primaryText)
                .lineLimit(1)

            Spacer()

            Button(action: onTap) {
                Text(ledMode ? (button.ledState == "On" ? "ON" : "OFF") : "PRESS")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(
                        ledMode && button.ledState == "On" ? .white :
                        !ledMode ? EditorialTheme.accent :
                        EditorialTheme.secondaryText
                    )
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        ledMode && button.ledState == "On" ? EditorialTheme.accent :
                        !ledMode ? EditorialTheme.accent.opacity(0.1) :
                        EditorialTheme.cardBackground,
                        in: Capsule()
                    )
                    .overlay(
                        Capsule().stroke(
                            ledMode && button.ledState == "On" ? EditorialTheme.accent :
                            EditorialTheme.cardBorder,
                            lineWidth: 0.5
                        )
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
