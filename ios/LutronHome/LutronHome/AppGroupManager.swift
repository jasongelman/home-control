import Foundation
import WidgetKit

struct AppGroupManager {
    static let suiteName = "group.com.jasongelman.homecontrol"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    private enum Key {
        static let devices = "widget_devices"
        static let scenes = "widget_scenes"
        static let usageEvents = "widget_usage_events"
        static let lightsOnCount = "widget_lights_on_count"
        static let serverHost = "widget_server_host"
        static let applianceStatus = "widget_appliance_status"
        static let widgetData = "widget_data_snapshot"
        static let statusCells = "widget_status_cells"
    }

    struct ApplianceInfo: Codable {
        let name: String
        let remainingMinutes: Int
    }

    // MARK: - Widget status snapshot types (shared with widget target)

    struct StatusCellSnapshot: Codable, Identifiable {
        var id: String
        var label: String
        var value: String
        var suffix: String?
        var isActive: Bool
        var isAlarming: Bool
    }

    struct WidgetDataSnapshot: Codable {
        var lastUpdated: Date = Date()
        var thermostats: [ThermostatSnapshot] = []
        var alarm: AlarmSnapshot? = nil
        var dishwashers: [ApplianceSnapshot] = []
        var smartHQAppliances: [ApplianceSnapshot] = []
        var garageDoors: [GarageSnapshot] = []
        var heatPump: HeatPumpSnapshot? = nil
        var sonosCoordinators: [SonosSnapshot] = []
        var lights: LightsSnapshot? = nil
    }

    struct ThermostatSnapshot: Codable {
        var id: String
        var name: String
        var currentTemp: Double
        var modeLabel: String
        var isOn: Bool
    }

    struct AlarmSnapshot: Codable {
        var stateLabel: String
        var isArmed: Bool
        var isAlarming: Bool
        var faultCount: Int
    }

    struct ApplianceSnapshot: Codable {
        var id: String
        var label: String
        var value: String
        var isActive: Bool
    }

    struct GarageSnapshot: Codable {
        var id: String
        var stateLabel: String
        var isActive: Bool
    }

    struct HeatPumpSnapshot: Codable {
        var connected: Bool
        var outdoorTemp: Double?
        var operatingMode: String?
    }

    struct SonosSnapshot: Codable {
        var id: String
        var name: String
        var isPlaying: Bool
        var trackTitle: String?
    }

    struct LightsSnapshot: Codable {
        var connected: Bool
        var onCount: Int
    }

    // MARK: - Write (called from main app)

    static func writeDevices(_ devices: [Int: DeviceState]) {
        guard let defaults else { return }
        let array = Array(devices.values)
        if let data = try? JSONEncoder().encode(array) {
            defaults.set(data, forKey: Key.devices)
        }
        let lightsOn = array.filter { $0.category == .light && $0.level > 0 }.count
        defaults.set(lightsOn, forKey: Key.lightsOnCount)
    }

    static func writeScenes(_ scenes: [LightScene]) {
        guard let defaults else { return }
        if let data = try? JSONEncoder().encode(scenes) {
            defaults.set(data, forKey: Key.scenes)
        }
    }

    static func writeUsageEvents(_ events: [UsageEvent]) {
        guard let defaults else { return }
        if let data = try? JSONEncoder().encode(events) {
            defaults.set(data, forKey: Key.usageEvents)
        }
    }

    static func writeServerHost(_ host: String) {
        guard let defaults else { return }
        defaults.set(host, forKey: Key.serverHost)
    }

    static func writeApplianceStatus(_ appliances: [ApplianceInfo]) {
        guard let defaults else { return }
        if let data = try? JSONEncoder().encode(appliances) {
            defaults.set(data, forKey: Key.applianceStatus)
        }
    }

