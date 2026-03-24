import SwiftUI

// MARK: - Bucket helpers

private extension TimeBucket {
    var label: String {
        switch self {
        case .morning:   return "🌅 Morning (5–12)"
        case .afternoon: return "☀️ Afternoon (12–5)"
        case .evening:   return "🌆 Evening (5–10)"
        case .night:     return "🌙 Night (10–5)"
        }
    }
    var color: Color {
        switch self {
        case .morning:   return Color(red: 1.0, green: 0.78, blue: 0.31)
        case .afternoon: return Color(red: 1.0, green: 0.55, blue: 0.16)
        case .evening:   return Color(red: 0.63, green: 0.35, blue: 1.0)
        case .night:     return Color(red: 0.27, green: 0.43, blue: 1.0)
        }
    }
}

// MARK: - Sub-components

private struct StatGrid: View {
    let totalEvents: Int
    let deviceEvents: Int
    let sceneEvents: Int
    let daysTracked: Int

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            StatTile(value: "\(totalEvents)", label: "Total Actions")
            StatTile(value: "\(deviceEvents)", label: "Device Actions")
            StatTile(value: "\(sceneEvents)", label: "Scene Activations")
            StatTile(value: daysTracked > 0 ? "\(daysTracked)" : "—", label: "Days Tracked")
        }
    }
}

private struct StatTile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(.orange)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.05))
        )
    }
}

private struct BarRow: View {
    let label: String
    let count: Int
    let max: Int
    let color: Color
    var badge: String? = nil

    var pct: CGFloat { max > 0 ? CGFloat(count) / CGFloat(max) : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer()
                if let badge {
                    Text(badge)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                }
                Text("\(count)×")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 5)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                        .frame(width: Swift.max(4, geo.size.width * pct), height: 5)
                }
            }
            .frame(height: 5)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Main View

struct PersonalizationInsightsView: View {
    @Environment(UsageTracker.self) var usageTracker
    @Environment(LutronStore.self) var store

    private var events: [UsageEvent] { usageTracker.events }
    private var totalEvents: Int { events.count }
    private var deviceEvents: Int { events.filter { $0.type == .device }.count }
    private var sceneEvents: Int { events.filter { $0.type == .scene }.count }
    private var daysTracked: Int {
        guard let first = events.first else { return 0 }
        return max(1, Int(ceil((Date().timeIntervalSince1970 - first.timestamp) / 86400)))
    }

    private var bucketCounts: [TimeBucket: Int] {
        var counts: [TimeBucket: Int] = [.morning: 0, .afternoon: 0, .evening: 0, .night: 0]
        for e in events {
            let b = TimeBucket.current(date: Date(timeIntervalSince1970: e.timestamp))
            counts[b, default: 0] += 1
        }
        return counts
    }

    // For You: top devices for current time bucket (last 30 days)
    private var forYouDevices: [(id: String, room: String?, count: Int)] {
        guard events.count >= 5 else { return [] }
        let now = Date().timeIntervalSince1970
        let currentBucket = TimeBucket.current()
        let thirtyDays: TimeInterval = 30 * 24 * 60 * 60
        let filtered = events.filter { e in
            guard e.type == .device, now - e.timestamp < thirtyDays else { return false }
            return TimeBucket.current(date: Date(timeIntervalSince1970: e.timestamp)) == currentBucket
        }
        var counts: [String: (room: String?, count: Int)] = [:]
        for e in filtered {
            if var ex = counts[e.id] { ex.count += 1; counts[e.id] = ex }
            else { counts[e.id] = (room: e.room, count: 1) }
        }
        return counts.map { (id: $0.key, room: $0.value.room, count: $0.value.count) }
            .sorted { $0.count > $1.count }
            .prefix(4)
            .map { $0 }
    }

    // Quick actions: top 4 scenes (personalized if 10+ events)
    private var isQuickActionsPersonalized: Bool { events.count >= 10 }
    private var topScenesForQuickActions: [(id: String, count: Int)] {
        usageTracker.topScenes(4)
    }

    private var topDevices: [(id: String, room: String?, count: Int)] {
        usageTracker.topDevices(10)
    }
    private var topScenes: [(id: String, count: Int)] {
        usageTracker.topScenes(8)
    }

    private var activeRooms: [String] {
        Array(Set(events.compactMap(\.room))).sorted()
    }

