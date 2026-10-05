import SwiftUI

struct EditorialSuggestedAction: View {
    @Environment(LutronStore.self) var store

    private let actions = SunCalculator.contextualActions()

    var body: some View {
        if let action = actions.first {
            Button {
                handleAction(action.id)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(action.title.uppercased())
                            .font(EditorialTheme.bebasNeue(size: 36))
                            .foregroundStyle(.white)
                        Spacer()
                        Image(systemName: "arrow.right")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                    Text(actionSubtitle(action.id))
                        .font(.system(size: 9, weight: .medium))
                        .tracking(0.6)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: EditorialTheme.cardRadius)
                        .fill(EditorialTheme.accent)
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func actionSubtitle(_ id: String) -> String {
        switch id {
        case "evening":
            let lightCount = store.devices.values.filter { $0.category == .light && $0.level > 0 }.count
            return "\(lightCount) LIGHTS · SHADES ▼ · WARM DIM"
        case "morning":
            return "KITCHEN · FAMILY ROOM · BRIGHT"
        case "shades_open":
            return "DINING · FAMILY ROOM · FULL OPEN"
        case "shades_close":
            return "DINING · FAMILY ROOM · FULL CLOSE"
        case "all_off":
            let lightCount = store.devices.values.filter { $0.category == .light && $0.level > 0 }.count
            return "\(lightCount) LIGHTS OFF · EXCEPT SEBASTIAN"
        case "goodnight":
            return "ALL LIGHTS OFF · EXCEPT SEBASTIAN"
        case "rise_and_shine":
            return "ALL DOWNSTAIRS SHADES · FULL OPEN"
        case "block_sun":
            return "FAMILY REAR · DINING · JASON OFFICE SOLAR"
        default:
            return ""
        }
    }

    private func handleAction(_ id: String) {
        store.performBulk(id) { runAction(id) }
    }

    private func runAction(_ id: String) {
        switch id {
        case "morning":
            store.setRoomLights("Kitchen", level: 60)
            store.setRoomLights("Family Room", level: 40)
        case "shades_open", "shades_close":
            store.toggleMainShades()
        case "all_off":
            store.turnOffAllLights(excludingNames: ["Bed 2 Entry"])
        case "evening":
            store.activateEveningScene()
        case "goodnight":
            store.turnOffAllLights(excludingRooms: ["Sebastian's Room"])
        case "rise_and_shine":
            store.raiseDownstairsShades()
        case "block_sun":
            store.blockOutTheSun()
        default:
            break
        }
    }
}

// MARK: - For You (presets learned from usage history)

/// A one-tap preset learned from what the user usually does around this time of day.
struct LearnedPreset: Identifiable {
    let id: String
    let title: String
    let detail: String
    let targets: [(deviceId: Int, level: Double)]
    let score: Double
}

enum LearnedPresetEngine {
    /// Usage within ±window of the current time of day counts as "around now".
    private static let window: TimeInterval = 2 * 60 * 60
    private static let lookback: TimeInterval = 30 * 24 * 60 * 60
    /// A device must have been set this many times around now before we suggest it.
    private static let minCount = 2
    private static let offWeight = 0.35

    static func presets(events: [UsageEvent],
                        patterns: [DetectedPattern],
                        devices: [Int: DeviceState],
                        maxCount: Int = 4,
                        now: Date = Date()) -> [LearnedPreset] {
        let nowTs = now.timeIntervalSince1970
        let nowSecs = secondsIntoDay(now)

        // 1. Per-device habits around this time of day. Older builds logged every step of a
        // drag, so collapse bursts on the same device (<3s apart) to the level it settled on.
        var deviceEvents = events.filter { $0.type == .device && nowTs - $0.timestamp < lookback }
            .sorted { $0.timestamp < $1.timestamp }
        // Older builds also logged bulk "all off" actions once per light; drop those bursts
        // (5+ lights turned off within 2s) — bulk actions are now a single `.bulk` event.
        var bulkOff = Set<Int>()
        var start = 0
        while start < deviceEvents.count {
            var end = start
            while end < deviceEvents.count, deviceEvents[end].timestamp - deviceEvents[start].timestamp < 2 { end += 1 }
            if deviceEvents[start..<end].filter({ $0.action == .turnOff }).count >= 5 {
                bulkOff.formUnion(start..<end)
                start = end
            } else {
                start += 1
            }
        }
        deviceEvents = deviceEvents.enumerated().filter { !bulkOff.contains($0.offset) }.map(\.element)
        var settled: [UsageEvent] = []
        var lastIndexById: [String: Int] = [:]
        for e in deviceEvents {
            if let i = lastIndexById[e.id], e.timestamp - settled[i].timestamp < 3 {
                settled[i] = e
            } else {
                lastIndexById[e.id] = settled.count
                settled.append(e)
            }
        }
        var levelsById: [Int: [Double]] = [:]
        for e in settled {
            guard let id = Int(e.id), let level = e.level else { continue }
            let secs = secondsIntoDay(Date(timeIntervalSince1970: e.timestamp))
            let diff = abs(secs - nowSecs)
            guard min(diff, 86_400 - diff) <= window else { continue }
            levelsById[id, default: []].append(level)
        }

        struct Habit { let device: DeviceState; let level: Double; let count: Int }
        var habits: [Habit] = []
        for (id, levels) in levelsById where levels.count >= minCount {
            guard let device = devices[id] else { continue }
            let target = (median(levels) / 5).rounded() * 5
            // Already where the user usually puts it — nothing to suggest.
            guard abs(device.level - target) >= 5 else { continue }
            habits.append(Habit(device: device, level: target, count: levels.count))
        }

        // 2. Merge habits in the same room with the same target into one room preset.
        var presets: [LearnedPreset] = []
        let byRoomAndLevel = Dictionary(grouping: habits) { "\($0.device.room)|\(Int($0.level))" }
        for (key, group) in byRoomAndLevel {
            let first = group[0]
            let room = first.device.room
            let roomTotal = devices.values.filter { $0.room == room && $0.category == first.device.category }.count
            let title: String
            if group.count == 1 {
                title = "\(room) \(deviceDisplayName(first.device))"
            } else if group.count == roomTotal {
                title = room
            } else {
                title = "\(room) · \(group.count)"
            }
            presets.append(LearnedPreset(
                id: "habit_\(key)",
                title: title,
                detail: levelLabel(first.level, category: first.device.category),
                targets: group.map { ($0.device.integrationId, $0.level) },
                // Levels you deliberately choose beat "turn it off" — the ALL OFF button covers that.
                score: Double(group.reduce(0) { $0 + $1.count }) * (first.level == 0 ? offWeight : 1)
            ))
        }

        // 3. Recurring multi-device combos (the pattern detector), if one fits this time of day.
        let bucket = TimeBucket.current(date: now).rawValue
        for pattern in patterns where pattern.timeOfDay == bucket {
            let targets = pattern.devices.compactMap { d -> (deviceId: Int, level: Double)? in
                devices[d.id] == nil ? nil : (d.id, d.avgLevel)
            }
            let pending = targets.filter { t in abs((devices[t.deviceId]?.level ?? 0) - t.level) >= 5 }
            guard targets.count >= 2, !pending.isEmpty else { continue }
            let rooms = Array(Set(targets.compactMap { devices[$0.deviceId]?.room })).sorted()
            presets.append(LearnedPreset(
                id: "pattern_\(pattern.hash)",
                title: rooms.count <= 2 ? rooms.joined(separator: " + ") : "Your usual \(bucket)",
                detail: "\(targets.count) LIGHTS · \(pattern.frequency)×",
                targets: targets,
                score: Double(pattern.frequency * targets.count)
            ))
            break
        }

        return Array(presets.sorted { $0.score > $1.score }.prefix(maxCount))
    }

    private static func levelLabel(_ level: Double, category: DeviceCategory) -> String {
        let isShade = category == .shadesAndDrapes || category == .window
        if level == 0 { return isShade ? "CLOSE" : "OFF" }
        if isShade { return level == 100 ? "OPEN" : "OPEN \(Int(level))%" }
        return "\(Int(level))%"
    }

    private static func secondsIntoDay(_ date: Date) -> TimeInterval {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return TimeInterval((c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60)
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

struct EditorialForYouRow: View {
    @Environment(LutronStore.self) var store
    @Environment(UsageTracker.self) var usageTracker

    var body: some View {
        let presets = LearnedPresetEngine.presets(
            events: usageTracker.events,
            patterns: usageTracker.detectPatterns(),
            devices: store.devices
        )
        if !presets.isEmpty {
            VStack(alignment: .leading, spacing: EditorialTheme.gridSpacing) {
                EditorialSectionHeader(
                    title: "FOR YOU",
                    trailing: TimeBucket.current().rawValue.uppercased()
                )
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(presets) { preset in
                        Button {
                            for t in preset.targets {
                                store.setLevel(t.deviceId, level: t.level, fadeTime: 1)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(preset.title.uppercased())
                                    .font(.system(size: 10, weight: .bold))
                                    .tracking(0.5)
                                    .foregroundStyle(EditorialTheme.primaryText)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Text(preset.detail)
                                    .font(EditorialTheme.monoValue(size: 10))
                                    .foregroundStyle(EditorialTheme.accent)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(10)
                            .background(EditorialTheme.cardBackground)
                            .clipShape(RoundedRectangle(cornerRadius: EditorialTheme.cardRadius))
                            .overlay(
                                RoundedRectangle(cornerRadius: EditorialTheme.cardRadius)
                                    .stroke(EditorialTheme.cardBorder, lineWidth: 0.5)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
