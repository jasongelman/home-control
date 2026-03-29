import Foundation

enum RecommendationEngine {

    static func recommend(
        events: [UsageEvent],
        devices: [DeviceState],
        scenes: [LightScene],
        maxCount: Int,
        now: Date = Date()
    ) -> [SuggestedAction] {
        guard !events.isEmpty else { return [] }

        let bucket = TimeBucket.current(date: now)
        let thirtyDaysAgo = now.timeIntervalSince1970 - 30 * 24 * 60 * 60
        let deviceMap = Dictionary(uniqueKeysWithValues: devices.map { ($0.integrationId, $0) })

        var scored: [SuggestedAction: Double] = [:]

        // --- Score devices ---
        let bucketDeviceEvents = events.filter { e in
            e.type == .device
                && TimeBucket.current(date: Date(timeIntervalSince1970: e.timestamp)) == bucket
                && e.timestamp > thirtyDaysAgo
        }

        var deviceFrequency: [String: Int] = [:]
        var deviceLevels: [String: [Double]] = [:]
        var deviceRooms: [String: String] = [:]
        for e in bucketDeviceEvents {
            deviceFrequency[e.id, default: 0] += 1
            if let level = e.level { deviceLevels[e.id, default: []].append(level) }
            if let room = e.room { deviceRooms[e.id] = room }
        }

        for (idStr, count) in deviceFrequency {
            guard let deviceId = Int(idStr), let device = deviceMap[deviceId] else { continue }

            let levels = deviceLevels[idStr] ?? []
            let avgLevel = levels.isEmpty ? 0 : (levels.reduce(0, +) / Double(levels.count)).rounded()

            let currentLevel = device.level
            let tolerance: Double = 5

            if abs(currentLevel - avgLevel) < tolerance {
                if currentLevel > 0 {
                    let action = SuggestedAction(
                        type: .device, id: idStr, label: device.name,
                        subtitle: "Turn off", level: 0
                    )
                    scored[action] = Double(count) * 0.5
                }
                continue
            }

            let subtitle: String
            if avgLevel == 0 {
                subtitle = "Turn off"
            } else if device.type == .shade {
                subtitle = "Open to \(Int(avgLevel))%"
            } else {
                subtitle = "Set to \(Int(avgLevel))%"
            }

            let action = SuggestedAction(
                type: .device, id: idStr, label: device.name,
                subtitle: subtitle, level: avgLevel
            )
            scored[action] = Double(count)
        }

        // --- Score scenes ---
        let bucketSceneEvents = events.filter { e in
            e.type == .scene
                && TimeBucket.current(date: Date(timeIntervalSince1970: e.timestamp)) == bucket
                && e.timestamp > thirtyDaysAgo
        }

        var sceneFrequency: [String: Int] = [:]
        for e in bucketSceneEvents {
            sceneFrequency[e.id, default: 0] += 1
        }

        for (sceneId, count) in sceneFrequency {
            guard let scene = scenes.first(where: { $0.id == sceneId }) else { continue }

            let allAtTarget = scene.targets.allSatisfy { target in
                guard let device = deviceMap[target.deviceId] else { return false }
                return abs(device.level - target.level) < 5
            }
            if allAtTarget { continue }

            let action = SuggestedAction(
                type: .scene, id: sceneId, label: scene.name,
                subtitle: "\(scene.targets.count) devices", level: nil
            )
            scored[action] = Double(count) * 1.2
        }

        return scored
            .sorted { $0.value > $1.value }
            .prefix(maxCount)
            .map(\.key)
    }
}