    static func writeWidgetData(_ snapshot: WidgetDataSnapshot) {
        guard let defaults else { return }
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Key.widgetData)
        }
        let cells = buildStatusCells(from: snapshot)
        if let data = try? JSONEncoder().encode(cells) {
            defaults.set(data, forKey: Key.statusCells)
        }
    }

    // MARK: - Read (called from widget / intents)

    static func readDevices() -> [DeviceState] {
        guard let defaults,
              let data = defaults.data(forKey: Key.devices),
              let devices = try? JSONDecoder().decode([DeviceState].self, from: data) else { return [] }
        return devices
    }

    static func readScenes() -> [LightScene] {
        guard let defaults,
              let data = defaults.data(forKey: Key.scenes),
              let scenes = try? JSONDecoder().decode([LightScene].self, from: data) else { return [] }
        return scenes
    }

    static func readUsageEvents() -> [UsageEvent] {
        guard let defaults,
              let data = defaults.data(forKey: Key.usageEvents),
              let events = try? JSONDecoder().decode([UsageEvent].self, from: data) else { return [] }
        return events
    }

    static func readLightsOnCount() -> Int {
        defaults?.integer(forKey: Key.lightsOnCount) ?? 0
    }

    static func readServerHost() -> String {
        defaults?.string(forKey: Key.serverHost) ?? "192.168.1.191"
    }

    static func readApplianceStatus() -> [AppGroupManager.ApplianceInfo] {
        guard let defaults,
              let data = defaults.data(forKey: Key.applianceStatus),
              let appliances = try? JSONDecoder().decode([ApplianceInfo].self, from: data) else { return [] }
        return appliances
    }

    static func readWidgetData() -> WidgetDataSnapshot {
        guard let defaults,
              let data = defaults.data(forKey: Key.widgetData),
              let snapshot = try? JSONDecoder().decode(WidgetDataSnapshot.self, from: data) else {
            return WidgetDataSnapshot()
        }
        return snapshot
    }

    static func readStatusCells() -> [StatusCellSnapshot] {
        guard let defaults,
              let data = defaults.data(forKey: Key.statusCells),
              let cells = try? JSONDecoder().decode([StatusCellSnapshot].self, from: data) else { return [] }
        return cells
    }

    // MARK: - Build status cells from snapshot

    /// Pure function that mirrors `ContentView.statusCells` ordering and formatting.
    /// Keep in sync with the dashboard in `ContentView.swift`.
    static func buildStatusCells(from snapshot: WidgetDataSnapshot) -> [StatusCellSnapshot] {
        var cells: [StatusCellSnapshot] = []

        // Thermostats (first — top row)
        for thermo in snapshot.thermostats {
            cells.append(StatusCellSnapshot(
                id: "thermo_\(thermo.id)",
                label: thermo.name,
                value: "\(Int(thermo.currentTemp))°",
                suffix: thermo.modeLabel,
                isActive: thermo.isOn,
                isAlarming: false
            ))
        }

        // Alarm
        if let alarm = snapshot.alarm {
            let suffix: String? = alarm.faultCount > 0 ? "\(alarm.faultCount)f" : nil
            let active = alarm.isArmed || alarm.isAlarming || alarm.faultCount > 0
            cells.append(StatusCellSnapshot(
                id: "alarm",
                label: "Alarm",
                value: alarm.stateLabel,
                suffix: suffix,
                isActive: active,
                isAlarming: alarm.isAlarming
            ))
        }

        // Dishwashers
        for dw in snapshot.dishwashers {
            cells.append(StatusCellSnapshot(
                id: "dw_\(dw.id)",
                label: dw.label,
                value: dw.value,
                suffix: nil,
                isActive: dw.isActive,
                isAlarming: false
            ))
        }

        // Washer / Dryer
        for app in snapshot.smartHQAppliances {
            cells.append(StatusCellSnapshot(
                id: "shq_\(app.id)",
                label: app.label,
                value: app.value,
                suffix: nil,
                isActive: app.isActive,
                isAlarming: false
            ))
        }

        // Garage
        for door in snapshot.garageDoors {
            cells.append(StatusCellSnapshot(
                id: "garage_\(door.id)",
                label: "Garage",
                value: door.stateLabel,
                suffix: nil,
                isActive: door.isActive,
                isAlarming: false
            ))
        }

        // Heat Pump
        if let hp = snapshot.heatPump, hp.connected {
            let value: String
            var suffix: String? = nil
            if let temp = hp.outdoorTemp {
                value = "\(Int(temp))°F"
                if let mode = hp.operatingMode {
                    switch mode {
                    case "Heating": suffix = "Heat"
                    case "Cooling": suffix = "Cool"
                    case "Hot Water": suffix = "HW"
                    default: break
                    }
                }
            } else {
                value = hp.operatingMode ?? "—"
            }
            cells.append(StatusCellSnapshot(
                id: "hvac",
                label: "HVAC",
                value: value,
                suffix: suffix,
                isActive: true,
                isAlarming: false
            ))
        }

        // Sonos speakers
        for player in snapshot.sonosCoordinators {
            let value = player.isPlaying ? (player.trackTitle ?? "Playing") : "Off"
            cells.append(StatusCellSnapshot(
                id: "sonos_\(player.id)",
                label: player.name,
                value: value,
                suffix: nil,
                isActive: player.isPlaying,
                isAlarming: false
            ))
        }

        // Lutron lights summary
        if let lights = snapshot.lights, lights.connected {
            let value = lights.onCount == 0 ? "All off" : "\(lights.onCount) on"
            cells.append(StatusCellSnapshot(
                id: "lights",
                label: "Lights",
                value: value,
                suffix: nil,
                isActive: lights.onCount > 0,
                isAlarming: false
            ))
        }

        return cells
    }

    // MARK: - Widget Refresh

    static func reloadWidgets() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}
