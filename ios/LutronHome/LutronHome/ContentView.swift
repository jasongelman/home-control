import SwiftUI
import HomeKit
import AuthenticationServices

struct ContentView: View {
    @Environment(LutronStore.self) var store
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeTab()
                .tabItem {
                    Image(systemName: "house.fill")
                    Text("Home")
                }
                .tag(0)

            CategoryTab(category: .light)
                .tabItem {
                    Image(systemName: "lightbulb.fill")
                    Text("Lights")
                }
                .tag(1)

            CategoryTab(categories: [.shadesAndDrapes, .window], title: "Shades & Windows")
                .tabItem {
                    Image(systemName: "blinds.vertical.open")
                    Text("Shades")
                }
                .tag(2)

            AppliancesTab()
                .tabItem {
                    Image(systemName: "washer")
                    Text("Appliances")
                }
                .tag(3)

            CategoryTab(categories: [.outlet, .fan], title: "Outlets & Fans")
                .tabItem {
                    Image(systemName: "poweroutlet.type.b")
                    Text("More")
                }
                .tag(4)
        }
        .onAppear { store.start() }
        .tint(SunCalculator.TimeTheme.current().accent)
    }
}

// MARK: - Home Tab

struct HomeTab: View {
    @Environment(LutronStore.self) var store
    @State private var selectedRoom: String?

    var body: some View {
        NavigationStack {
            if let room = selectedRoom {
                RoomDetailView(roomName: room, onBack: { selectedRoom = nil })
            } else {
                DashboardView()
            }
        }
    }
}

// MARK: - Category Tab (Lights, Shades & Drapes, Outlets)

struct CategoryTab: View {
    @Environment(LutronStore.self) var store
    let categories: [DeviceCategory]
    let title: String
    @State private var selectedRoom: String?

    init(category: DeviceCategory) {
        self.categories = [category]
        self.title = category.rawValue
    }

    init(categories: [DeviceCategory], title: String) {
        self.categories = categories
        self.title = title
    }

    private var categoryRooms: [(name: String, devices: [DeviceState])] {
        store.rooms.compactMap { room in
            let filtered = room.devices.filter { categories.contains($0.category) }
            return filtered.isEmpty ? nil : (name: room.name, devices: filtered)
        }
    }

    private var isLightsTab: Bool { categories == [.light] }

    /// Floors that actually have rooms in this category
    private var activeFloors: [Floor] {
        Floor.allCases.filter { floor in
            categoryRooms.contains { Floor.floor(for: $0.name) == floor }
        }
    }

    var body: some View {
        NavigationStack {
            if let room = selectedRoom {
                RoomDetailView(roomName: room, onBack: { selectedRoom = nil })
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        if isLightsTab && activeFloors.count > 1 {
                            LazyVStack(alignment: .leading, spacing: 20, pinnedViews: [.sectionHeaders]) {
                                Section {
                                    lightsContent
                                } header: {
                                    floorAnchorBar(proxy: proxy)
                                        .padding(.horizontal)
                                        .padding(.vertical, 8)
                                        .background(.bar)
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            .padding(.top, 12)
                        } else {
                            VStack(alignment: .leading, spacing: 20) {
                                if categoryRooms.isEmpty {
                                    emptyState
                                } else {
                                    ForEach(Floor.allCases, id: \.self) { floor in
                                        let floorRooms = categoryRooms.filter { Floor.floor(for: $0.name) == floor }
                                        if !floorRooms.isEmpty {
                                            floorSection(floor: floor, rooms: floorRooms)
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal)
                            .padding(.top, 12)
                        }
                    }
                }
                .refreshable { await store.refresh() }
                .background(Color(.systemBackground))
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.large)
            }
        }
    }

    private var lightsContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            if categoryRooms.isEmpty {
                emptyState
            } else {
                ForEach(Floor.allCases, id: \.self) { floor in
                    let floorRooms = categoryRooms.filter { Floor.floor(for: $0.name) == floor }
                    if !floorRooms.isEmpty {
                        floorSection(floor: floor, rooms: floorRooms)
                            .id(floor)
                    }
                }
            }
        }
        .padding(.horizontal)
    }

    private func floorAnchorBar(proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 0) {
            ForEach(activeFloors, id: \.self) { floor in
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(floor, anchor: .top)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: floor.icon)
                            .font(.system(size: 10))
                        Text(floor.rawValue)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(.tertiarySystemBackground), in: Capsule())
                }
                .buttonStyle(.plain)

                if floor != activeFloors.last {
                    Spacer(minLength: 4)
                }
            }
        }
    }

    private func floorSection(floor: Floor, rooms: [(name: String, devices: [DeviceState])]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: floor.icon)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(floor.rawValue)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
            }
            .padding(.leading, 4)

            MasonryTwoColumn(spacing: 10) {
                ForEach(rooms, id: \.name) { room in
                    CategoryRoomCard(
                        name: room.name,
                        devices: room.devices,
                        category: room.devices.first?.category ?? categories.first ?? .light,
                        onTap: { selectedRoom = room.name }
                    )
                }
            }
        }
    }

    private var emptyState: some View {
        HStack {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: categories.first?.icon ?? "questionmark")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(store.isConnected ? "No \(title.lowercased()) found" : "Not connected")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
            Spacer()
        }
        .padding(.vertical, 40)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Dashboard

