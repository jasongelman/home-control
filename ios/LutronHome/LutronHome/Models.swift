import Foundation

enum DeviceType: String, Codable {
    case light
    case shade
    case keypad
}

/// High-level device category for grouping in the UI
enum DeviceCategory: String, Codable, CaseIterable {
    case light = "Lights"
    case shadesAndDrapes = "Shades & Drapes"
    case outlet = "Outlets"
    case fan = "Fans"
    case window = "Windows"

    var icon: String {
        switch self {
        case .light: return "lightbulb.fill"
        case .shadesAndDrapes: return "blinds.vertical.open"
        case .outlet: return "poweroutlet.type.b"
        case .fan: return "fan"
        case .window: return "window.vertical.open"
        }
    }

    /// Classify a zone by its LEAP controlType and name
    static func classify(controlType: String, name: String) -> DeviceCategory {
        let lower = name.lowercased()

        // CCO = Window Film
        if controlType == "CCO" { return .window }

        // Shade control type
        if controlType == "Shade" { return .shadesAndDrapes }

        // Outlets (by name)
        if lower.contains("outlet") { return .outlet }

        // Fans (switched)
        if lower.contains("fan") { return .fan }

        // Exterior switched lights (not outlets/fans)
        let exteriorSwitchedNames: Set<String> = [
            "landscape", "main entry ext - x100-01",
            "garage sconces - x101-02", "garage floods",
            "back yard floods", "deck - x102-02",
            "garage surface", "stairs recessed"
        ]
        if controlType == "Switched" && exteriorSwitchedNames.contains(lower) {
            return .light
        }

        // Outlets (switched with outlet-like names or unknown zones)
        if controlType == "Switched" {
            return .outlet
        }

        // Everything else (Dimmed) = lights
        return .light
    }
}

struct KeypadComponent: Codable, Identifiable {
    let id: Int
    let name: String
}

struct DeviceState: Codable, Identifiable {
    let integrationId: Int
    var name: String
    var type: DeviceType
    var category: DeviceCategory
    var room: String
    var level: Double
    var components: [KeypadComponent]?
    var lastUpdated: Double

    var id: Int { integrationId }
    var isOn: Bool { level > 0 }
    var brightnessPercent: Int { Int(level.rounded()) }
}

// MARK: - Floor Mapping

enum Floor: String, CaseIterable {
    case upstairs = "Upstairs"
    case mainFloor = "Main Floor"
    case downstairs = "Downstairs"
    case exterior = "Exterior"

    static let roomMap: [String: Floor] = [
        // Upstairs
        "Guest Bedroom": .upstairs,
        "Guest Bathroom": .upstairs,
        "Playroom": .upstairs,
        "Secret Room": .upstairs,
        "Upper Level": .upstairs,
        // Main Floor
        "Dining Room": .mainFloor,
        "Family Room": .mainFloor,
        "Kitchen": .mainFloor,
        "Jason Office": .mainFloor,
        "Rachel Office": .mainFloor,
        "Living Room": .mainFloor,
        "Main Entry": .mainFloor,
        "Main Hall": .mainFloor,
        "Mudroom": .mainFloor,
        "Breakfast Nook": .mainFloor,
        "Powder Room": .mainFloor,
        "Main Level": .mainFloor,
        "Gelman": .mainFloor,
        // Downstairs
        "Ronan's Room": .downstairs,
        "Sebastian's Room": .downstairs,
        "Hallway And Stairs": .downstairs,
        "Laundry": .downstairs,
        "Master Suite": .downstairs,
        "Primary Bedroom": .downstairs,
        "Primary Bathroom": .downstairs,
        "Rachel Closet": .downstairs,
        "Jason Closet": .downstairs,
        "Nanny Suite": .downstairs,
        "Shared Bathroom": .downstairs,
        "Gym": .downstairs,
        "Lower Level": .downstairs,
        "Mechanical": .downstairs,
        // Exterior
        "Front": .exterior,
        "Driveway": .exterior,
        "Rear": .exterior,
        "Garage": .exterior,
        "Exterior": .exterior,
    ]

    static func floor(for room: String) -> Floor {
        roomMap[room] ?? .mainFloor
    }

    var icon: String {
        switch self {
        case .upstairs: return "arrow.up"
        case .mainFloor: return "house"
        case .downstairs: return "arrow.down"
        case .exterior: return "tree"
        }
    }
}

struct SceneDeviceTarget: Codable {
    let deviceId: Int
    let level: Double
}

struct LightScene: Codable, Identifiable {
    let id: String
    var name: String
    var icon: String
    var targets: [SceneDeviceTarget]
    var createdAt: Double
    var updatedAt: Double
}
