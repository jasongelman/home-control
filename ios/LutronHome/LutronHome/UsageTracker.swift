import Foundation
import Observation

// MARK: - Usage Event

struct UsageEvent: Codable {
    enum EventType: String, Codable {
        case device
        case scene
    }
    enum Action: String, Codable {
        case setLevel
        case activate
        case turnOff
    }

    let type: EventType
    let id: String // Device integrationId (as string) or scene ID
    let action: Action
    let level: Double?
    let room: String?
    let timestamp: Double
}

// MARK: - Time Buckets

enum TimeBucket: String, CaseIterable {
    case morning
    case afternoon
    case evening
    case night

    static func current(date: Date = Date()) -> TimeBucket {
        let hour = Calendar.current.component(.hour, from: date)
        if hour >= 5 && hour < 12 { return .morning }
        if hour >= 12 && hour < 18 { return .afternoon }
        if hour >= 18 || hour < 2 { return .evening }
        return .night
    }
}

// MARK: - Detected Pattern

struct DetectedPattern: Identifiable {
    let hash: String
    let devices: [(id: Int, avgLevel: Double, room: String?)]
    let timeOfDay: String?
    let frequency: Int

    var id: String { hash }
}

// MARK: - Usage Tracker

@Observable
class UsageTracker {
    private static let storageKey = "lutron_usage_log"
    private static let dismissedKey = "lutron_dismissed_patterns"
    private static let maxEvents = 2000

    private(set) var events: [UsageEvent] = []
    private(set) var dismissedPatterns: Set<String> = []

    init() {
        loadEvents()
        loadDismissed()
    }

    // MARK: - Track Actions

    func trackDevice(_ deviceId: Int, action: UsageEvent.Action, room: String? = nil, level: Double? = nil) {
        let event = UsageEvent(
            type: .device,
            id: String(deviceId),
            action: action,
            level: level,
            room: room,
            timestamp: Date().timeIntervalSince1970
        )
        events.append(event)
        saveEvents()
    }

    func trackScene(_ sceneId: String) {
        let event = UsageEvent(
            type: .scene,
            id: sceneId,
            action: .activate,
            level: nil,
            room: nil,
            timestamp: Date().timeIntervalSince1970
        )
        events.append(event)
        saveEvents()
    }

    // MARK: - Queries

    func topDevices(_ n: Int, timeWindowSeconds: TimeInterval? = nil) -> [(id: String, room: String?, count: Int)] {
        let now = Date().timeIntervalSince1970
        let filtered = events.filter { e in
            guard e.type == .device else { return false }
            if let window = timeWindowSeconds, now - e.timestamp > window { return false }
            return true
        }

        var counts: [String: (room: String?, count: Int, lastUsed: Double)] = [:]
        for e in filtered {
            if var existing = counts[e.id] {
                existing.count += 1
                if e.timestamp > existing.lastUsed { existing.lastUsed = e.timestamp }
                counts[e.id] = existing
            } else {
                counts[e.id] = (room: e.room, count: 1, lastUsed: e.timestamp)
            }
        }

        return counts.map { (id: $0.key, room: $0.value.room, count: $0.value.count) }
            .sorted { $0.count > $1.count }
            .prefix(n)
            .map { $0 }
    }