struct DashboardView: View {
    @Environment(LutronStore.self) var store
    @Environment(UsageTracker.self) var usageTracker
    @Environment(HomeKitManager.self) var homeKit
    @Environment(HomeConnectManager.self) var homeConnect
    @Environment(MyUplinkManager.self) var myUplink
    @Environment(SmartHQManager.self) var smartHQ
    @Environment(TotalConnectManager.self) var totalConnect

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Time-aware header
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Image(systemName: timeTheme.periodIcon)
                                    .font(.system(size: 15))
                                    .foregroundStyle(timeTheme.theme.accent)
                                Text(timeTheme.greeting)
                                    .font(.subheadline)
                                    .foregroundStyle(timeTheme.theme.accent.opacity(0.85))
                            }
                            Text("8 Highclere")
                                .font(.largeTitle)
                                .fontWeight(.bold)
                        }
                        Spacer()
                        HStack(spacing: 12) {
                            connectionIndicator
                            NavigationLink(destination: SettingsView()) {
                                Image(systemName: "gear")
                                    .font(.system(size: 17))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .background(
                    LinearGradient(colors: timeTheme.theme.headerGradient, startPoint: .top, endPoint: .bottom)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal, -16)
                )

                if store.connectionState != .connected {
                    ConnectionBanner()
                }

                CameraCarouselCard(homeKit: homeKit)
                // garageDoorSection  // Hidden until HomeKit garage door integration is working
                forYouSection
                quickActionsSection
                adaptiveRoomControlsSection
                sceneSuggestionsSection
                lightsOnSection
            }
            .padding(.horizontal)
            .padding(.top, 12)
        }
        .refreshable {
            await store.refresh()
        }
        .background {
            TimeOfDayBackground(period: SunCalculator.currentPeriod())
        }
        .scrollContentBackground(.hidden)
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: - Time Theme

    private var timeTheme: (greeting: String, theme: SunCalculator.TimeTheme, periodIcon: String) {
        let period = SunCalculator.currentPeriod()
        return (
            greeting: period.greeting,
            theme: SunCalculator.TimeTheme.current(),
            periodIcon: period.icon
        )
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack(spacing: 8) {
            if store.isLoading {
                ProgressView()
                    .scaleEffect(0.8)
            }
            Text(store.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Connection Status

    private var connectionIndicator: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(connectionDotColor)
                .frame(width: 6, height: 6)
            Text(connectionLabel)
                .font(.caption)
                .foregroundStyle(connectionDotColor)
        }
    }

    private var connectionDotColor: Color {
        switch store.connectionState {
        case .connected: return .green
        case .connecting: return .orange
        default: return .red
        }
    }

    private var connectionLabel: String {
        switch store.connectionState {
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        default: return "Offline"
        }
    }

    // MARK: - Garage Doors

    private var garageDoorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "door.garage.closed")
                    .font(.caption)
                    .foregroundStyle(.cyan)
                Text("Garage Doors")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
            }

            if homeKit.garageDoors.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "door.garage.closed")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text(homeKit.isReady ? "No garage doors found in HomeKit" : "Connecting to HomeKit...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 20)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(homeKit.garageDoors, id: \.uniqueIdentifier) { door in
                        GarageDoorCard(door: door, homeKit: homeKit)
                    }
                }
            }
        }
    }

    // MARK: - Quick Actions

    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quick Actions")
                .font(.caption)
                .fontWeight(.semibold)
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(timeTheme.theme.sectionHeaderColor)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                // Time-based contextual actions (shown first)
                let contextual = SunCalculator.contextualActions()
                ForEach(contextual, id: \.id) { action in
                    QuickActionButton(title: action.title, icon: action.icon, color: timeTheme.theme.accent) {
                        handleContextualAction(action.id)
                    }
                }

                // Appliance pills (same height, different color scheme)
                if homeConnect.isLinked {
                    ForEach(homeConnect.dishwashers) { dw in
                        AppliancePill(
                            title: dw.applianceName.isEmpty ? "Dishwasher" : dw.applianceName,
                            icon: "dishwasher",
                            status: dw.operationState.label,
                            color: .cyan,
                            isActive: dw.operationState.isActive,
                            progress: dw.operationState.isActive ? dw.progress : nil,
                            timeRemaining: dw.remainingTimeFormatted
                        )
                    }
                }

                if smartHQ.isLinked {
                    ForEach(smartHQ.appliances) { app in
                        AppliancePill(
                            title: app.applianceName,
                            icon: app.typeIcon,
                            status: app.machineState.label,
                            color: app.isWasher ? .indigo : .purple,
                            isActive: app.machineState.isActive,
                            progress: nil,
                            timeRemaining: app.remainingTimeFormatted
                        )
                    }
                }

                if myUplink.isLinked {
                    AppliancePill(
                        title: "Geothermal",
                        icon: heatPumpIcon,
                        status: myUplink.heatPump.operatingMode ?? "Connected",
                        color: heatPumpColor,
                        isActive: false,
                        progress: nil,
                        timeRemaining: myUplink.heatPump.currentPower.map { String(format: "%.1f kW", $0) }
                    )
                }

                // Alarm panels
                if totalConnect.isLinked {
                    ForEach(totalConnect.panels) { panel in
                        AlarmPill(panel: panel, manager: totalConnect)
                    }
                }

                // Standard actions
                QuickActionButton(title: "Main Floor Off", icon: "power", color: .orange) {
                    store.turnOffLights(on: .mainFloor)
                }
                QuickActionButton(title: "Upstairs Off", icon: "power", color: .orange) {
                    store.turnOffLights(on: .upstairs)
                }
                QuickActionButton(title: "Main Shades Toggle", icon: "blinds.vertical.closed", color: .blue) {
                    store.toggleMainShades()
                }
            }
        }
    }

    private var heatPumpIcon: String {
        let mode = (myUplink.heatPump.operatingMode ?? "").lowercased()
        if mode.contains("heat") { return "flame.fill" }
        if mode.contains("cool") { return "snowflake" }
        if mode.contains("hot water") || mode.contains("dhw") { return "drop.fill" }
        return "leaf.fill"
    }

    private var heatPumpColor: Color {
        let mode = (myUplink.heatPump.operatingMode ?? "").lowercased()
        if mode.contains("heat") { return .orange }
        if mode.contains("cool") { return .cyan }
        if mode.contains("hot water") || mode.contains("dhw") { return .blue }
        return .green
    }

    private func handleContextualAction(_ id: String) {
        switch id {
        case "morning":
            // Morning lights scene — turn on key lights at low level
            store.setRoomLights("Kitchen", level: 60)
            store.setRoomLights("Family Room", level: 40)
        case "shades_open":
            store.toggleMainShades() // Opens if closed
        case "shades_close":
            store.toggleMainShades() // Closes if open
        case "all_off":
            store.turnOffAllLights(excludingNames: ["Bed 2 Entry"])
        case "evening":
            store.activateEveningScene()
        case "goodnight":
            // Turn off all lights except Sebastian's night light
            store.turnOffAllLights(excludingNames: ["Bed 2 Entry"])
        default:
            break
        }
    }

    // MARK: - For You (personalized suggestions)

    @ViewBuilder
    private var forYouSection: some View {
        let isEvening = TimeBucket.current() == .evening
        let topDevices = usageTracker.topDevices(isEvening ? 3 : 4, timeWindowSeconds: 30 * 24 * 60 * 60)
        let hasContent = isEvening || (!topDevices.isEmpty && usageTracker.events.count >= 5)
        if hasContent {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundStyle(timeTheme.theme.accent)
                    Text("For You")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .textCase(.uppercase)
                        .tracking(0.5)
                        .foregroundStyle(timeTheme.theme.sectionHeaderColor)
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    // Always show Evening scene during evening hours (6pm–2am)
                    if isEvening {
                        Button {
                            store.activateEveningScene()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "moon.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(timeTheme.theme.accent)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Evening")
                                        .font(.footnote)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text("Scene")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(timeTheme.theme.accent.opacity(0.06))
                                    .strokeBorder(timeTheme.theme.accent.opacity(0.15))
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    ForEach(topDevices, id: \.id) { item in
                        if let device = store.devices[Int(item.id) ?? 0] {
                            Button {
                                let newLevel: Double = device.level > 0 ? 0 : 100
                                store.setLevel(device.integrationId, level: newLevel, fadeTime: 1)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: device.category == .light ? "lightbulb.fill" : "blinds.vertical.open")
                                        .font(.system(size: 14))
                                        .foregroundStyle(timeTheme.theme.accent)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(device.name)
                                            .font(.footnote)
                                            .fontWeight(.semibold)
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text(device.room)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(timeTheme.theme.accent.opacity(0.06))
                                        .strokeBorder(timeTheme.theme.accent.opacity(0.15))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Room Controls (adaptive)

    private var adaptiveRoomControlsSection: some View {
        let roomIcons: [String: String] = [
            "Guest Bathroom": "🚿", "Primary Bedroom": "🛏️", "Primary Bathroom": "🛁",
            "Kitchen": "🍳", "Family Room": "📺", "Dining Room": "🍽️",
            "Jason Office": "💻", "Living Room": "🛋️", "Main Entry": "🚪",
            "Mudroom": "🚪", "Breakfast Nook": "☕", "Powder Room": "🚿",
            "Ronan's Room": "🧸", "Sebastian's Room": "🧸", "Gym": "🏋️",
            "Laundry": "🧺", "Garage": "🚗", "Guest Bedroom": "🛏️",
        ]

        let defaultRooms = ["Guest Bathroom", "Primary Bedroom", "Primary Bathroom", "Kitchen", "Family Room", "Dining Room"]
        let available = store.rooms.map(\.name)
        let sorted = usageTracker.sortedRoomNames(available: available)
        let displayRooms = usageTracker.events.isEmpty ? defaultRooms : Array(sorted.prefix(6))

        return VStack(alignment: .leading, spacing: 10) {
            Text("Room Controls")
                .font(.caption)
                .fontWeight(.semibold)
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(timeTheme.theme.sectionHeaderColor)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(displayRooms, id: \.self) { room in
                    RoomControlCard(roomName: room, icon: roomIcons[room] ?? "🏠", store: store)
                }
            }
        }
    }

    // MARK: - Scene Suggestions

    @ViewBuilder
    private var sceneSuggestionsSection: some View {
        let patterns = usageTracker.detectPatterns()
        if let pattern = patterns.first {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .font(.caption)
                                .foregroundStyle(timeTheme.theme.accent)
                            Text("Suggested Scene")
                                .font(.footnote)
                                .fontWeight(.semibold)
                        }
                        Text(patternDescription(pattern))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    Spacer()
                    Button {
                        usageTracker.dismissPattern(pattern.hash)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(timeTheme.theme.accent.opacity(0.06))
                        .strokeBorder(timeTheme.theme.accent.opacity(0.15))
                )
            }
        }
    }

    private func patternDescription(_ pattern: DetectedPattern) -> String {
        let parts = pattern.devices.prefix(3).map { d in
            let device = store.devices[d.id]
            let name = device.map { "\($0.room) \($0.name)" } ?? "Device \(d.id)"
            return "\(name) \(Int(d.avgLevel))%"
        }
        let timeLabel = pattern.timeOfDay.map { " in the \($0)" } ?? ""
        return "You often set \(parts.joined(separator: ", "))\(timeLabel) (\(pattern.frequency)x)"
    }

    // MARK: - Lights On

    private var lightsOnSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Lights On")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .foregroundStyle(timeTheme.theme.sectionHeaderColor)

                Text("\(store.lightsOn.count)")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        store.lightsOn.isEmpty
                            ? Color(.systemGray5)
                            : timeTheme.theme.accent.opacity(0.2)
                    )
                    .foregroundColor(store.lightsOn.isEmpty ? .secondary : timeTheme.theme.accent)
                    .clipShape(Capsule())
            }

            if store.lightsOn.isEmpty {
                HStack {
                    Spacer()
                    Text("All lights are off")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                    Spacer()
                }
                .padding(.vertical, 24)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            } else {
                // Group by room so the list stays navigable even with many lights on.
                // Within each room the pill shows the light name without the room prefix.
                let byRoom = Dictionary(grouping: store.lightsOn, by: \.room)
                let sortedRooms = byRoom.keys.sorted()

                VStack(alignment: .leading, spacing: 14) {
                    ForEach(sortedRooms, id: \.self) { room in
                        let lights = byRoom[room]!
                        VStack(alignment: .leading, spacing: 6) {
                            // Room header
                            HStack(spacing: 5) {
                                Text(room)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Text("\(lights.count)")
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(timeTheme.theme.accent.opacity(0.15))
                                    .foregroundStyle(timeTheme.theme.accent)
                                    .clipShape(Capsule())
                            }

                            // Lights for this room — strip room prefix since it's in the header
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                                ForEach(lights) { device in
                                    LightOnPill(device: device, roomName: room)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

}

// MARK: - Quick Action Button

struct QuickActionButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(color)
                Text(title)
                    .font(.footnote)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer()
            }
            .padding(14)
            .frame(minHeight: 56)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(.separator).opacity(0.4), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Alarm Pill

struct AlarmPill: View {
    let panel: AlarmPanel
    let manager: TotalConnectManager

    private var stateColor: Color {
        switch panel.state {
        case .disarmed:              return .green
        case .armedAway, .armedHome, .armedNight: return .orange
        case .alarming:              return .red
        default:                     return .secondary
        }
    }

    var body: some View {
        Menu {
            Button("Arm Away")  { Task { await manager.armAway(panel) } }
                .disabled(panel.state == .armedAway || panel.state.isTransitioning)
            Button("Arm Home")  { Task { await manager.armHome(panel) } }
                .disabled(panel.state == .armedHome || panel.state.isTransitioning)
            Button("Arm Night") { Task { await manager.armNight(panel) } }
                .disabled(panel.state == .armedNight || panel.state.isTransitioning)
            Divider()
            Button("Disarm", role: .destructive) { Task { await manager.disarm(panel) } }
                .disabled(panel.state == .disarmed || panel.state.isTransitioning)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: panel.state.icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(stateColor)

                VStack(alignment: .leading, spacing: 1) {
                    Text(panel.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(panel.state.label)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(14)
            .frame(minHeight: 56)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(stateColor.opacity(panel.state == .alarming ? 0.8 : 0.2), lineWidth: panel.state == .alarming ? 1.5 : 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Appliance Pill (same height as QuickActionButton, different color scheme)

struct AppliancePill: View {
    let title: String
    let icon: String
    let status: String
    let color: Color
    let isActive: Bool
    let progress: Int?
    let timeRemaining: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(color)
                .symbolEffect(.pulse, isActive: isActive)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                HStack(spacing: 4) {
                    Text(status)
                        .font(.system(size: 10))
                        .foregroundStyle(isActive ? color : .secondary)
                    if let time = timeRemaining {
                        Text(time)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 0)

            // Mini progress ring when active
            if isActive, let prog = progress {
                CircularProgressView(progress: Double(prog) / 100, color: color)
                    .frame(width: 24, height: 24)
            }
        }
        .padding(14)
        .frame(minHeight: 56)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial)
                if isActive { RoundedRectangle(cornerRadius: 12).fill(color.opacity(0.10)) }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isActive ? color.opacity(0.4) : Color(.separator).opacity(0.4), lineWidth: isActive ? 1 : 0.5)
        )
    }
}

// MARK: - Room Control Card (On / Dim / Off)

struct RoomControlCard: View {
    let roomName: String
    let icon: String
    var store: LutronStore

    private var roomLights: [DeviceState] {
        store.devices.values.filter { $0.room == roomName && $0.category == .light }
    }

    private var currentState: RoomLightState {
        let lights = roomLights
        if lights.isEmpty { return .off }
        let allOff = lights.allSatisfy { $0.level == 0 }
        if allOff { return .off }
        let allFull = lights.allSatisfy { $0.level >= 100 }
        if allFull { return .on }
        return .dim
    }

    private var isActive: Bool { currentState != .off }

    enum RoomLightState {
        case on, dim, off
    }

    var body: some View {
        VStack(spacing: 10) {
            // Room name row
            HStack(spacing: 6) {
                Text(icon)
                    .font(.system(size: 14))
                Text(roomName)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer()
            }

            // Control buttons
            HStack(spacing: 8) {
                modeButton(icon: "lightbulb.max.fill", state: .on) {
                    store.setRoomLights(roomName, level: 100)
                }
                modeButton(icon: "lightbulb.min", state: .dim) {
                    store.setRoomLights(roomName, level: 50)
                }
                modeButton(icon: "power", state: .off) {
                    store.setRoomLights(roomName, level: 0)
                }
            }
        }
        .padding(12)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isActive ? Color.orange.opacity(0.2) : Color(.separator).opacity(0.5), lineWidth: 1)
        )
    }

    private func modeButton(icon: String, state: RoomLightState, action: @escaping () -> Void) -> some View {
        let isSelected = currentState == state
        return Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(isSelected ? Color.orange : Color(.tertiarySystemBackground))
                .foregroundStyle(isSelected ? .white : Color(.systemGray2))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var cardBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial)
            if isActive {
                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(
                        colors: [Color.orange.opacity(0.14), Color.orange.opacity(0.04)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
            }
        }
    }
}

// MARK: - Light On Pill (drag-to-dim + tap-to-off)

private enum DragIntent { case undecided, dimming, scrolling }

struct LightOnPill: View {
    @Environment(LutronStore.self) var store
    let device: DeviceState
    /// If set, strips this room name prefix from the displayed light name.
    var roomName: String = ""

    @State private var dragIntent: DragIntent = .undecided
    @State private var isDragging = false
    @State private var dragLevel: Double = 0
    @State private var lastSentLevel: Double = -1
    @State private var lastSendTime: Date = .distantPast

    private var displayLevel: Double { isDragging ? dragLevel : device.level }

    private var displayName: String {
        var n = device.name
        if !roomName.isEmpty, n.lowercased().hasPrefix(roomName.lowercased()) {
            let stripped = String(n.dropFirst(roomName.count)).trimmingCharacters(in: .whitespaces)
            if !stripped.isEmpty { n = stripped }
        }
        // Strip "Bed N " prefixes used in bedroom devices
        if let range = n.range(of: #"^Bed \d+ "#, options: .regularExpression) {
            let stripped = String(n[range.upperBound...])
            if !stripped.isEmpty { n = stripped }
        }
        return n
    }

    // Throttle: send at most every 100ms and only if level changed by ≥5
    private func sendIfNeeded(_ level: Double) {
        let snapped = (level / 5).rounded() * 5
        let now = Date()
        guard abs(snapped - lastSentLevel) >= 5,
              now.timeIntervalSince(lastSendTime) >= 0.1 else { return }
        lastSentLevel = snapped
        lastSendTime = now
        store.setLevel(device.integrationId, level: snapped, fadeTime: 0)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.ultraThinMaterial)

                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.orange.opacity(0.35))
                    .frame(width: geo.size.width * (displayLevel / 100))
                    .animation(isDragging ? nil : .easeOut(duration: 0.15), value: displayLevel)

                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.orange.opacity(0.3), lineWidth: 1)

                HStack(spacing: 4) {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 10))
                    Text(displayName)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 4)
                    Text("\(Int(displayLevel))%")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 10)
            }
            .contentShape(Rectangle())
            // Directional drag: only activates when gesture is clearly horizontal,
            // letting vertical scrolling pass through to the ScrollView.
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        if dragIntent == .undecided {
                            let h = abs(value.translation.width)
                            let v = abs(value.translation.height)
                            if h > v * 1.5 { dragIntent = .dimming }
                            else if v > h * 1.5 { dragIntent = .scrolling }
                        }
                        guard dragIntent == .dimming else { return }
                        if !isDragging {
                            isDragging = true
                            dragLevel = device.level
                            lastSentLevel = device.level
                        }
                        let pct = max(1, min(100, (value.location.x / geo.size.width) * 100))
                        dragLevel = pct
                        sendIfNeeded(pct)
                    }
                    .onEnded { value in
                        if dragIntent == .dimming && isDragging {
                            let pct = max(1, min(100, (value.location.x / geo.size.width) * 100))
                            let snapped = (pct / 5).rounded() * 5
                            store.setLevel(device.integrationId, level: snapped, fadeTime: 0)
                        }
                        dragIntent = .undecided
                        isDragging = false
                    }
            )
            .simultaneousGesture(
                TapGesture().onEnded {
                    guard !isDragging else { return }
                    store.turnOff(device.integrationId)
                }
            )
        }
        .frame(height: 36)
    }
}