    private var roomHeatmap: [TimeBucket: [String: Int]] {
        Dictionary(uniqueKeysWithValues: TimeBucket.allCases.map { b in
            (b, usageTracker.roomScores(for: b))
        })
    }
    private var maxHeatmapVal: Int {
        roomHeatmap.values.flatMap(\.values).max() ?? 1
    }

    private var detectedPatterns: [DetectedPattern] {
        usageTracker.detectPatterns()
    }

    private var recentActivity: [UsageEvent] {
        Array(events.suffix(25).reversed())
    }

    var body: some View {
        Group {
            if totalEvents == 0 {
                emptyState
            } else {
                insightsList
            }
        }
        .navigationTitle("For You Insights")
        .navigationBarTitleDisplayMode(.large)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No usage data yet")
                .font(.headline)
            Text("Use your lights and scenes to start building personalization data.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var insightsList: some View {
        List {
            // MARK: Overview
            Section {
                StatGrid(
                    totalEvents: totalEvents,
                    deviceEvents: deviceEvents,
                    sceneEvents: sceneEvents,
                    daysTracked: daysTracked
                )
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)

                HStack {
                    Text("Current Period")
                    Spacer()
                    Text(TimeBucket.current().label)
                        .foregroundStyle(.orange)
                        .fontWeight(.semibold)
                        .font(.subheadline)
                }
            } header: { Text("Overview") }

            // MARK: Time-of-Day Distribution
            Section("Activity by Time of Day") {
                let counts = bucketCounts
                let maxCount = max(1, counts.values.max() ?? 1)
                ForEach(TimeBucket.allCases, id: \.self) { bucket in
                    BarRow(
                        label: bucket.label,
                        count: counts[bucket] ?? 0,
                        max: maxCount,
                        color: bucket.color
                    )
                }
            }

            // MARK: For You
            Section {
                if forYouDevices.isEmpty {
                    Text("Need at least 5 events (\(totalEvents)/5 so far).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    let maxScore = forYouDevices.first?.count ?? 1
                    ForEach(Array(forYouDevices.enumerated()), id: \.offset) { i, item in
                        let dev = store.devices[Int(item.id) ?? 0]
                        let label = dev?.name ?? "Device \(item.id)"
                        let badge = dev?.room ?? item.room
                        HStack(alignment: .top, spacing: 12) {
                            Text("\(i + 1)")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundStyle(.orange)
                                .frame(width: 18, height: 18)
                                .background(Circle().fill(Color.orange.opacity(0.15)))
                            BarRow(label: label, count: item.count, max: maxScore, color: .orange.opacity(0.6), badge: badge)
                        }
                    }
                }
            } header: {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                    Text("For You — Current Suggestions")
                }
            }

            // MARK: Quick Actions
            Section {
                if isQuickActionsPersonalized {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                        Text("Personalized — using your most-used scenes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    let maxCount = topScenesForQuickActions.first?.count ?? 1
                    ForEach(topScenesForQuickActions, id: \.id) { s in
                        let scene = store.scenes.first { $0.id == s.id }
                        BarRow(
                            label: scene?.name ?? "Scene \(s.id.prefix(8))",
                            count: s.count,
                            max: maxCount,
                            color: Color(red: 0.31, green: 0.78, blue: 0.47)
                        )
                    }
                } else {
                    Text("Using defaults — need 10+ events (\(totalEvents)/10 so far).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } header: { Text("Quick Actions") }

            // MARK: Top Devices
            Section("Most Used Devices") {
                if topDevices.isEmpty {
                    Text("No device data yet.").foregroundStyle(.secondary).font(.subheadline)
                } else {
                    let maxCount = topDevices.first?.count ?? 1
                    ForEach(topDevices, id: \.id) { item in
                        let dev = store.devices[Int(item.id) ?? 0]
                        BarRow(
                            label: dev?.name ?? "Device \(item.id)",
                            count: item.count,
                            max: maxCount,
                            color: .orange,
                            badge: dev?.room ?? item.room
                        )
                    }
                }
            }

            // MARK: Top Scenes
            if !topScenes.isEmpty {
                Section("Most Activated Scenes") {
                    let maxCount = topScenes.first?.count ?? 1
                    ForEach(topScenes, id: \.id) { s in
                        let scene = store.scenes.first { $0.id == s.id }
                        BarRow(
                            label: scene?.name ?? "Scene \(s.id.prefix(8))",
                            count: s.count,
                            max: maxCount,
                            color: Color(red: 0.63, green: 0.35, blue: 1.0)
                        )
                    }
                }
            }

            // MARK: Room × Time Heatmap
            if !activeRooms.isEmpty {
                Section("Room Usage Heatmap") {
                    RoomHeatmapView(
                        rooms: activeRooms,
                        heatmap: roomHeatmap,
                        maxVal: maxHeatmapVal
                    )
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
            }

            // MARK: Detected Patterns
            if !detectedPatterns.isEmpty {
                Section("Detected Patterns (\(detectedPatterns.count))") {
                    ForEach(detectedPatterns) { pattern in
                        PatternRow(pattern: pattern, devices: store.devices)
                    }
                }
            }

            // MARK: Recent Activity
            Section("Recent Activity") {
                ForEach(Array(recentActivity.enumerated()), id: \.offset) { _, e in
                    RecentActivityRow(event: e, devices: store.devices, scenes: store.scenes)
                }
            }
        }
    }
}

// MARK: - Room Heatmap

private struct RoomHeatmapView: View {
    let rooms: [String]
    let heatmap: [TimeBucket: [String: Int]]
    let maxVal: Int

    private let bucketEmojis: [TimeBucket: String] = [
        .morning: "🌅", .afternoon: "☀️", .evening: "🌆", .night: "🌙"
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 5) {
                // Header
                HStack(spacing: 6) {
                    Text("").frame(width: 100)
                    ForEach(TimeBucket.allCases, id: \.self) { bucket in
                        VStack(spacing: 1) {
                            Text(bucketEmojis[bucket] ?? "")
                                .font(.caption)
                            Text(bucket.rawValue)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 56)
                    }
                }
                // Rows
                ForEach(rooms, id: \.self) { room in
                    HStack(spacing: 6) {
                        Text(room)
                            .font(.caption)
                            .fontWeight(.medium)
                            .lineLimit(1)
                            .frame(width: 100, alignment: .leading)
                        ForEach(TimeBucket.allCases, id: \.self) { bucket in
                            let val = heatmap[bucket]?[room] ?? 0
                            let intensity = maxVal > 0 ? Double(val) / Double(maxVal) : 0
                            ZStack {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(intensity > 0
                                          ? Color.orange.opacity(0.1 + intensity * 0.7)
                                          : Color.primary.opacity(0.05))
                                if val > 0 {
                                    Text("\(val)")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(intensity > 0.55 ? Color(white: 0.1) : .orange)
                                }
                            }
                            .frame(width: 56, height: 28)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Pattern Row

private struct PatternRow: View {
    let pattern: DetectedPattern
    let devices: [Int: DeviceState]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let tod = pattern.timeOfDay {
                    Text(tod)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.purple.opacity(0.15)))
                        .foregroundStyle(.purple)
                }
                Text("observed \(pattern.frequency)×")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            FlowLayout(spacing: 5) {
                ForEach(pattern.devices, id: \.id) { d in
                    let dev = devices[d.id]
                    let label = dev != nil
                        ? "\(dev!.name)\(d.avgLevel > 0 ? " \(Int(d.avgLevel))%" : "")"
                        : "Device \(d.id)\(d.avgLevel > 0 ? " \(Int(d.avgLevel))%" : "")"
                    Text(label)
                        .font(.caption)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Recent Activity Row

private struct RecentActivityRow: View {
    let event: UsageEvent
    let devices: [Int: DeviceState]
    let scenes: [LightScene]

    private var icon: String { event.type == .scene ? "theatermasks.fill" : "lightbulb.fill" }
    private var label: String {
        if event.type == .scene {
            return scenes.first(where: { $0.id == event.id })?.name ?? "Scene \(event.id.prefix(8))"
        }
        let dev = devices[Int(event.id) ?? 0]
        var name = dev?.name ?? "Device \(event.id)"
        if let level = event.level { name += " → \(Int(level))%" }
        else if event.action == .turnOff { name += " → off" }
        return name
    }
    private var room: String? {
        if event.type == .device { return devices[Int(event.id) ?? 0]?.room ?? event.room }
        return nil
    }
    private var timeStr: String {
        let d = Date(timeIntervalSince1970: event.timestamp)
        let time = d.formatted(.dateTime.hour().minute())
        let date = d.formatted(.dateTime.month(.abbreviated).day())
        return "\(time) · \(date)"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(event.type == .scene ? Color.purple : Color.orange)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.subheadline).lineLimit(1)
                if let room { Text(room).font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer()
            Text(timeStr)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.trailing)
        }
    }
}

