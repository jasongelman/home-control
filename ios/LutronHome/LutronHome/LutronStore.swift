import Foundation
import Network
import Observation
import WidgetKit

enum ConnectionState: Equatable {
    case connected
    case connecting
    case disconnectedProcessorDown   // On WiFi, processor not responding
    case disconnectedNeedsVPN        // On cellular or non-home WiFi
    case disconnectedNoNetwork       // No network at all
}

@Observable
class LutronStore: @unchecked Sendable {
    var devices: [Int: DeviceState] = [:]
    var isConnected = false
    var isLoading = false
    var scenes: [LightScene] = []
    var statusMessage = ""
    var connectionState: ConnectionState = .connecting

    var processorHost: String {
        get { UserDefaults.standard.string(forKey: "processorHost") ?? "192.168.1.191" }
        set { UserDefaults.standard.set(newValue, forKey: "processorHost") }
    }



    /// Usage tracker for personalization — set externally from App entry point
    var usageTracker: UsageTracker?

    private var leapClient: LEAPClient?
    /// Exposes the LEAP client for keypad discovery (read-only).
    var leapClientForKeypads: LEAPClient? { leapClient }
    private var reconnectTimer: Timer?
    private var reconnectAttempt = 0
    private let maxReconnectDelay: TimeInterval = 60
    private var started = false

    // MARK: - Topology Cache

    private struct CachedTopology: Codable {
        var devices: [DeviceState]
        var processorHost: String
        var savedAt: Double
    }

    private var topologyCacheURL: URL? {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("lutron-topology.json")
    }

    /// True if we loaded topology from cache and haven't done a full LEAP fetch yet.
    private var usingCachedTopology = false

    // MARK: - Keypad Integration

    struct KeypadOffButton {
        let room: String
        let buttonId: Int
    }

    struct ColorKeypadButton: Identifiable {
        let id: Int
        let engraving: String
        let ledId: Int?
        let isOff: Bool
    }

    struct ColorKeypadEntry: Identifiable {
        let id: Int // deviceId
        let room: String
        var buttons: [ColorKeypadButton]
        var activeButtonId: Int? // which button's LED is currently on
    }

    /// Keypad "Off" buttons to press during bulk-off actions
    var keypadOffButtons: [KeypadOffButton] = []
    /// Colors keypads for Gym/Playroom/Secret Room
    var colorKeypads: [ColorKeypadEntry] = []
    private var pathMonitor: NWPathMonitor?
    private var currentPath: NWPath?

    private func loadCachedTopology() -> Bool {
        guard let url = topologyCacheURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(CachedTopology.self, from: data),
              cache.processorHost == processorHost,
              !cache.devices.isEmpty else {
            return false
        }
        var newDevices: [Int: DeviceState] = [:]
        for var d in cache.devices {
            d.level = 0
            d.lastUpdated = Date().timeIntervalSince1970
            newDevices[d.integrationId] = d
        }
        devices = newDevices
        usingCachedTopology = true
        print("LEAP: loaded \(newDevices.count) devices from topology cache")
        return true
    }

    private func saveCachedTopology() {
        guard let url = topologyCacheURL else { return }
        let cache = CachedTopology(
            devices: Array(devices.values),
            processorHost: processorHost,
            savedAt: Date().timeIntervalSince1970
        )
        do {
            let data = try JSONEncoder().encode(cache)
            try data.write(to: url, options: .atomic)
            print("LEAP: saved topology cache (\(devices.count) devices)")
        } catch {
            print("LEAP: failed to write topology cache — \(error.localizedDescription)")
        }
    }