// MARK: - Dim Pill (off/close | name | max/open, drag-to-position)

struct DimPill: View {
    @Environment(LutronStore.self) var store
    let devices: [DeviceState]
    let displayName: String
    var accentColor: Color = .orange
    var leftIcon: String = "power"
    var rightIcon: String = "lightbulb.max.fill"

    @State private var dragIntent: DragIntent = .undecided
    @State private var isDragging = false
    @State private var dragLevel: Double = 0
    @State private var lastSentLevel: Double = -1
    @State private var lastSendTime: Date = .distantPast

    private var currentLevel: Double {
        guard !devices.isEmpty else { return 0 }
        return devices.map(\.level).reduce(0, +) / Double(devices.count)
    }
    private var displayLevel: Double { isDragging ? dragLevel : currentLevel }
    private var isOn: Bool { devices.contains { $0.isOn } }

    private func setAll(_ level: Double, fadeTime: Double = 0) {
        for device in devices {
            store.setLevel(device.integrationId, level: level, fadeTime: fadeTime)
        }
    }

    private func sendIfNeeded(_ level: Double) {
        let snapped = (level / 5).rounded() * 5
        let now = Date()
        guard abs(snapped - lastSentLevel) >= 5,
              now.timeIntervalSince(lastSendTime) >= 0.1 else { return }
        lastSentLevel = snapped
        lastSendTime = now
        setAll(snapped, fadeTime: 0)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.ultraThinMaterial)

                RoundedRectangle(cornerRadius: 8)
                    .fill(accentColor.opacity(0.35))
                    .frame(width: geo.size.width * max(0, displayLevel / 100))
                    .animation(isDragging ? nil : .easeOut(duration: 0.15), value: displayLevel)

                RoundedRectangle(cornerRadius: 8)
                    .stroke(accentColor.opacity(isOn ? 0.3 : 0.15), lineWidth: 1)

