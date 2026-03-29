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
    }

    struct ApplianceInfo: Codable {
        let name: String
        let remainingMinutes: Int
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

    // MARK: - Widget Refresh

    static func reloadWidgets() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}
