import Foundation
import HomeKit
import Observation

// MARK: - Models

enum HvacMode: String, Codable, CaseIterable {
    case heat, cool, auto, off

    var label: String {
        switch self {
        case .heat: return "Heat"
        case .cool: return "Cool"
        case .auto: return "Auto"
        case .off:  return "Off"
        }
    }

    var icon: String {
        switch self {
        case .heat: return "flame.fill"
        case .cool: return "snowflake"
        case .auto: return "arrow.left.arrow.right"
        case .off:  return "power"
        }
    }

    /// Map from HomeKit target heating/cooling value
    static func fromHomeKit(_ value: Int) -> HvacMode {
        switch value {
        case 0: return .off
        case 1: return .heat
        case 2: return .cool
        case 3: return .auto
        default: return .off
        }
    }

    /// Map to HomeKit target heating/cooling value
    var homeKitValue: Int {
        switch self {
        case .off:  return 0
        case .heat: return 1
        case .cool: return 2
        case .auto: return 3
        }
    }
}

struct EcobeeThermostat: Identifiable, Codable {
    var id: String { identifier }
    var identifier: String
    var name: String            // HomeKit name (may be serial number)
    var currentTemp: Double     // °F
    var desiredHeat: Double     // °F
    var desiredCool: Double     // °F
    var hvacMode: HvacMode
    var humidity: Int?
    var room: String?
    var lastUpdated: Date

    /// User-set display name, or falls back to HomeKit name
    var displayName: String {
        EcobeeManager.nameOverride(for: identifier) ?? name
    }
}

struct EcobeeRemoteSensor: Identifiable, Codable {
    var id: String
    var name: String
    var temp: Double?         // °F
    var occupancy: Bool
    var parentThermostatId: String
    var room: String?
}

// MARK: - Manager

@Observable
class EcobeeManager: NSObject, @unchecked Sendable {
    var thermostats: [EcobeeThermostat] = []
    var sensors: [EcobeeRemoteSensor] = []
    var isLoading = false
    var errorMessage: String?
    var hasThermostats: Bool { !thermostats.isEmpty }

    // MARK: - Name Overrides

    private static let nameOverridesKey = "ecobee-nameOverrides"

    static func nameOverride(for identifier: String) -> String? {
        let overrides = UserDefaults.standard.dictionary(forKey: nameOverridesKey) as? [String: String] ?? [:]
        let value = overrides[identifier]
        return (value?.isEmpty == true) ? nil : value
    }

    func setNameOverride(for identifier: String, name: String) {
        var overrides = UserDefaults.standard.dictionary(forKey: Self.nameOverridesKey) as? [String: String] ?? [:]
        if name.isEmpty {
            overrides.removeValue(forKey: identifier)
        } else {
            overrides[identifier] = name
        }
        UserDefaults.standard.set(overrides, forKey: Self.nameOverridesKey)
    }

    private var homeManager: HMHomeManager?
    private var pollTimer: Timer?
    private let pollInterval: TimeInterval = 60

    // Topology cache
    private var topologyCacheURL: URL? {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("ecobee-topology.json")
    }

    override init() {
        super.init()
        loadTopologyCache()
    }

    // MARK: - Public API

    func resume() {
        if homeManager == nil {
            homeManager = HMHomeManager()
            homeManager?.delegate = self
        }
        Task { await refreshFromHomeKit() }
        startPolling()
    }

    // MARK: - Actions