    private func deleteCachedTopology() {
        guard let url = topologyCacheURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Keypad Cache Loading

    private var keypadCacheURL: URL? {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("lutron-keypads.json")
    }

    /// Area renames applied to keypad data (same as zone topology renames).
    private static let areaRenames: [String: String] = [
        "Bedroom 1": "Ronan's Room",
        "Bedroom 2": "Sebastian's Room",
        "Safe Room": "Secret Room",
        "Attic Bathroom": "Guest Bathroom",
        "Attic Guest Bedroom": "Guest Bedroom",
        "Mudroom Entry": "Mudroom",
    ]

    /// Load keypad off-buttons and color keypads from the keypad cache file.
    private func loadKeypadData() {
        guard let url = keypadCacheURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let keypads = try? JSONDecoder().decode([KeypadInfo].self, from: data) else { return }

        let offRooms: Set<String> = ["Gym", "Playroom", "Secret Room"]

        // Extract off-buttons for bulk-off actions
        var offButtons: [KeypadOffButton] = []
        for kp in keypads {
            let room = Self.areaRenames[kp.areaName] ?? kp.areaName
            guard offRooms.contains(room) else { continue }
            // Skip Colors keypads — their Off button is for color lights only
            if kp.name.localizedCaseInsensitiveContains("Colors") { continue }
            for btn in kp.buttons {
                let eng = btn.engraving.lowercased()
                if eng == "off" || eng == "room off" {
                    offButtons.append(KeypadOffButton(room: room, buttonId: btn.id))
                }
            }
        }
        keypadOffButtons = offButtons
        print("LEAP: loaded \(offButtons.count) keypad off-buttons from cache")

        // Extract Colors keypads
        var colors: [ColorKeypadEntry] = []
        for kp in keypads where kp.name.localizedCaseInsensitiveContains("Colors") {
            let room = Self.areaRenames[kp.areaName] ?? kp.areaName
            let buttons = kp.buttons.map { btn in
                let eng = btn.engraving.lowercased()
                let isOff = eng == "off" || eng.contains("off")
                return ColorKeypadButton(id: btn.id, engraving: btn.engraving, ledId: btn.ledId, isOff: isOff)
            }
            // Sort: non-off buttons first, then off button last
            let sorted = buttons.sorted { a, b in
                if a.isOff != b.isOff { return !a.isOff }
                return a.id < b.id
            }
            colors.append(ColorKeypadEntry(id: kp.deviceId, room: room, buttons: sorted, activeButtonId: nil))
        }
        colorKeypads = colors
        print("LEAP: loaded \(colors.count) color keypads from cache")
    }

    /// Press a keypad button via LEAP PressAndRelease command.
    func pressKeypadButton(_ buttonId: Int) {
        guard let client = leapClient else { return }
        Task {
            _ = try? await client.send(LEAPMessagePayload(
                CommuniqueType: "CreateRequest",
                Header: LEAPMessageHeader(Url: "/button/\(buttonId)/commandprocessor"),
                Body: LEAPBodyPayload(Command: LEAPCommand(
                    CommandType: "PressAndRelease"
                ))
            ))
        }
    }

    /// Refresh LED states for color keypads (determines which color is active).
    func refreshColorKeypadLEDs() async {
        guard let client = leapClient else { return }
        for (i, entry) in colorKeypads.enumerated() {
            var activeId: Int?
            for btn in entry.buttons where !btn.isOff {
                guard let ledId = btn.ledId else { continue }
                do {
                    let resp = try await client.send(LEAPMessagePayload(
                        CommuniqueType: "ReadRequest",
                        Header: LEAPMessageHeader(Url: "/led/\(ledId)/status")
                    ))
                    if let status = resp.Body?.additionalValues?["LEDStatus"]?.dictValue,
                       status["State"]?.stringValue == "On" {
                        activeId = btn.id
                    }
                } catch {}
            }
            let capturedActiveId = activeId
            await MainActor.run {
                self.colorKeypads[i].activeButtonId = capturedActiveId
            }
        }
    }

    // Computed properties
    var lightsOn: [DeviceState] {
        devices.values
            .filter { $0.category == .light && $0.level > 0 }
            .sorted { ($0.room, $0.name) < ($1.room, $1.name) }
    }

    var rooms: [(name: String, devices: [DeviceState])] {
        let grouped = Dictionary(grouping: Array(devices.values)) { $0.room }
        return grouped
            .map { (name: $0.key, devices: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.name < $1.name }
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        _ = loadCachedTopology()
        loadKeypadData()
        startNetworkMonitoring()
        connect()
    }

    // MARK: - Connection

    func connect() {
        disconnect()

        guard let creds = CertificateLoader.loadFromBundle() else {
            statusMessage = "No certificates found in bundle"
            print("LutronStore: \(statusMessage)")
            return
        }

        statusMessage = "Connecting..."
        connectionState = .connecting
        let client = LEAPClient(host: processorHost, port: 8081, identity: creds.identity, caCert: creds.ca)

        client.onConnect = { [weak self] in
            guard let self else { return }
            self.isConnected = true
            self.reconnectAttempt = 0
            self.updateConnectionState()
            print("LEAP: connected to \(self.processorHost)")
            if self.usingCachedTopology || !self.devices.isEmpty {
                self.statusMessage = "Subscribing to updates..."
                Task {
                    await self.subscribeToZoneStatus()
                    await self.refreshColorKeypadLEDs()
                }
            } else {
                self.statusMessage = "Connected, loading devices..."
                Task {
                    await self.loadTopology()
                    await self.refreshColorKeypadLEDs()
                }
            }
        }

        client.onDisconnect = { [weak self] reason in
            guard let self else { return }
            print("LEAP: disconnected — \(reason)")
            self.isConnected = false
            self.statusMessage = "Disconnected: \(reason)"
            self.updateConnectionState()
            self.scheduleReconnect()
        }

        client.onError = { [weak self] error in
            print("LEAP: error — \(error.localizedDescription)")
            self?.statusMessage = "Error: \(error.localizedDescription)"
        }

        client.onMessage = { [weak self] msg in
            self?.handleUnsolicited(msg)
        }

        self.leapClient = client
        client.connect()
    }

    func disconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        leapClient?.disconnect()
        leapClient = nil
        isConnected = false
    }

    // MARK: - Refresh (pull-to-refresh)

    func refresh() async {
        guard leapClient != nil else {
            connect()
            return
        }
        await loadTopology()
    }

    /// Force a full topology re-fetch from the LEAP processor, ignoring cache.
    func refreshDevices() async {
        guard leapClient != nil else {
            connect()
            return
        }
        usingCachedTopology = false
        await loadTopology()
    }

    // MARK: - Topology Loading

    private func loadTopology() async {
        guard let client = leapClient else { return }

        usingCachedTopology = false
        await MainActor.run { isLoading = true }

        do {
            // Small delay to let the processor settle after TLS handshake
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5s

            // 1. Load areas
            await MainActor.run { statusMessage = "Loading areas..." }
            let areaResp = try await client.send(LEAPMessagePayload(
                CommuniqueType: "ReadRequest",
                Header: LEAPMessageHeader(Url: "/area")
            ))
            var areas: [Int: String] = [:]
            if let rawAreas = areaResp.Body?.Areas {
                for a in rawAreas {
                    let id = hrefToId(a["href"]?.stringValue ?? "")
                    let name = a["Name"]?.stringValue ?? "Area \(id)"
                    if id > 0 { areas[id] = name }
                }
            }
            print("LEAP: loaded \(areas.count) areas")

            // 2. Load zones — try bulk first, fall back to status discovery (QSX)
            var zoneList: [(id: Int, name: String, controlType: String, areaName: String)] = []
            var initialLevels: [Int: Double] = [:]

            await MainActor.run { statusMessage = "Loading zones..." }

            do {
                let zoneResp = try await client.send(LEAPMessagePayload(
                    CommuniqueType: "ReadRequest",
                    Header: LEAPMessageHeader(Url: "/zone")
                ))
                if let rawZones = zoneResp.Body?.Zones, !rawZones.isEmpty {
                    for z in rawZones {
                        let parsed = parseZone(z, areas: areas)
                        if let parsed { zoneList.append(parsed) }
                    }
                    print("LEAP: bulk /zone returned \(zoneList.count) zones")
                } else {
                    throw LEAPError.notConnected // force fallback
                }
            } catch {
                // QSX path — discover from status subscription
                print("LEAP: bulk /zone not available, discovering from status...")
                await MainActor.run { statusMessage = "Discovering zones via status..." }

                let statusResp = try await client.send(LEAPMessagePayload(
                    CommuniqueType: "SubscribeRequest",
                    Header: LEAPMessageHeader(Url: "/zone/status")
                ))

                var zoneIds: [Int] = []
                if let statuses = statusResp.Body?.ZoneStatuses {
                    for zs in statuses {
                        let zoneHref = zs["Zone"]?.dictValue?["href"]?.stringValue ?? ""
                        let zid = hrefToId(zoneHref)
                        let level = zs["Level"]?.doubleValue ?? 0
                        if zid > 0 {
                            zoneIds.append(zid)
                            initialLevels[zid] = level
                        }
                    }
                }
                print("LEAP: discovered \(zoneIds.count) zones from status")
                let capturedZoneIds = zoneIds
                await MainActor.run { statusMessage = "Fetching zone details (0/\(capturedZoneIds.count))..." }

                // Fetch individual zone details — populate UI progressively
                for (i, zid) in capturedZoneIds.enumerated() {
                    if i % 10 == 0 {
                        await MainActor.run { statusMessage = "Loading devices (\(i)/\(capturedZoneIds.count))..." }
                    }
                    do {
                        let zResp = try await client.send(LEAPMessagePayload(
                            CommuniqueType: "ReadRequest",
                            Header: LEAPMessageHeader(Url: "/zone/\(zid)")
                        ))
                        if let z = zResp.Body?.Zone {
                            if let parsed = parseZone(z, areas: areas) {
                                zoneList.append(parsed)
                                // Progressive: add device immediately so UI updates
                                let type: DeviceType = parsed.controlType == "Shade" ? .shade : .light
                                let category = DeviceCategory.classify(controlType: parsed.controlType, name: parsed.name)
                                let device = DeviceState(
                                    integrationId: parsed.id,
                                    name: parsed.name,
                                    type: type,
                                    category: category,
                                    room: parsed.areaName,
                                    level: initialLevels[parsed.id] ?? 0,
                                    components: nil,
                                    lastUpdated: Date().timeIntervalSince1970
                                )
                                await MainActor.run {
                                    self.devices[parsed.id] = device
                                }
                            }
                        }
                    } catch {
                        print("LEAP: failed to fetch zone \(zid): \(error)")
                    }
                }
            }

            // 3. For bulk path, build device map atomically
            if initialLevels.isEmpty || zoneList.count != devices.count {
                var newDevices: [Int: DeviceState] = [:]
                for z in zoneList {
                    let type: DeviceType = z.controlType == "Shade" ? .shade : .light
                    let category = DeviceCategory.classify(controlType: z.controlType, name: z.name)
                    newDevices[z.id] = DeviceState(
                        integrationId: z.id,
                        name: z.name,
                        type: type,
                        category: category,
                        room: z.areaName,
                        level: initialLevels[z.id] ?? 0,
                        components: nil,
                        lastUpdated: Date().timeIntervalSince1970
                    )
                }
                let devicesResult = newDevices
                await MainActor.run {
                    self.devices = devicesResult
                }
            }

            await MainActor.run {
                self.statusMessage = "\(self.devices.count) devices loaded"
                self.isLoading = false
            }
            print("LEAP: loaded \(devices.count) devices in \(areas.count) areas")

            // 4. Subscribe to zone status updates (if not already from QSX path)
            if initialLevels.isEmpty {
                await subscribeToZoneStatus()
            }

            syncToAppGroup()
            saveCachedTopology()

        } catch {
            print("LEAP: topology load failed: \(error)")
            await MainActor.run {
                self.statusMessage = "Load failed: \(error.localizedDescription)"
                self.isLoading = false
            }
        }
    }

    /// Subscribe to /zone/status for real-time level updates. Also applies
    /// the initial status snapshot returned by the SubscribeRequest.
    private func subscribeToZoneStatus() async {
        guard let client = leapClient else { return }
        do {
            let subResp = try await client.send(LEAPMessagePayload(
                CommuniqueType: "SubscribeRequest",
                Header: LEAPMessageHeader(Url: "/zone/status")
            ))
            if let statuses = subResp.Body?.ZoneStatuses {
                await MainActor.run {
                    for zs in statuses {
                        let zoneHref = zs["Zone"]?.dictValue?["href"]?.stringValue ?? ""
                        let zid = self.hrefToId(zoneHref)
                        let level = zs["Level"]?.doubleValue ?? 0
                        if zid > 0 { self.devices[zid]?.level = level }
                    }
                    self.statusMessage = "\(self.devices.count) devices"
                }
            }
            syncToAppGroup()
            print("LEAP: subscribed to zone status updates")
        } catch {
            print("LEAP: subscribe failed: \(error)")
            await MainActor.run { self.statusMessage = "Subscribe failed: \(error.localizedDescription)" }
        }
    }

    // MARK: - Unsolicited Messages (real-time zone updates)

    private func handleUnsolicited(_ msg: LEAPMessage) {
        let bodyType = msg.Header.MessageBodyType ?? ""
        guard bodyType == "MultipleZoneStatus" || bodyType == "OneZoneStatus" else { return }

        var statuses: [[String: AnyCodable]] = []
        if let zss = msg.Body?.ZoneStatuses { statuses = zss }
        else if let zs = msg.Body?.ZoneStatus { statuses = [zs] }

        for zs in statuses {
            let zoneHref = zs["Zone"]?.dictValue?["href"]?.stringValue ?? ""
            let zoneId = hrefToId(zoneHref)
            let level = zs["Level"]?.doubleValue ?? 0
            if zoneId > 0 {
                devices[zoneId]?.level = level
            }
        }
        syncToAppGroup()
    }

    // MARK: - Actions

    func setLevel(_ deviceId: Int, level: Double, fadeTime: Double? = nil) {
        guard let client = leapClient else { return }
        let fade = fadeTime.map { fadeDuration($0) }

        // Track usage
        let room = devices[deviceId]?.room
        let action: UsageEvent.Action = level == 0 ? .turnOff : .setLevel
        usageTracker?.trackDevice(deviceId, action: action, room: room, level: level)

        Task {
            do {
                _ = try await client.send(LEAPMessagePayload(
                    CommuniqueType: "CreateRequest",
                    Header: LEAPMessageHeader(Url: "/zone/\(deviceId)/commandprocessor"),
                    Body: LEAPBodyPayload(Command: LEAPCommand(
                        CommandType: "GoToLevel",
                        Parameter: [["Type": AnyCodable("Level"), "Value": AnyCodable(level)]],
                        FadeTime: fade
                    ))
                ))
            } catch {
                print("LEAP: setLevel failed: \(error)")
            }
        }
        // Optimistically update App Group
        devices[deviceId]?.level = level
        syncToAppGroup()
    }

    func turnOff(_ deviceId: Int) {
        setLevel(deviceId, level: 0, fadeTime: 1)
    }

    // MARK: - Color (full RGB) control

    /// Last color set per zone (optimistic — the QSX processor does not report color back).
    var deviceHSV: [Int: HSVColor] = [:]

    /// Rooms that have a "Colors" keypad — their light zones accept full RGB.
    /// Uses the renamed room names already applied to `colorKeypads`.
    var colorCapableRooms: Set<String> { Set(colorKeypads.map { $0.room }) }

    /// True if this light zone accepts arbitrary HSV color (GoToSpectrumTuningLevel).
    func isColorCapable(_ device: DeviceState) -> Bool {
        device.category == .light && colorCapableRooms.contains(device.room)
    }

    /// Set an arbitrary HSV color on a color-capable zone.
    /// Hue 0–360, Saturation 0–100. Level defaults to the zone's current level (or full-on if off).
    func setColor(_ deviceId: Int, hue: Double, saturation: Double, level: Double? = nil) {
        guard let client = leapClient else { return }
        let current = devices[deviceId]?.level ?? 0
        let lvl = level ?? (current > 0 ? current : 100)
        let h = Int(hue.rounded())
        let s = Int(saturation.rounded())

        usageTracker?.trackDevice(deviceId, action: lvl == 0 ? .turnOff : .setLevel,
                                  room: devices[deviceId]?.room, level: lvl)

        Task {
            do {
                _ = try await client.send(LEAPMessagePayload(
                    CommuniqueType: "CreateRequest",
                    Header: LEAPMessageHeader(Url: "/zone/\(deviceId)/commandprocessor"),
                    Body: LEAPBodyPayload(Command: LEAPCommand(
                        CommandType: "GoToSpectrumTuningLevel",
                        SpectrumTuningLevelParameters: [
                            "Level": AnyCodable(lvl),
                            "ColorTuningStatus": AnyCodable([
                                "HSVTuningLevel": AnyCodable([
                                    "Hue": AnyCodable(h),
                                    "Saturation": AnyCodable(s),
                                ] as [String: AnyCodable]),
                            ] as [String: AnyCodable]),
                        ]
                    ))
                ))
            } catch {
                print("LEAP: setColor failed: \(error)")
            }
        }
        // Optimistic local state
        deviceHSV[deviceId] = HSVColor(hue: hue, saturation: saturation)
        devices[deviceId]?.level = lvl
        syncToAppGroup()
    }

    /// Set all lights in a given room to a level
    func setRoomLights(_ roomName: String, level: Double, fadeTime: Double = 1) {
        let roomLights = devices.values.filter {
            $0.room == roomName && $0.category == .light
        }
        for device in roomLights {
            setLevel(device.integrationId, level: level, fadeTime: fadeTime)
        }
    }

    /// Find a device by room and name (case-insensitive contains match)
    private func findDevice(room: String, name: String) -> DeviceState? {
        let lower = name.lowercased()
        return devices.values.first {
            $0.room == room && $0.name.lowercased().contains(lower)
        }
    }

    /// Set a specific device level by room + name
    private func setDeviceLevel(room: String, name: String, level: Double, fadeTime: Double = 2) {
        if let device = findDevice(room: room, name: name) {
            setLevel(device.integrationId, level: level, fadeTime: fadeTime)
        }
    }

    /// Activate the Evening scene
    func activateEveningScene() {
        // 1. Dining Room: chandelier 50%, off cove accent & recessed
        setDeviceLevel(room: "Dining Room", name: "Chandelier", level: 50)
        setDeviceLevel(room: "Dining Room", name: "Cove Accent", level: 0)
        setDeviceLevel(room: "Dining Room", name: "Recessed", level: 0)

        // 2. Family Room: peak coves & wall coves 25%, spots 12%
        setDeviceLevel(room: "Family Room", name: "Peak Cove A", level: 25)
        setDeviceLevel(room: "Family Room", name: "Peak Cove B", level: 25)
        setDeviceLevel(room: "Family Room", name: "Wall Cove A", level: 25)
        setDeviceLevel(room: "Family Room", name: "Wall Cove B", level: 25)
        setDeviceLevel(room: "Family Room", name: "Spots", level: 12)

        // 3. Jason Office: all off
        setRoomLights("Jason Office", level: 0)

        // 4. Living Room: all off
        setRoomLights("Living Room", level: 0)

        // 5. Kitchen: specific off, pendant B & undercabinet 50%
        setDeviceLevel(room: "Kitchen", name: "Island Pendant A", level: 0)
        setDeviceLevel(room: "Kitchen", name: "Breakfast Chandelier", level: 0)
        setDeviceLevel(room: "Kitchen", name: "Breakfast Recessed", level: 0)
        setDeviceLevel(room: "Kitchen", name: "Breakfast Undercabinet", level: 0)
        setDeviceLevel(room: "Kitchen", name: "Kitchen Recessed", level: 0)
        setDeviceLevel(room: "Kitchen", name: "Pantry Chandelier", level: 0)
        setDeviceLevel(room: "Kitchen", name: "Pantry Undercabinet", level: 0)
        setDeviceLevel(room: "Kitchen", name: "Island Pendant B", level: 50)
        setDeviceLevel(room: "Kitchen", name: "Kitchen Undercabinet", level: 50)

        // 6. Main Entry: all off except hall track 25%
        setRoomLights("Main Entry", level: 0)
        setDeviceLevel(room: "Main Entry", name: "Hall Track", level: 25)

        // 7. Main Hall: stairs accent 30%
        setDeviceLevel(room: "Main Hall", name: "Stairs Accent", level: 30)

        // 8. Mudroom Entry: sconces off, recessed 25%
        setDeviceLevel(room: "Mudroom Entry", name: "Sconces", level: 0)
        setDeviceLevel(room: "Mudroom Entry", name: "Recessed", level: 25)
    }

    /// Toggle the Dining Shade, Family Room Shades Rear and Shades Side
    func toggleMainShades() {
        let targetNames = ["dining shade", "shades rear", "shades side"]
        let targetShades = devices.values.filter { device in
            device.category == .shadesAndDrapes &&
            targetNames.contains(where: { device.name.lowercased().contains($0) })
        }
        let anyOpen = targetShades.contains { $0.level > 0 }
        let newLevel: Double = anyOpen ? 0 : 100
        for shade in targetShades {
            setLevel(shade.integrationId, level: newLevel, fadeTime: 2)
        }
    }

    /// Turn off all lights on a given floor
    func turnOffLights(on floor: Floor) {
        let floorDevices = devices.values.filter {
            $0.category == .light && $0.level > 0 && Floor.floor(for: $0.room) == floor
        }
        for device in floorDevices {
            setLevel(device.integrationId, level: 0, fadeTime: 1)
        }
        // Also press keypad off-buttons for rooms on this floor
        for entry in keypadOffButtons where Floor.floor(for: entry.room) == floor {
            pressKeypadButton(entry.buttonId)
        }
    }

    /// Turn off all lights in the house, optionally excluding specific device names
    func turnOffAllLights(excludingNames: Set<String> = [], excludingRooms: Set<String> = []) {
        let lightsOn = devices.values.filter {
            $0.category == .light && $0.level > 0
            && !excludingNames.contains($0.name)
            && !excludingRooms.contains($0.room)
        }
        for device in lightsOn {
            setLevel(device.integrationId, level: 0, fadeTime: 1)
        }
        // Also press keypad off-buttons for all rooms not excluded
        for entry in keypadOffButtons where !excludingRooms.contains(entry.room) {
            pressKeypadButton(entry.buttonId)
        }
    }

    // MARK: - Garage Door Lights Automation

    private var garageLightsOffTimer: Timer?

    /// Turn on garage lights and auto-off after delay
    func triggerGarageDoorLights() {
        let garageLightNames: Set<String> = ["garage surface", "stairs recessed"]
        let matches = devices.values.filter {
            garageLightNames.contains($0.name.lowercased())
        }
        guard !matches.isEmpty else { return }

        for device in matches {
            setLevel(device.integrationId, level: 100, fadeTime: 0)
        }
        print("Lutron: garage lights ON (\(matches.count) devices)")

        // Cancel any existing timer and schedule auto-off in 5 minutes
        garageLightsOffTimer?.invalidate()
        garageLightsOffTimer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: false) { [weak self] _ in
            guard let self else { return }
            for device in matches {
                self.setLevel(device.integrationId, level: 0, fadeTime: 2)
            }
            print("Lutron: garage lights auto-OFF (5 min timer)")
        }
    }