                HStack(spacing: 0) {
                    Button { setAll(0, fadeTime: 1) } label: {
                        Image(systemName: leftIcon)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(isOn ? accentColor : Color(.systemGray3))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)

                    Text(displayName)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(isOn ? .primary : .secondary)
                        .frame(maxWidth: .infinity)

                    Button { setAll(100, fadeTime: 1) } label: {
                        Image(systemName: rightIcon)
                            .font(.system(size: 10))
                            .foregroundStyle(isOn ? accentColor : Color(.systemGray3))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        if dragIntent == .undecided {
                            let h = abs(value.translation.width)
                            let v = abs(value.translation.height)
                            if h > v * 1.5 { dragIntent = .dimming }
                            else if v > h * 1.5 { dragIntent = .scrolling }
                        }
                        guard dragIntent == .dimming else { return }
                        if !isDragging {
                            isDragging = true
                            dragLevel = currentLevel
                            lastSentLevel = currentLevel
                        }
                        let pct = max(1, min(100, (value.location.x / geo.size.width) * 100))
                        dragLevel = pct
                        sendIfNeeded(pct)
                    }
                    .onEnded { value in
                        if dragIntent == .dimming && isDragging {
                            let pct = max(1, min(100, (value.location.x / geo.size.width) * 100))
                            let snapped = (pct / 5).rounded() * 5
                            setAll(snapped, fadeTime: 0)
                        }
                        dragIntent = .undecided
                        isDragging = false
                    }
            )
        }
        .frame(height: 32)
    }
}

// MARK: - Category Room Card (icon + name, device toggles, no counts)

struct CategoryRoomCard: View {
    let name: String
    let devices: [DeviceState]
    let category: DeviceCategory
    let onTap: () -> Void

    @Environment(LutronStore.self) var store

    private var hasActiveDevice: Bool { devices.contains { $0.isOn } }

    /// Group devices like "Peak Cove A" + "Peak Cove B" → "Peak Cove"
    private var groupedDevices: [(label: String, devices: [DeviceState])] {
        // Strip room name prefix and bedroom prefixes for grouping
        func displayName(_ device: DeviceState) -> String {
            var n = device.name
            // Strip room name prefix (e.g., "Kitchen Recessed" → "Recessed")
            if n.lowercased().hasPrefix(name.lowercased()) {
                let stripped = String(n.dropFirst(name.count)).trimmingCharacters(in: .whitespaces)
                if !stripped.isEmpty { n = stripped }
            }
            // Strip "Bed N " prefix for bedroom devices (e.g., "Bed 1 Entry" → "Entry", "Bed 2 Recessed" → "Recessed")
            if let range = n.range(of: #"^Bed \d+ "#, options: .regularExpression) {
                let stripped = String(n[range.upperBound...])
                if !stripped.isEmpty { return stripped }
            }
            return n
        }

        // Check if a name ends with " A" or " B" (or similar single-letter suffix)
        func groupKey(_ displayName: String) -> String {
            let suffixes = [" A", " B", " C", " D"]
            for suffix in suffixes {
                if displayName.hasSuffix(suffix) {
                    return String(displayName.dropLast(suffix.count))
                }
            }
            return displayName
        }

        var groups: [(label: String, devices: [DeviceState])] = []
        var seen: [String: Int] = [:] // groupKey → index in groups

        for device in devices {
            let dn = displayName(device)
            let key = groupKey(dn)
            if let idx = seen[key] {
                groups[idx].devices.append(device)
            } else {
                seen[key] = groups.count
                groups.append((label: key, devices: [device]))
            }
        }
        return groups
    }

    private var accentColor: Color {
        switch category {
        case .light: return .orange
        case .shadesAndDrapes: return .blue
        case .outlet: return .green
        case .fan: return .teal
        case .window: return .purple
        }
    }