    func topScenes(_ n: Int) -> [(id: String, count: Int)] {
        let filtered = events.filter { $0.type == .scene }
        var counts: [String: Int] = [:]
        for e in filtered { counts[e.id, default: 0] += 1 }
        return counts.map { (id: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
            .prefix(n)
            .map { $0 }
    }

    /// Room usage scores for the given time bucket
    func roomScores(for bucket: TimeBucket) -> [String: Int] {
        let bucketEvents = events.filter { e in
            guard let room = e.room else { return false }
            return TimeBucket.current(date: Date(timeIntervalSince1970: e.timestamp)) == bucket
        }
        var scores: [String: Int] = [:]
        for e in bucketEvents {
            if let room = e.room {
                scores[room, default: 0] += 1
            }
        }
        return scores
    }

    /// Sort rooms by relevance: time-of-day frequency (60%) + recent usage (40%)
    func sortedRoomNames(available: [String]) -> [String] {
        guard !events.isEmpty else { return available.sorted() }

        let bucket = TimeBucket.current()
        let bucketScores = roomScores(for: bucket)

        let now = Date().timeIntervalSince1970
        let sevenDays: TimeInterval = 7 * 24 * 60 * 60
        let recentEvents = events.filter { e in
            e.room != nil && now - e.timestamp < sevenDays
        }
        var recentScores: [String: Int] = [:]
        for e in recentEvents {
            if let room = e.room { recentScores[room, default: 0] += 1 }
        }

        let maxBucket = Double(max(1, bucketScores.values.max() ?? 1))
        let maxRecent = Double(max(1, recentScores.values.max() ?? 1))

        let scored = available.map { name -> (name: String, score: Double) in
            let bs = Double(bucketScores[name] ?? 0) / maxBucket * 0.6
            let rs = Double(recentScores[name] ?? 0) / maxRecent * 0.4
            return (name: name, score: bs + rs)
        }

        let withScore = scored.filter { $0.score > 0 }.sorted { $0.score > $1.score }
        let noScore = scored.filter { $0.score == 0 }.sorted { $0.name < $1.name }
        return (withScore + noScore).map(\.name)
    }

    // MARK: - Pattern Detection

    func detectPatterns() -> [DetectedPattern] {
        guard events.count >= 10 else { return [] }

        let sessions = buildSessions()
        guard sessions.count >= 3 else { return [] }

        var groups: [String: [Session]] = [:]
        for session in sessions {
            let fp = session.fingerprint
            groups[fp, default: []].append(session)
        }

        var patterns: [DetectedPattern] = []
        for (fp, group) in groups {
            guard group.count >= 3 else { continue }
            let hash = simpleHash(fp)
            guard !dismissedPatterns.contains(hash) else { continue }

            let deviceIds = Array(group[0].devices.keys).sorted()
            let devices: [(id: Int, avgLevel: Double, room: String?)] = deviceIds.map { id in
                var allLevels: [Double] = []
                var room: String?
                for session in group {
                    if let data = session.devices[id] {
                        allLevels.append(contentsOf: data.levels)
                        if let r = data.room { room = r }
                    }
                }
                let avg = allLevels.isEmpty ? 0 : allLevels.reduce(0, +) / Double(allLevels.count)
                return (id: id, avgLevel: avg.rounded(), room: room)
            }

            // Most common time of day
            var timeCounts: [String: Int] = [:]
            for session in group {
                let bucket = TimeBucket.current(date: Date(timeIntervalSince1970: session.startTime))
                timeCounts[bucket.rawValue, default: 0] += 1
            }
            let timeOfDay = timeCounts.max(by: { $0.value < $1.value })?.key

            patterns.append(DetectedPattern(
                hash: hash,
                devices: devices,
                timeOfDay: timeOfDay,
                frequency: group.count
            ))
        }

        return patterns.sorted { $0.frequency > $1.frequency }
    }

    func dismissPattern(_ hash: String) {
        dismissedPatterns.insert(hash)
        saveDismissed()
    }

    // MARK: - Session Building

    private struct SessionDeviceData {
        var levels: [Double]
        var room: String?
    }

    private struct Session {
        var devices: [Int: SessionDeviceData]
        var startTime: Double

        var fingerprint: String {
            devices.keys.sorted().map { id in
                let data = devices[id]!
                let avg = data.levels.isEmpty ? 0 : data.levels.reduce(0, +) / Double(data.levels.count)
                let bucketed = Int((avg / 10).rounded()) * 10
                return "\(id):\(bucketed)"
            }.joined(separator: "|")
        }
    }

    private func buildSessions() -> [Session] {
        let deviceEvents = events.filter { $0.type == .device }
        guard let first = deviceEvents.first else { return [] }

        let sessionGap: TimeInterval = 5 * 60

        var sessions: [Session] = []
        var current = Session(devices: [:], startTime: first.timestamp)

        for e in deviceEvents {
            if e.timestamp - current.startTime > sessionGap && !current.devices.isEmpty {
                if current.devices.count >= 2 { sessions.append(current) }
                current = Session(devices: [:], startTime: e.timestamp)
            }

            guard let id = Int(e.id) else { continue }
            if var existing = current.devices[id] {
                if let level = e.level { existing.levels.append(level) }
                current.devices[id] = existing
            } else {
                current.devices[id] = SessionDeviceData(
                    levels: e.level.map { [$0] } ?? [],
                    room: e.room
                )
            }
        }
        if current.devices.count >= 2 { sessions.append(current) }

        return sessions
    }

    private func simpleHash(_ str: String) -> String {
        var hash: UInt64 = 5381
        for byte in str.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return String(hash, radix: 36)
    }

    // MARK: - Persistence

    private func loadEvents() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([UsageEvent].self, from: data) else { return }
        events = decoded
    }

    private func saveEvents() {
        // Trim to max
        if events.count > Self.maxEvents {
            events = Array(events.suffix(Self.maxEvents))
        }
        if let data = try? JSONEncoder().encode(events) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
        // Sync to App Group for widget
        AppGroupManager.writeUsageEvents(events)
    }

    private func loadDismissed() {
        guard let arr = UserDefaults.standard.array(forKey: Self.dismissedKey) as? [String] else { return }
        dismissedPatterns = Set(arr)
    }

    private func saveDismissed() {
        UserDefaults.standard.set(Array(dismissedPatterns), forKey: Self.dismissedKey)
    }
}