    /// Rise & Shine: raise all downstairs shades to fully open
    func raiseDownstairsShades() {
        let downstairsShades = devices.values.filter {
            ($0.category == .shadesAndDrapes || $0.category == .window)
            && Floor.floor(for: $0.room) == .downstairs
        }
        for shade in downstairsShades {
            setLevel(shade.integrationId, level: 100, fadeTime: 2)
        }
    }

    /// Block Out The Sun: close Family Room rear shades, Dining shades,
    /// and Jason Office rear solar shade
    func blockOutTheSun() {
        let targetNames = ["shades rear", "dining shade", "rear solar"]
        let targetShades = devices.values.filter { device in
            (device.category == .shadesAndDrapes || device.category == .window) &&
            targetNames.contains(where: { device.name.lowercased().contains($0) })
        }
        for shade in targetShades {
            setLevel(shade.integrationId, level: 0, fadeTime: 2)
        }
    }

    // MARK: - Widget Sync

    /// Push current state to App Group for widget consumption
    private func syncToAppGroup() {
        AppGroupManager.writeDevices(devices)
        AppGroupManager.writeScenes(scenes)
        AppGroupManager.writeServerHost(processorHost)
        AppGroupManager.reloadWidgets()
    }

    // MARK: - Network Monitoring

    private func startNetworkMonitoring() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.currentPath = path
                self?.updateConnectionState()
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.lutronhome.network-monitor"))
        pathMonitor = monitor
    }

    private func updateConnectionState() {
        if isConnected {
            connectionState = .connected
            return
        }

        guard let path = currentPath else {
            // No path info yet — keep current state
            return
        }

        if path.status == .unsatisfied {
            connectionState = .disconnectedNoNetwork
        } else if path.usesInterfaceType(.cellular) && !path.usesInterfaceType(.wifi) {
            connectionState = .disconnectedNeedsVPN
        } else if path.usesInterfaceType(.wifi) {
            // On WiFi but not connected — could be wrong network or processor down
            connectionState = .disconnectedProcessorDown
        } else {
            connectionState = .disconnectedNeedsVPN
        }
    }

    // MARK: - Reconnect

    private func scheduleReconnect() {
        let delay = min(5.0 * pow(2.0, Double(reconnectAttempt)), maxReconnectDelay)
        reconnectAttempt += 1
        print("LEAP: reconnecting in \(delay)s (attempt \(reconnectAttempt))...")
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.connect() }
        }
    }

    // MARK: - Helpers

    private func parseZone(_ z: [String: AnyCodable], areas: [Int: String]) -> (id: Int, name: String, controlType: String, areaName: String)? {
        let id = hrefToId(z["href"]?.stringValue ?? "")
        guard id > 0 else { return nil }
        let rawName = z["Name"]?.stringValue ?? "Zone \(id)"
        let ct = z["ControlType"]?.stringValue ?? "Unknown"
        let areaHref = z["AssociatedArea"]?.dictValue?["href"]?.stringValue ?? ""
        let areaId = hrefToId(areaHref)
        let areaRenames: [String: String] = [
            "Bedroom 1": "Ronan's Room",
            "Bedroom 2": "Sebastian's Room",
            "Safe Room": "Secret Room",
            "Attic Bathroom": "Guest Bathroom",
            "Attic Guest Bedroom": "Guest Bedroom",
            "Mudroom Entry": "Mudroom",
        ]
        var areaName = areaRenames[areas[areaId] ?? ""] ?? areas[areaId] ?? "Unassigned"
        var name = rawName

        // Break Master Suite into sub-rooms and strip prefixes
        if areaName == "Master Suite" {
            let lower = rawName.lowercased()
            if lower.hasPrefix("rachel closet") {
                areaName = "Rachel Closet"
                name = String(rawName.dropFirst("Rachel Closet".count)).trimmingCharacters(in: .whitespaces)
            } else if lower.hasPrefix("jason closet") {
                areaName = "Jason Closet"
                name = String(rawName.dropFirst("Jason Closet".count)).trimmingCharacters(in: .whitespaces)
            } else if lower.hasPrefix("mbth") || lower.hasPrefix("mbth") {
                areaName = "Primary Bathroom"
                // Strip "MBTH " or "MBth " prefix
                if rawName.hasPrefix("MBTH ") {
                    name = String(rawName.dropFirst(5))
                } else if rawName.hasPrefix("MBth ") {
                    name = String(rawName.dropFirst(5))
                }
            } else if lower.hasPrefix("mbd") {
                areaName = "Primary Bedroom"
                // Strip "MBD " prefix
                if rawName.hasPrefix("MBD ") {
                    name = String(rawName.dropFirst(4))
                }
            }
            // Shades (Rear/Side Drapes/Shades) stay in Master Suite or assign to Primary Bedroom
        }

        // Break Breakfast devices out of Kitchen into Breakfast Nook
        if areaName == "Kitchen" && name.hasPrefix("Breakfast ") {
            areaName = "Breakfast Nook"
            name = String(name.dropFirst("Breakfast ".count))
        }

        // Rename specific devices
        let deviceRenames: [String: [String: String]] = [
            "Kitchen": [
                "Island Pendant A": "Island Uplight",
                "Island Pendant B": "Island Downlight",
            ],
            "Powder Room": [
                "Powder Recessed": "Recessed",
            ],
        ]
        if let renames = deviceRenames[areaName], let renamed = renames[name] {
            name = renamed
        }

        // Strip room-name prefixes from device names
        let prefixStrips: [String: [String]] = [
            "Guest Bathroom": ["Attic Bath "],
            "Guest Bedroom": ["Attic GB "],
            "Ronan's Room": ["Bedroom 1 ", "Bd1 "],
            "Sebastian's Room": ["Bedroom 2 ", "Bd2 "],
            "Mudroom": ["Mudroom "],
        ]
        if let prefixes = prefixStrips[areaName] {
            for prefix in prefixes {
                if name.hasPrefix(prefix) {
                    name = String(name.dropFirst(prefix.count))
                    break
                }
            }
        }

        return (id: id, name: name, controlType: ct, areaName: areaName)
    }

    private func hrefToId(_ href: String) -> Int {
        guard !href.isEmpty else { return 0 }
        return Int(href.split(separator: "/").last ?? "") ?? 0
    }

    private func fadeDuration(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}