    /// Whether this room has exactly one device (after grouping)
    private var isSingleDevice: Bool { groupedDevices.count == 1 && devices.count == 1 }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                if isSingleDevice {
                    // Single device: room name + toggle on one line
                    SingleDeviceRoomRow(
                        roomIcon: roomIcon,
                        roomName: name,
                        device: devices[0],
                        accentColor: accentColor
                    )
                } else {
                    // Icon + name on same line
                    HStack(spacing: 6) {
                        Text(roomIcon)
                            .font(.system(size: 14))
                        Text(name)
                            .font(.system(size: 13, weight: .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .foregroundStyle(.primary)
                    }

                    // Device toggles (with A/B grouping)
                    VStack(spacing: 4) {
                        ForEach(groupedDevices, id: \.label) { group in
                            if group.devices.count == 1 {
                                DeviceToggleRow(device: group.devices[0], roomName: name)
                            } else {
                                GroupedDeviceToggleRow(label: group.label, devices: group.devices)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(hasActiveDevice ? accentColor.opacity(0.3) : Color(.separator).opacity(0.5), lineWidth: 1)
            )
            .shadow(color: hasActiveDevice ? accentColor.opacity(0.1) : .clear, radius: 8, y: 4)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var cardBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial)
            if hasActiveDevice {
                RoundedRectangle(cornerRadius: 14)
                    .fill(LinearGradient(
                        colors: [accentColor.opacity(0.12), accentColor.opacity(0.03)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
            }
        }
    }

    private var roomIcon: String {
        let icons: [String: String] = [
            "Kitchen": "🍳", "Master Suite": "🛏️", "Primary Bedroom": "🛏️",
            "Primary Bathroom": "🛁", "Rachel Closet": "👗", "Jason Closet": "👔",
            "Living Room": "🛋️", "Family Room": "📺", "Dining Room": "🍽️",
            "Office": "💻", "Jason Office": "💻", "Rachel Office": "💻",
            "Garage": "🚗", "Laundry": "🧺", "Bathroom": "🚿",
            "Hallway": "🚪", "Entry": "🚪", "Powder Room": "🚿",
            "Ronan's Room": "🧒", "Sebastian's Room": "👦",
            "Nursery": "👶", "Kids Room": "🧸", "Guest Room": "🛏️",
            "Theater": "🎬", "Gym": "🏋️", "Pool": "🏊",
            "Stairway": "📶", "Playroom": "🎮", "Secret Room": "🔒",
            "Nanny Suite": "🛏️", "Mechanical": "⚙️",
            "Guest Bathroom": "🚿", "Guest Bedroom": "🛏️",
            "Breakfast Nook": "🥐", "Mudroom": "🥾",
            "Front": "🏡", "Driveway": "🚗", "Rear": "🌳",
            "Exterior": "🌳", "Gelman": "🏠",
        ]
        if let icon = icons[name] { return icon }
        let lower = name.lowercased()
        for (key, icon) in icons {
            if lower.contains(key.lowercased()) { return icon }
        }
        return "🏠"
    }
}

// MARK: - Device Toggle Row (on/off toggle per device in room card)

struct DeviceToggleRow: View {
    @Environment(LutronStore.self) var store
    let device: DeviceState
    var roomName: String = ""

    private var displayName: String {
        guard !roomName.isEmpty else { return device.name }
        var n = device.name
        if n.lowercased().hasPrefix(roomName.lowercased()) {
            let stripped = String(n.dropFirst(roomName.count)).trimmingCharacters(in: .whitespaces)
            if !stripped.isEmpty { n = stripped }
        }
        if let range = n.range(of: #"^Bed \d+ "#, options: .regularExpression) {
            let stripped = String(n[range.upperBound...])
            if !stripped.isEmpty { return stripped }
        }
        return n
    }

    var body: some View {
        switch device.category {
        case .light:
            DimPill(devices: [device], displayName: displayName,
                    accentColor: .orange, leftIcon: "power", rightIcon: "lightbulb.max.fill")
        case .shadesAndDrapes:
            DimPill(devices: [device], displayName: displayName,
                    accentColor: .blue, leftIcon: "blinds.vertical.closed", rightIcon: "blinds.vertical.open")
        default:
            HStack(spacing: 6) {
                Image(systemName: deviceIcon)
                    .font(.system(size: 9))
                    .foregroundStyle(device.isOn ? iconColor : Color(.systemGray3))
                    .frame(width: 14)

                Text(displayName)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(device.isOn ? .primary : .secondary)

                Spacer()

                Button {
                    store.setLevel(device.integrationId, level: device.isOn ? 0 : 100, fadeTime: 1)
                } label: {
                    Circle()
                        .fill(device.isOn ? iconColor : Color(.systemGray5))
                        .frame(width: 20, height: 20)
                        .overlay(
                            Image(systemName: "power")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(device.isOn ? .white : Color(.systemGray3))
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var deviceIcon: String {
        switch device.category {
        case .light: return "lightbulb.fill"
        case .shadesAndDrapes: return "blinds.vertical.open"
        case .outlet: return "poweroutlet.type.b"
        case .fan: return "fan"
        case .window: return "window.vertical.open"
        }
    }

    private var iconColor: Color {
        switch device.category {
        case .light: return .orange
        case .shadesAndDrapes: return .blue
        case .outlet: return .green
        case .fan: return .teal
        case .window: return .purple
        }
    }
}

// MARK: - Grouped Device Toggle Row (controls multiple devices as one)

struct GroupedDeviceToggleRow: View {
    @Environment(LutronStore.self) var store
    let label: String
    let devices: [DeviceState]

    private var isOn: Bool { devices.contains { $0.isOn } }
    private var isLightGroup: Bool { devices.first?.category == .light }

    private var iconColor: Color {
        guard let cat = devices.first?.category else { return .orange }
        switch cat {
        case .light: return .orange
        case .shadesAndDrapes: return .blue
        case .outlet: return .green
        case .fan: return .teal
        case .window: return .purple
        }
    }

    private var deviceIcon: String {
        guard let cat = devices.first?.category else { return "lightbulb.fill" }
        switch cat {
        case .light: return "lightbulb.fill"
        case .shadesAndDrapes: return "blinds.vertical.open"
        case .outlet: return "poweroutlet.type.b"
        case .fan: return "fan"
        case .window: return "window.vertical.open"
        }
    }

    private var isShadeGroup: Bool { devices.first?.category == .shadesAndDrapes }

    var body: some View {
        if isLightGroup {
            DimPill(devices: devices, displayName: label,
                    accentColor: .orange, leftIcon: "power", rightIcon: "lightbulb.max.fill")
        } else if isShadeGroup {
            DimPill(devices: devices, displayName: label,
                    accentColor: .blue, leftIcon: "blinds.vertical.closed", rightIcon: "blinds.vertical.open")
        } else {
            HStack(spacing: 6) {
                Image(systemName: deviceIcon)
                    .font(.system(size: 9))
                    .foregroundStyle(isOn ? iconColor : Color(.systemGray3))
                    .frame(width: 14)

                Text(label)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(isOn ? .primary : .secondary)

                Spacer()

                Button {
                    let newLevel: Double = isOn ? 0 : 100
                    for device in devices {
                        store.setLevel(device.integrationId, level: newLevel, fadeTime: 1)
                    }
                } label: {
                    Circle()
                        .fill(isOn ? iconColor : Color(.systemGray5))
                        .frame(width: 20, height: 20)
                        .overlay(
                            Image(systemName: "power")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(isOn ? .white : Color(.systemGray3))
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Single Device Room Row (room name + toggle on one line)

struct SingleDeviceRoomRow: View {
    @Environment(LutronStore.self) var store
    let roomIcon: String
    let roomName: String
    let device: DeviceState
    let accentColor: Color

    var body: some View {
        if device.category == .light {
            HStack(spacing: 6) {
                Text(roomIcon).font(.system(size: 14))
                DimPill(devices: [device], displayName: roomName,
                        accentColor: .orange, leftIcon: "power", rightIcon: "lightbulb.max.fill")
            }
        } else if device.category == .shadesAndDrapes {
            HStack(spacing: 6) {
                Text(roomIcon).font(.system(size: 14))
                DimPill(devices: [device], displayName: roomName,
                        accentColor: .blue, leftIcon: "blinds.vertical.closed", rightIcon: "blinds.vertical.open")
            }
        } else {
            HStack(spacing: 6) {
                Text(roomIcon)
                    .font(.system(size: 14))
                Text(roomName)
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(.primary)

                Spacer()

                Button {
                    let newLevel: Double = device.isOn ? 0 : 100
                    store.setLevel(device.integrationId, level: newLevel, fadeTime: 1)
                } label: {
                    Circle()
                        .fill(device.isOn ? accentColor : Color(.systemGray5))
                        .frame(width: 24, height: 24)
                        .overlay(
                            Image(systemName: "power")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(device.isOn ? .white : Color(.systemGray3))
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Masonry Two Column Layout (top-aligned, no row height matching)

struct MasonryTwoColumn: Layout {
    var spacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let colWidth = (bounds.width - spacing) / 2
        var colHeights: [CGFloat] = [0, 0]

        for subview in subviews {
            let col = colHeights[0] <= colHeights[1] ? 0 : 1
            let size = subview.sizeThatFits(ProposedViewSize(width: colWidth, height: nil))
            let x = bounds.minX + CGFloat(col) * (colWidth + spacing)
            let y = bounds.minY + colHeights[col]
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: colWidth, height: size.height))
            colHeights[col] += size.height + spacing
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> CGSize {
        let totalWidth = proposal.width ?? 300
        let colWidth = (totalWidth - spacing) / 2
        var colHeights: [CGFloat] = [0, 0]

        for subview in subviews {
            let col = colHeights[0] <= colHeights[1] ? 0 : 1
            let size = subview.sizeThatFits(ProposedViewSize(width: colWidth, height: nil))
            colHeights[col] += size.height + spacing
        }

        let maxHeight = max(colHeights[0], colHeights[1]) - spacing
        return CGSize(width: totalWidth, height: max(0, maxHeight))
    }
}

// MARK: - Flow Layout (wrapping horizontal)

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangeSubviews(proposal: ProposedViewSize(width: bounds.width, height: nil), subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrangeSubviews(proposal: ProposedViewSize, subviews: Subviews) -> (positions: [CGPoint], size: CGSize) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
        }

        return (positions, CGSize(width: maxX, height: y + rowHeight))
    }
}

// MARK: - Garage Door Card

struct GarageDoorCard: View {
    let door: HMAccessory
    var homeKit: HomeKitManager

    private var state: GarageDoorState? {
        homeKit.garageDoorStates[door.uniqueIdentifier]
    }

    private var position: GarageDoorPosition {
        state?.current ?? .unknown
    }

    private var isTransitioning: Bool {
        position == .opening || position == .closing
    }

    var body: some View {
        Button {
            homeKit.toggleGarageDoor(door)
        } label: {
            VStack(spacing: 10) {
                // Icon
                Image(systemName: position.icon)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(position.color)
                    .symbolEffect(.pulse, isActive: isTransitioning)
                    .frame(height: 36)

                // Door name
                Text(door.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(.primary)

                // State label
                Text(position.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(position.color)

                // Obstruction warning
                if state?.obstructionDetected == true {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                        Text("Obstruction")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .padding(.horizontal, 12)
            .background(cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(position == .open ? Color.orange.opacity(0.3) : Color(.separator).opacity(0.5), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var cardBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial)
            if position == .open {
                RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.12))
            } else if isTransitioning {
                RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.10))
            }
        }
    }
}

// MARK: - Connection Banner

struct ConnectionBanner: View {
    @Environment(LutronStore.self) var store

    var body: some View {
        switch store.connectionState {
        case .connected:
            EmptyView()
        case .connecting:
            bannerContent(
                icon: "antenna.radiowaves.left.and.right",
                message: "Connecting to processor...",
                tint: .orange,
                showSpinner: true
            )
        case .disconnectedNeedsVPN:
            bannerContent(
                icon: "wifi.exclamationmark",
                message: "Not on home network",
                tint: .orange,
                actionLabel: "Open Tailscale",
                action: openTailscale
            )
        case .disconnectedProcessorDown:
            bannerContent(
                icon: "exclamationmark.triangle",
                message: "Processor unreachable",
                tint: .red,
                actionLabel: "Retry",
                action: { store.connect() }
            )
        case .disconnectedNoNetwork:
            bannerContent(
                icon: "wifi.slash",
                message: "No network connection",
                tint: .red
            )
        }
    }

    private func bannerContent(
        icon: String,
        message: String,
        tint: Color,
        showSpinner: Bool = false,
        actionLabel: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(message)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                if store.connectionState == .disconnectedNeedsVPN {
                    Text("Connect via Tailscale VPN to control remotely")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if showSpinner {
                ProgressView()
                    .scaleEffect(0.8)
            } else if let actionLabel, let action {
                Button(action: action) {
                    Text(actionLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(tint, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(tint.opacity(0.2), lineWidth: 1)
        )
    }

    private func openTailscale() {
        if let url = URL(string: "tailscale://") {
            UIApplication.shared.open(url) { success in
                if !success, let appStore = URL(string: "https://apps.apple.com/app/tailscale/id1470499037") {
                    UIApplication.shared.open(appStore)
                }
            }
        }
    }
}

// MARK: - Dishwasher Card

struct DishwasherCard: View {
    let status: DishwasherStatus

    var body: some View {
        VStack(spacing: 10) {
            // Icon
            Image(systemName: status.operationState.icon)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(statusColor)
                .symbolEffect(.pulse, isActive: status.operationState == .run)
                .frame(height: 36)

            // Name
            Text(status.applianceName.isEmpty ? "Dishwasher" : status.applianceName)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(.primary)

            // State
            Text(status.operationState.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(statusColor)

            // Progress / Time remaining
            if status.operationState.isActive {
                VStack(spacing: 4) {
                    if let progress = status.progress {
                        ProgressView(value: Double(progress), total: 100)
                            .tint(.cyan)
                            .scaleEffect(y: 1.5)
                        Text("\(progress)%")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    if let time = status.remainingTimeFormatted {
                        HStack(spacing: 2) {
                            Image(systemName: "clock")
                                .font(.system(size: 8))
                            Text(time)
                                .font(.system(size: 9, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                    }
                    if let program = status.programDisplayName {
                        Text(program)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            // Door state
            if status.doorState == .open {
                HStack(spacing: 2) {
                    Image(systemName: "door.left.hand.open")
                        .font(.system(size: 8))
                    Text("Door Open")
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 12)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(status.operationState.isActive ? Color.cyan.opacity(0.3) : Color(.separator).opacity(0.5), lineWidth: 1)
        )
    }

    private var statusColor: Color {
        switch status.operationState {
        case .run: return .cyan
        case .finished: return .green
        case .error, .actionRequired: return .red
        case .ready: return .green
        case .delayedStart, .pause: return .orange
        default: return .secondary
        }
    }

    @ViewBuilder
    private var cardBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial)
            if status.operationState.isActive {
                RoundedRectangle(cornerRadius: 12).fill(Color.cyan.opacity(0.10))
            }
        }
    }
}

// MARK: - Heat Pump Card

struct HeatPumpCard: View {
    @Environment(MyUplinkManager.self) var myUplink

    private var status: HeatPumpStatus { myUplink.heatPump }

    var body: some View {
        NavigationLink(destination: HeatPumpDetailView()) {
            VStack(spacing: 8) {
                // Icon
                Image(systemName: modeIcon)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(modeColor)
                    .frame(height: 36)

                // Name
                Text("Geothermal")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)

                // Mode
                if let mode = status.operatingMode {
                    Text(mode)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(modeColor)
                }

                // Key temps
                VStack(spacing: 2) {
                    if let outdoor = status.outdoorTemp {
                        tempRow(label: "Outside", value: outdoor)
                    }
                    if let supply = status.supplyLineTemp {
                        tempRow(label: "Supply", value: supply)
                    }
                    if let brineIn = status.brineInTemp {
                        tempRow(label: "Loop In", value: brineIn)
                    }
                }

                // Power
                if let power = status.currentPower {
                    HStack(spacing: 2) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 8))
                        Text(String(format: "%.1f kW", power))
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundStyle(.yellow)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .padding(.horizontal, 12)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(.separator).opacity(0.5), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func tempRow(label: String, value: Double) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Spacer()
            Text(String(format: "%.0f°F", value))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var modeIcon: String {
        let mode = (status.operatingMode ?? "").lowercased()
        if mode.contains("heat") { return "flame.fill" }
        if mode.contains("cool") { return "snowflake" }
        if mode.contains("hot water") || mode.contains("dhw") { return "drop.fill" }
        return "leaf.fill"
    }

    private var modeColor: Color {
        let mode = (status.operatingMode ?? "").lowercased()
        if mode.contains("heat") { return .orange }
        if mode.contains("cool") { return .cyan }
        if mode.contains("hot water") || mode.contains("dhw") { return .blue }
        return .green
    }
}

// MARK: - Heat Pump Detail View

struct HeatPumpDetailView: View {
    @Environment(MyUplinkManager.self) var myUplink

    private var status: HeatPumpStatus { myUplink.heatPump }

    private var categorizedPoints: [(category: String, points: [(name: String, value: String, unit: String)])] {
        var grouped: [String: [(name: String, value: String, unit: String)]] = [:]
        for dp in status.dataPoints {
            let cat = dp.category.isEmpty ? "Other" : dp.category
            grouped[cat, default: []].append((name: dp.name, value: dp.value, unit: dp.unit))
        }
        return grouped.sorted { $0.key < $1.key }.map { (category: $0.key, points: $0.value) }
    }

    var body: some View {
        List {
            // Summary section
            Section("System") {
                LabeledContent("Name", value: status.systemName)
                if let mode = status.operatingMode {
                    LabeledContent("Mode", value: mode)
                }
                if let power = status.currentPower {
                    LabeledContent("Power", value: String(format: "%.1f kW", power))
                }
                if let freq = status.compressorFrequency {
                    LabeledContent("Compressor", value: String(format: "%.0f Hz", freq))
                }
            }

            // Temperatures
            Section("Temperatures") {
                if let v = status.outdoorTemp { LabeledContent("Outdoor", value: String(format: "%.1f°F", v)) }
                if let v = status.supplyLineTemp { LabeledContent("Supply Line", value: String(format: "%.1f°F", v)) }
                if let v = status.returnLineTemp { LabeledContent("Return Line", value: String(format: "%.1f°F", v)) }
                if let v = status.brineInTemp { LabeledContent("Brine In (Loop)", value: String(format: "%.1f°F", v)) }
                if let v = status.brineOutTemp { LabeledContent("Brine Out (Loop)", value: String(format: "%.1f°F", v)) }
                if let v = status.hotWaterTemp { LabeledContent("Hot Water", value: String(format: "%.1f°F", v)) }
            }

            // Smart Home Mode
            Section("Smart Home Mode") {
                HStack {
                    modeButton("Home", mode: "Home")
                    modeButton("Away", mode: "Away")
                    modeButton("Default", mode: "Default")
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }

            // All data points by category
            ForEach(categorizedPoints, id: \.category) { group in
                Section(group.category) {
                    ForEach(group.points, id: \.name) { point in
                        LabeledContent(point.name, value: "\(point.value) \(point.unit)")
                            .font(.system(size: 13))
                    }
                }
            }
        }
        .navigationTitle("Geothermal")
        .refreshable {
            await myUplink.fetchDataPoints()
        }
    }

    private func modeButton(_ label: String, mode: String) -> some View {
        let isSelected = status.smartHomeMode == mode
        return Button {
            Task { await myUplink.setSmartHomeMode(mode) }
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(isSelected ? Color.green : Color(.tertiarySystemBackground))
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - OAuth Presentation Context Helper

// MARK: - Time-of-Day Sky Background

struct TimeOfDayBackground: View {
    let period: SunCalculator.TimePeriod

    var body: some View {
        GeometryReader { geo in
            ZStack {
                skyBase(size: geo.size)
                switch period {
                case .night:
                    LarchmontNightSky(size: geo.size)
                case .earlyMorning:
                    StarField(count: 130, spreadRatio: 0.70, opacity: 0.55, size: geo.size)
                    PreDawnGlow(size: geo.size)
                case .morning:
                    SunriseGlow(size: geo.size)
                case .midday:
                    MiddaySky(size: geo.size)
                case .evening:
                    SunsetGlow(size: geo.size)
                }
            }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func skyBase(size: CGSize) -> some View {
        switch period {
        case .night:
            // Larchmont, NY — pristine dark sky: deep black zenith fading to dark blue at horizon
            LinearGradient(stops: [
                .init(color: Color(red: 0.01, green: 0.01, blue: 0.06), location: 0.00),
                .init(color: Color(red: 0.02, green: 0.04, blue: 0.14), location: 0.45),
                .init(color: Color(red: 0.03, green: 0.06, blue: 0.20), location: 1.00),
            ], startPoint: .top, endPoint: .bottom)
        case .earlyMorning:
            LinearGradient(stops: [
                .init(color: Color(red: 0.04, green: 0.04, blue: 0.18), location: 0.0),
                .init(color: Color(red: 0.18, green: 0.10, blue: 0.38), location: 0.55),
                .init(color: Color(red: 0.45, green: 0.22, blue: 0.55), location: 0.80),
                .init(color: Color(red: 0.70, green: 0.35, blue: 0.40), location: 1.0),
            ], startPoint: .top, endPoint: .bottom)
        case .morning:
            LinearGradient(stops: [
                .init(color: Color(red: 0.45, green: 0.68, blue: 0.95), location: 0.0),
                .init(color: Color(red: 0.75, green: 0.82, blue: 0.98), location: 0.35),
                .init(color: Color(red: 0.98, green: 0.80, blue: 0.55), location: 0.70),
                .init(color: Color(red: 0.99, green: 0.65, blue: 0.25), location: 1.0),
            ], startPoint: .top, endPoint: .bottom)
        case .midday:
            LinearGradient(stops: [
                .init(color: Color(red: 0.12, green: 0.40, blue: 0.88), location: 0.0),
                .init(color: Color(red: 0.28, green: 0.60, blue: 0.98), location: 0.45),
                .init(color: Color(red: 0.55, green: 0.78, blue: 1.00), location: 1.0),
            ], startPoint: .top, endPoint: .bottom)
        case .evening:
            LinearGradient(stops: [
                .init(color: Color(red: 0.08, green: 0.04, blue: 0.22), location: 0.0),
                .init(color: Color(red: 0.40, green: 0.12, blue: 0.30), location: 0.30),
                .init(color: Color(red: 0.75, green: 0.25, blue: 0.10), location: 0.65),
                .init(color: Color(red: 0.95, green: 0.52, blue: 0.08), location: 1.0),
            ], startPoint: .top, endPoint: .bottom)
        }
    }
}

struct StarField: View {
    let count: Int
    let spreadRatio: Double
    let opacity: Double
    let size: CGSize

    var body: some View {
        Canvas { ctx, _ in
            var seed: UInt64 = 98765
            func next() -> Double {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return Double(seed >> 33) / Double(0x7FFFFFFF)
            }
            for _ in 0..<count {
                let x = next() * size.width
                let y = next() * size.height * spreadRatio
                let r = next() * 1.6 + 0.4
                let alpha = (next() * 0.55 + 0.45) * opacity
                ctx.fill(
                    Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                    with: .color(.white.opacity(alpha))
                )
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

struct MoonView: View {
    let size: CGSize
    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(
                    colors: [Color.white.opacity(0.12), Color.white.opacity(0.04), Color.clear],
                    center: .center, startRadius: 14, endRadius: 55
                ))
                .frame(width: 110, height: 110)
            Circle()
                .fill(Color(red: 0.92, green: 0.92, blue: 0.85).opacity(0.88))
                .frame(width: 26, height: 26)
        }
        .position(x: size.width * 0.78, y: size.height * 0.10)
    }
}

// MARK: - Larchmont, NY Night Sky
// Clear night with no light pollution. Winter sky facing roughly south.
// Left edge ≈ east, right edge ≈ west; top ≈ zenith, bottom ≈ horizon.

struct LarchmontNightSky: View {
    let size: CGSize
    var body: some View {
        ZStack {
            // Color-varied star field — Bortle 1 dark sky reveals thousands of stars
            DarkSkyStarField(size: size)
            // Winter Milky Way arc: Cassiopeia → Perseus → Auriga → Gemini → Orion → Canis Major
            MilkyWayBand(size: size)
            // Named bright stars and constellation lines
            NightConstellations(size: size)
            // Moon
            MoonView(size: size)
        }
    }
}

// MARK: - Dark Sky Star Field (Bortle 1 — no light pollution)
struct DarkSkyStarField: View {
    let size: CGSize

    var body: some View {
        Canvas { ctx, _ in
            var seed: UInt64 = 73621
            func next() -> Double {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return Double(seed >> 33) / Double(0x7FFFFFFF)
            }
            // Spectral type distribution: B/A (blue-white), F (white), G (yellow), K (orange), M (red)
            func starColor(_ roll: Double) -> (Double, Double, Double) {
                switch roll {
                case ..<0.28: return (0.72, 0.82, 1.00)  // B-type: blue-white
                case ..<0.58: return (0.92, 0.94, 1.00)  // A-type: white
                case ..<0.76: return (1.00, 0.98, 0.88)  // F-type: warm white
                case ..<0.88: return (1.00, 0.94, 0.68)  // G-type: yellow
                case ..<0.96: return (1.00, 0.76, 0.45)  // K-type: orange
                default:      return (1.00, 0.52, 0.28)  // M-type: red-orange
                }
            }
            let w = Double(size.width), h = Double(size.height)
            // Tier 1: faint background stars (mag 4.5–6.5) — hundreds of tiny dots
            for _ in 0..<700 {
                let x = next() * w, y = next() * h * 0.93
                let r = next() * 0.55 + 0.25
                let alpha = next() * 0.45 + 0.20
                let (cr, cg, cb) = starColor(next())
                ctx.fill(Path(ellipseIn: CGRect(x: x-r, y: y-r, width: r*2, height: r*2)),
                         with: .color(Color(red: cr, green: cg, blue: cb).opacity(alpha)))
            }
            // Tier 2: moderate stars (mag 2.5–4.5)
            for _ in 0..<180 {
                let x = next() * w, y = next() * h * 0.90
                let r = next() * 0.75 + 0.60
                let alpha = next() * 0.30 + 0.55
                let (cr, cg, cb) = starColor(next())
                ctx.fill(Path(ellipseIn: CGRect(x: x-r, y: y-r, width: r*2, height: r*2)),
                         with: .color(Color(red: cr, green: cg, blue: cb).opacity(alpha)))
            }
            // Tier 3: bright background stars (mag 1–2.5) with a small glow halo
            for _ in 0..<45 {
                let x = next() * w, y = next() * h * 0.88
                let r = next() * 0.6 + 1.1
                let alpha = 0.80 + next() * 0.18
                let (cr, cg, cb) = starColor(next())
                ctx.fill(Path(ellipseIn: CGRect(x: x-r*2.5, y: y-r*2.5, width: r*5, height: r*5)),
                         with: .color(Color(red: cr, green: cg, blue: cb).opacity(0.12)))
                ctx.fill(Path(ellipseIn: CGRect(x: x-r, y: y-r, width: r*2, height: r*2)),
                         with: .color(Color(red: cr, green: cg, blue: cb).opacity(alpha)))
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

// MARK: - Milky Way Band
// Winter arc: Cassiopeia (upper-left) → Perseus → Auriga → Gemini → Orion → Canis Major
struct MilkyWayBand: View {
    let size: CGSize

    private func buildPath() -> Path {
        let w = size.width, h = size.height
        var p = Path()
        p.move(to:        CGPoint(x: 0.00 * w, y: 0.34 * h))
        p.addCurve(to:    CGPoint(x: 0.30 * w, y: 0.07 * h),
                   control1: CGPoint(x: 0.06 * w, y: 0.14 * h),
                   control2: CGPoint(x: 0.18 * w, y: 0.06 * h))
        p.addCurve(to:    CGPoint(x: 0.65 * w, y: 0.13 * h),
                   control1: CGPoint(x: 0.44 * w, y: 0.07 * h),
                   control2: CGPoint(x: 0.56 * w, y: 0.09 * h))
        p.addCurve(to:    CGPoint(x: 0.75 * w, y: 0.32 * h),
                   control1: CGPoint(x: 0.72 * w, y: 0.17 * h),
                   control2: CGPoint(x: 0.76 * w, y: 0.23 * h))
        p.addCurve(to:    CGPoint(x: 0.56 * w, y: 0.62 * h),
                   control1: CGPoint(x: 0.74 * w, y: 0.45 * h),
                   control2: CGPoint(x: 0.65 * w, y: 0.55 * h))
        p.addCurve(to:    CGPoint(x: 0.44 * w, y: 1.02 * h),
                   control1: CGPoint(x: 0.50 * w, y: 0.74 * h),
                   control2: CGPoint(x: 0.46 * w, y: 0.88 * h))
        return p
    }

    var body: some View {
        let path = buildPath()
        let lw = size.width  // reference width for line widths
        ZStack {
            // Layer 1: wide outer halo — barely perceptible
            Canvas { ctx, _ in
                ctx.stroke(path,
                           with: .color(Color(red: 0.78, green: 0.85, blue: 1.00).opacity(0.09)),
                           style: StrokeStyle(lineWidth: lw * 0.24, lineCap: .round, lineJoin: .round))
            }
            .blur(radius: 20)

            // Layer 2: main diffuse band
            Canvas { ctx, _ in
                ctx.stroke(path,
                           with: .color(Color(red: 0.80, green: 0.88, blue: 1.00).opacity(0.14)),
                           style: StrokeStyle(lineWidth: lw * 0.11, lineCap: .round, lineJoin: .round))
            }
            .blur(radius: 9)

            // Layer 3: brighter inner core
            Canvas { ctx, _ in
                ctx.stroke(path,
                           with: .color(Color(red: 0.88, green: 0.92, blue: 1.00).opacity(0.11)),
                           style: StrokeStyle(lineWidth: lw * 0.04, lineCap: .round, lineJoin: .round))
            }
            .blur(radius: 3)

            // Layer 4: dense unresolved star clusters scattered along the band
            Canvas { ctx, _ in
                var seed: UInt64 = 11223
                func next() -> Double {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    return Double(seed >> 33) / Double(0x7FFFFFFF)
                }
                let w = Double(size.width), h = Double(size.height)
                // Sample points approximating the bezier above
                let samples: [(Double, Double)] = [
                    (0.02,0.30),(0.08,0.18),(0.14,0.10),(0.22,0.07),(0.30,0.07),
                    (0.38,0.08),(0.48,0.09),(0.57,0.11),(0.64,0.13),(0.69,0.19),
                    (0.73,0.25),(0.74,0.32),(0.72,0.40),(0.67,0.48),(0.62,0.54),
                    (0.57,0.61),(0.52,0.68),(0.48,0.76),(0.45,0.86),(0.43,0.96),
                ]
                let spread = w * 0.055
                for pt in samples {
                    for _ in 0..<22 {
                        let x = pt.0 * w + (next() - 0.5) * spread * 2
                        let y = pt.1 * h + (next() - 0.5) * spread * 0.7
                        let r = next() * 0.45 + 0.18
                        let alpha = next() * 0.42 + 0.20
                        ctx.fill(Path(ellipseIn: CGRect(x: x-r, y: y-r, width: r*2, height: r*2)),
                                 with: .color(Color.white.opacity(alpha)))
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

struct NightConstellations: View {
    let size: CGSize

    var body: some View {
        Canvas { ctx, _ in
            let w = size.width
            let h = size.height

            // Draw a star dot at normalised (nx, ny)
            func dot(_ nx: CGFloat, _ ny: CGFloat, r: CGFloat, _ color: Color, alpha: CGFloat = 0.92) {
                ctx.fill(
                    Path(ellipseIn: CGRect(x: nx * w - r, y: ny * h - r, width: r * 2, height: r * 2)),
                    with: .color(color.opacity(alpha))
                )
            }
            // Bright star: layered glow + core
            func brightStar(_ nx: CGFloat, _ ny: CGFloat, r: CGFloat, _ color: Color) {
                dot(nx, ny, r: r * 3.5, color, alpha: 0.08)
                dot(nx, ny, r: r * 2.0, color, alpha: 0.18)
                dot(nx, ny, r: r,       color, alpha: 0.95)
            }
            // Constellation line between normalised coords
            func line(_ ax: CGFloat, _ ay: CGFloat, _ bx: CGFloat, _ by: CGFloat, alpha: CGFloat = 0.20) {
                var p = Path()
                p.move(to: CGPoint(x: ax * w, y: ay * h))
                p.addLine(to: CGPoint(x: bx * w, y: by * h))
                ctx.stroke(p, with: .color(.white.opacity(alpha)), lineWidth: 0.5)
            }

            let white      = Color.white
            let blueWhite  = Color(red: 0.80, green: 0.88, blue: 1.00)
            let warmYellow = Color(red: 1.00, green: 0.95, blue: 0.65)
            let orange     = Color(red: 1.00, green: 0.58, blue: 0.28)
            let orangeRed  = Color(red: 0.98, green: 0.42, blue: 0.22)

            // ── ORION ─────────────────────────────────────────────────────────
            // Dominant winter constellation; centre-south sky from Larchmont
            line(0.36, 0.42, 0.55, 0.40)           // shoulders
            line(0.36, 0.42, 0.38, 0.51)           // Betelgeuse → belt
            line(0.55, 0.40, 0.53, 0.50)           // Bellatrix → belt
            line(0.38, 0.51, 0.46, 0.50)           // belt L–M
            line(0.46, 0.50, 0.53, 0.50)           // belt M–R
            line(0.38, 0.51, 0.40, 0.63)           // Alnitak → Saiph
            line(0.53, 0.50, 0.57, 0.63)           // Mintaka → Rigel
            dot(0.36, 0.42, r: 3.2, orangeRed)     // Betelgeuse — red supergiant
            dot(0.55, 0.40, r: 2.2, blueWhite)     // Bellatrix
            dot(0.38, 0.51, r: 1.8, blueWhite)     // Alnitak  (belt east)
            dot(0.46, 0.50, r: 1.6, white)         // Alnilam  (belt centre)
            dot(0.53, 0.50, r: 1.7, blueWhite)     // Mintaka  (belt west)
            dot(0.40, 0.63, r: 2.0, blueWhite)     // Saiph
            brightStar(0.57, 0.63, r: 3.5, blueWhite) // Rigel — brilliant blue-white

            // ── SIRIUS ────────────────────────────────────────────────────────
            // Brightest star in sky; low southeast in winter from Larchmont
            brightStar(0.43, 0.77, r: 4.2, blueWhite)

            // ── TAURUS ────────────────────────────────────────────────────────
            line(0.66, 0.37, 0.72, 0.30)
            line(0.66, 0.37, 0.62, 0.30)
            dot(0.66, 0.37, r: 2.8, orange)        // Aldebaran — orange giant
            dot(0.72, 0.30, r: 1.4, white)
            dot(0.62, 0.30, r: 1.2, white)

            // ── PLEIADES ──────────────────────────────────────────────────────
            // Seven Sisters cluster above Taurus; clearly visible despite light pollution
            let pleiadesOffsets: [(CGFloat, CGFloat)] = [
                (0.000,  0.000), (0.025, -0.020), (0.050,  0.010),
                (0.020,  0.025), (0.045, -0.010), (0.010,  0.015), (0.035,  0.020)
            ]
            for (dx, dy) in pleiadesOffsets {
                dot(0.78 + dx, 0.20 + dy, r: 1.1, Color(red: 0.85, green: 0.90, blue: 1.00))
            }

            // ── GEMINI ────────────────────────────────────────────────────────
            line(0.74, 0.26, 0.78, 0.32)           // Castor – Pollux
            line(0.74, 0.26, 0.55, 0.40)           // toward Bellatrix
            line(0.78, 0.32, 0.57, 0.43)
            dot(0.74, 0.26, r: 2.0, white)         // Castor
            dot(0.78, 0.32, r: 2.6, warmYellow)    // Pollux — slightly warm

            // ── CAPELLA ───────────────────────────────────────────────────────
            // Bright yellow star, nearly overhead in winter nights
            brightStar(0.64, 0.14, r: 3.2, warmYellow)

            // ── PROCYON ───────────────────────────────────────────────────────
            // Canis Minor; east of Orion, clearly visible
            dot(0.22, 0.54, r: 2.6, Color(red: 0.95, green: 0.95, blue: 0.90))

            // ── BIG DIPPER (Ursa Major) ───────────────────────────────────────
            // Northeast sky, high in winter evenings from Larchmont (~41° N)
            let dipper: [(CGFloat, CGFloat)] = [
                (0.90, 0.14),   // Dubhe
                (0.87, 0.19),   // Merak
                (0.83, 0.15),   // Phecda
                (0.80, 0.12),   // Megrez (faintest of bowl)
                (0.75, 0.16),   // Alioth
                (0.71, 0.11),   // Mizar
                (0.66, 0.08),   // Alkaid
            ]
            let dipperLinks = [(0, 1), (1, 2), (2, 3), (3, 4), (4, 5), (5, 6)]
            for (a, b) in dipperLinks {
                line(dipper[a].0, dipper[a].1, dipper[b].0, dipper[b].1, alpha: 0.22)
            }
            for (i, s) in dipper.enumerated() {
                dot(s.0, s.1, r: i == 3 ? 1.5 : 2.0, white)
            }

            // ── POLARIS ───────────────────────────────────────────────────────
            // North Star — fixed at 40.9° altitude above north horizon from Larchmont
            dot(0.90, 0.06, r: 2.1, Color(red: 0.90, green: 0.90, blue: 0.95))

            // ── CASSIOPEIA ────────────────────────────────────────────────────
            // Distinctive W-shape; circumpolar from Larchmont, upper left (north-northwest)
            let cass: [(CGFloat, CGFloat)] = [
                (0.09, 0.10), (0.14, 0.05), (0.19, 0.10), (0.24, 0.05), (0.29, 0.09)
            ]
            for i in 0..<4 {
                line(cass[i].0, cass[i].1, cass[i + 1].0, cass[i + 1].1, alpha: 0.22)
            }
            for s in cass { dot(s.0, s.1, r: 1.8, white) }
        }
        .frame(width: size.width, height: size.height)
    }
}

struct PreDawnGlow: View {
    let size: CGSize
    var body: some View {
        RadialGradient(
            colors: [
                Color(red: 0.85, green: 0.50, blue: 0.60).opacity(0.55),
                Color(red: 0.60, green: 0.25, blue: 0.55).opacity(0.30),
                Color.clear,
            ],
            center: UnitPoint(x: 0.5, y: 1.05),
            startRadius: 0, endRadius: size.height * 0.55
        )
        .frame(width: size.width, height: size.height)
    }
}

struct SunriseGlow: View {
    let size: CGSize
    var body: some View {
        ZStack {
            RadialGradient(
                colors: [
                    Color(red: 1.00, green: 0.88, blue: 0.40).opacity(0.75),
                    Color(red: 1.00, green: 0.60, blue: 0.20).opacity(0.50),
                    Color(red: 0.95, green: 0.35, blue: 0.10).opacity(0.20),
                    Color.clear,
                ],
                center: UnitPoint(x: 0.5, y: 1.10),
                startRadius: 0, endRadius: size.height * 0.80
            )
            Circle()
                .fill(RadialGradient(
                    colors: [
                        Color.white.opacity(0.95),
                        Color(red: 1.0, green: 0.92, blue: 0.55).opacity(0.90),
                        Color(red: 1.0, green: 0.80, blue: 0.30).opacity(0.60),
                        Color.clear,
                    ],
                    center: .center, startRadius: 0, endRadius: 60
                ))
                .frame(width: 120, height: 120)
                .position(x: size.width * 0.50, y: size.height * 0.78)
        }
        .frame(width: size.width, height: size.height)
    }
}

struct MiddaySky: View {
    let size: CGSize
    var body: some View {
        ZStack {
            RadialGradient(
                colors: [Color.white.opacity(0.25), Color(red: 0.85, green: 0.92, blue: 1.0).opacity(0.15), Color.clear],
                center: UnitPoint(x: 0.62, y: 0.08),
                startRadius: 0, endRadius: size.width * 0.55
            )
            LinearGradient(
                colors: [.clear, Color(red: 0.75, green: 0.88, blue: 1.0).opacity(0.18)],
                startPoint: UnitPoint(x: 0.5, y: 0.6), endPoint: .bottom
            )
        }
        .frame(width: size.width, height: size.height)
    }
}

struct SunsetGlow: View {
    let size: CGSize
    var body: some View {
        ZStack {
            RadialGradient(
                colors: [
                    Color(red: 1.00, green: 0.65, blue: 0.15).opacity(0.80),
                    Color(red: 0.90, green: 0.30, blue: 0.08).opacity(0.55),
                    Color(red: 0.55, green: 0.10, blue: 0.25).opacity(0.25),
                    Color.clear,
                ],
                center: UnitPoint(x: 0.5, y: 1.08),
                startRadius: 0, endRadius: size.height * 0.85
            )
            Circle()
                .fill(RadialGradient(
                    colors: [
                        Color.white.opacity(0.90),
                        Color(red: 1.0, green: 0.75, blue: 0.25).opacity(0.85),
                        Color(red: 1.0, green: 0.40, blue: 0.10).opacity(0.50),
                        Color.clear,
                    ],
                    center: .center, startRadius: 0, endRadius: 70
                ))
                .frame(width: 140, height: 140)
                .position(x: size.width * 0.45, y: size.height * 0.82)
            LinearGradient(
                colors: [.clear, Color(red: 0.70, green: 0.12, blue: 0.05).opacity(0.22), Color(red: 0.40, green: 0.06, blue: 0.18).opacity(0.18)],
                startPoint: UnitPoint(x: 0.5, y: 0.65), endPoint: .bottom
            )
        }
        .frame(width: size.width, height: size.height)
    }
}

// MARK: - OAuth

class OAuthPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first else {
            return ASPresentationAnchor(windowScene: UIApplication.shared.connectedScenes.first as! UIWindowScene)
        }
        return window
    }
}