    func setTargetTemp(thermostatId: String, temp: Double) async throws {
        guard let accessory = findAccessory(thermostatId: thermostatId),
              let thermostatService = accessory.services.first(where: { $0.serviceType == HMServiceTypeThermostat }),
              let targetChar = thermostatService.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypeTargetTemperature }) else {
            throw NSError(domain: "EcobeeManager", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "Thermostat not found"])
        }

        let celsius = fahrenheitToCelsius(temp)
        try await targetChar.writeValue(celsius)

        // Optimistic update
        await MainActor.run {
            if let idx = thermostats.firstIndex(where: { $0.identifier == thermostatId }) {
                thermostats[idx].desiredHeat = temp
                thermostats[idx].desiredCool = temp
            }
        }
        try? await Task.sleep(for: .seconds(2))
        await refreshFromHomeKit()
    }

    func setHeatCoolTargets(thermostatId: String, heat: Double, cool: Double) async throws {
        guard let accessory = findAccessory(thermostatId: thermostatId),
              let thermostatService = accessory.services.first(where: { $0.serviceType == HMServiceTypeThermostat }) else {
            throw NSError(domain: "EcobeeManager", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "Thermostat not found"])
        }

        let heatChar = thermostatService.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypeHeatingThreshold })
        let coolChar = thermostatService.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypeCoolingThreshold })

        if let heatChar {
            try await heatChar.writeValue(fahrenheitToCelsius(heat))
        }
        if let coolChar {
            try await coolChar.writeValue(fahrenheitToCelsius(cool))
        }

        // Optimistic update
        await MainActor.run {
            if let idx = thermostats.firstIndex(where: { $0.identifier == thermostatId }) {
                thermostats[idx].desiredHeat = heat
                thermostats[idx].desiredCool = cool
            }
        }
        try? await Task.sleep(for: .seconds(2))
        await refreshFromHomeKit()
    }

    func setMode(thermostatId: String, mode: HvacMode) async throws {
        guard let accessory = findAccessory(thermostatId: thermostatId),
              let thermostatService = accessory.services.first(where: { $0.serviceType == HMServiceTypeThermostat }),
              let targetModeChar = thermostatService.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypeTargetHeatingCooling }) else {
            throw NSError(domain: "EcobeeManager", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "Thermostat not found"])
        }

        try await targetModeChar.writeValue(mode.homeKitValue)

        // Optimistic update
        await MainActor.run {
            if let idx = thermostats.firstIndex(where: { $0.identifier == thermostatId }) {
                thermostats[idx].hvacMode = mode
            }
        }
        try? await Task.sleep(for: .seconds(2))
        await refreshFromHomeKit()
    }

    // MARK: - Polling

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { await self?.refreshFromHomeKit() }
        }
    }

    // MARK: - HomeKit Data Refresh

    private func refreshFromHomeKit() async {
        guard let home = homeManager?.primaryHome ?? homeManager?.homes.first else {
            await MainActor.run {
                errorMessage = "No HomeKit home found"
            }
            return
        }

        var newThermostats: [EcobeeThermostat] = []
        var newSensors: [EcobeeRemoteSensor] = []

        for accessory in home.accessories {
            let thermostatService = accessory.services.first(where: { $0.serviceType == HMServiceTypeThermostat })
            let tempSensorService = accessory.services.first(where: { $0.serviceType == HMServiceTypeTemperatureSensor })

            if let service = thermostatService {
                // Read all characteristics
                for char in service.characteristics {
                    try? await char.readValue()
                }

                let currentTempC = service.characteristics
                    .first(where: { $0.characteristicType == HMCharacteristicTypeCurrentTemperature })?
                    .value as? Double ?? 0
                let targetTempC = service.characteristics
                    .first(where: { $0.characteristicType == HMCharacteristicTypeTargetTemperature })?
                    .value as? Double ?? 0
                let targetMode = service.characteristics
                    .first(where: { $0.characteristicType == HMCharacteristicTypeTargetHeatingCooling })?
                    .value as? Int ?? 0
                let humidity = service.characteristics
                    .first(where: { $0.characteristicType == HMCharacteristicTypeCurrentRelativeHumidity })?
                    .value as? Double

                // In auto mode, check for heat/cool thresholds
                let heatThresholdC = service.characteristics
                    .first(where: { $0.characteristicType == HMCharacteristicTypeHeatingThreshold })?
                    .value as? Double ?? targetTempC
                let coolThresholdC = service.characteristics
                    .first(where: { $0.characteristicType == HMCharacteristicTypeCoolingThreshold })?
                    .value as? Double ?? targetTempC

                let mode = HvacMode.fromHomeKit(targetMode)

                let thermostat = EcobeeThermostat(
                    identifier: accessory.uniqueIdentifier.uuidString,
                    name: accessory.name,
                    currentTemp: celsiusToFahrenheit(currentTempC),
                    desiredHeat: mode == .auto ? celsiusToFahrenheit(heatThresholdC) : celsiusToFahrenheit(targetTempC),
                    desiredCool: mode == .auto ? celsiusToFahrenheit(coolThresholdC) : celsiusToFahrenheit(targetTempC),
                    hvacMode: mode,
                    humidity: humidity != nil ? Int(humidity!) : nil,
                    room: accessory.room?.name,
                    lastUpdated: Date()
                )
                newThermostats.append(thermostat)
            } else if let service = tempSensorService, thermostatService == nil {
                // Standalone temperature sensor (likely a remote sensor)
                for char in service.characteristics {
                    try? await char.readValue()
                }

                let tempC = service.characteristics
                    .first(where: { $0.characteristicType == HMCharacteristicTypeCurrentTemperature })?
                    .value as? Double

                // Check for occupancy sensor on same accessory
                let occupancyService = accessory.services.first(where: { $0.serviceType == HMServiceTypeOccupancySensor })
                var occupancy = false
                if let occService = occupancyService {
                    for char in occService.characteristics {
                        try? await char.readValue()
                    }
                    occupancy = occService.characteristics
                        .first(where: { $0.characteristicType == HMCharacteristicTypeOccupancyDetected })?
                        .value as? Bool ?? false
                }

                newSensors.append(EcobeeRemoteSensor(
                    id: accessory.uniqueIdentifier.uuidString,
                    name: accessory.name,
                    temp: tempC != nil ? celsiusToFahrenheit(tempC!) : nil,
                    occupancy: occupancy,
                    parentThermostatId: "",
                    room: accessory.room?.name
                ))
            }
        }

        let hasData = !newThermostats.isEmpty
        await MainActor.run {
            if hasData {
                thermostats = newThermostats
                sensors = newSensors
                errorMessage = nil
            }
        }

        if hasData {
            saveTopologyCache()
        }
    }

    // MARK: - Helpers

    private func findAccessory(thermostatId: String) -> HMAccessory? {
        guard let home = homeManager?.primaryHome ?? homeManager?.homes.first else { return nil }
        return home.accessories.first(where: { $0.uniqueIdentifier.uuidString == thermostatId })
    }

    private func celsiusToFahrenheit(_ c: Double) -> Double {
        (c * 9.0 / 5.0) + 32.0
    }

    private func fahrenheitToCelsius(_ f: Double) -> Double {
        (f - 32.0) * 5.0 / 9.0
    }

    // MARK: - Topology cache

    private struct CachedTopology: Codable {
        var thermostats: [EcobeeThermostat]
        var sensors: [EcobeeRemoteSensor]
    }

    private func loadTopologyCache() {
        guard let url = topologyCacheURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(CachedTopology.self, from: data) else {
            return
        }
        thermostats = cache.thermostats
        sensors = cache.sensors
    }

    private func saveTopologyCache() {
        guard let url = topologyCacheURL else { return }
        let cache = CachedTopology(thermostats: thermostats, sensors: sensors)
        do {
            let data = try JSONEncoder().encode(cache)
            try data.write(to: url, options: .atomic)
        } catch {
            print("EcobeeManager: failed to write topology cache — \(error.localizedDescription)")
        }
    }
}

// MARK: - HMHomeManagerDelegate

extension EcobeeManager: HMHomeManagerDelegate {
    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        Task { await refreshFromHomeKit() }
    }
}
