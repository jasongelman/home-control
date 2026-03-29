import Foundation

struct SuggestedAction: Codable, Identifiable {
    enum ActionType: String, Codable {
        case device
        case scene
    }

    let type: ActionType
    let id: String
    let label: String
    let subtitle: String
    let level: Double?
}

extension SuggestedAction: Hashable {
    static func == (lhs: SuggestedAction, rhs: SuggestedAction) -> Bool {
        lhs.type == rhs.type && lhs.id == rhs.id && lhs.level == rhs.level
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(type)
        hasher.combine(id)
        hasher.combine(level)
    }
}
