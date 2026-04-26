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
                    Text("HOME")
                }
                .tag(0)

            CategoryTab(category: .light)
                .tabItem {
                    Image(systemName: "lightbulb.fill")
                    Text("LIGHTS")
                }
                .tag(1)

            CategoryTab(categories: [.shadesAndDrapes, .window], title: "Shades & Windows")
                .tabItem {
                    Image(systemName: "blinds.vertical.open")
                    Text("SHADES")
                }
                .tag(2)

            AppliancesTab()
                .tabItem {
                    Image(systemName: "washer")
                    Text("APPLIANCES")
                }
                .tag(3)

            CategoryTab(categories: [.outlet, .fan], title: "More", showAlarmZones: true, showKeypads: true)
                .tabItem {
                    Image(systemName: "poweroutlet.type.b")
                    Text("MORE")
                }
                .tag(4)
        }
        .onAppear { store.start() }
        .tint(EditorialTheme.accent)
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
    @Environment(TotalConnectManager.self) var totalConnect
    let categories: [DeviceCategory]
    let title: String
    let showAlarmZones: Bool
    let showKeypads: Bool
    @State private var selectedRoom: String?

    init(category: DeviceCategory) {
        self.categories = [category]
        self.title = category.rawValue
        self.showAlarmZones = false
        self.showKeypads = false
    }

    init(categories: [DeviceCategory], title: String, showAlarmZones: Bool = false, showKeypads: Bool = false) {
        self.categories = categories
        self.title = title
        self.showAlarmZones = showAlarmZones
        self.showKeypads = showKeypads
    }

    private var categoryRooms: [(name: String, devices: [DeviceState])] {
        store.rooms.compactMap { room in
            let filtered = room.devices.filter { categories.contains($0.category) }
            return filtered.isEmpty ? nil : (name: room.name, devices: filtered)
        }
    }

    private var isLightsTab: Bool { categories == [.light] }
    private var isLightsOrShadesTab: Bool {
        categories.count == 1 && (categories[0] == .light || categories[0] == .shadesAndDrapes)
    }

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
                        VStack(alignment: .leading, spacing: EditorialTheme.sectionSpacing) {
                            // Tab header
                            HStack(alignment: .firstTextBaseline) {
                                Text(title.uppercased())
                                    .font(EditorialTheme.bebasNeue(size: 32))
                                    .foregroundStyle(EditorialTheme.primaryText)
                                Spacer()
                                if !categoryRooms.isEmpty {
                                    Text("\(categoryRooms.flatMap(\.devices).count) DEVICES")
                                        .font(EditorialTheme.sectionLabel(size: 10))
                                        .tracking(0.8)
                                        .foregroundStyle(EditorialTheme.secondaryText)
                                }
                            }

                            if isLightsTab && activeFloors.count > 1 {
                                floorAnchorBar(proxy: proxy)
                            }

                            if categoryRooms.isEmpty && !(showAlarmZones && totalConnect.isLinked) && !showKeypads {
                                emptyState
                            } else {
                                // Group devices by category when showing multiple categories
                                if categories.count > 1 {
                                    ForEach(categories, id: \.self) { cat in
                                        let catRooms = categoryRooms.compactMap { room -> (name: String, devices: [DeviceState])? in
                                            let filtered = room.devices.filter { $0.category == cat }
                                            return filtered.isEmpty ? nil : (name: room.name, devices: filtered)
                                        }
                                        if !catRooms.isEmpty {
                                            VStack(alignment: .leading, spacing: EditorialTheme.gridSpacing) {
                                                EditorialSectionHeader(
                                                    title: cat.rawValue,
                                                    trailing: "\(catRooms.flatMap(\.devices).count) DEVICES"
                                                )

                                                MasonryTwoColumn(spacing: EditorialTheme.gridSpacing) {
                                                    ForEach(catRooms, id: \.name) { room in
                                                        CategoryRoomCard(
                                                            name: room.name,
                                                            devices: room.devices,
                                                            category: cat,
                                                            onTap: { selectedRoom = room.name }
                                                        )
                                                    }
                                                }
                                            }
                                        }
                                    }
                                } else {
                                    ForEach(Floor.allCases, id: \.self) { floor in
                                        let floorRooms = categoryRooms.filter { Floor.floor(for: $0.name) == floor }
                                        if !floorRooms.isEmpty {
                                            floorSection(floor: floor, rooms: floorRooms)
                                                .id(floor)
                                        }
                                    }
                                }
                                if showAlarmZones && totalConnect.isLinked {
                                    alarmZonesSection
                                }
                                if showKeypads {
                                    KeypadsSection()
                                }
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top, 12)
                    }
                }
                .refreshable { await store.refresh() }
                .background(EditorialTheme.background.ignoresSafeArea())
                .toolbar(.hidden, for: .navigationBar)
            }
        }
    }

    private func floorAnchorBar(proxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(activeFloors, id: \.self) { floor in
                    Button {
                        proxy.scrollTo(floor, anchor: .top)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: floor.icon)
                                .font(.system(size: 9))
                            Text(floor.rawValue.uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .tracking(0.6)
                                .lineLimit(1)
                        }
                        .foregroundStyle(EditorialTheme.primaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(EditorialTheme.cardBackground)
                        .overlay(
                            Rectangle().stroke(EditorialTheme.cardBorder, lineWidth: 0.5)
                        )
                        .fixedSize()
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func floorSection(floor: Floor, rooms: [(name: String, devices: [DeviceState])]) -> some View {
        VStack(alignment: .leading, spacing: EditorialTheme.gridSpacing) {
            EditorialSectionHeader(
                title: floor.rawValue,
                trailing: "\(rooms.flatMap(\.devices).count) DEVICES"
            )

            if isLightsOrShadesTab {
                // Lights & shades: masonry 2-column, each room kept together
                MasonryTwoColumn(spacing: EditorialTheme.gridSpacing) {
                    ForEach(rooms, id: \.name) { room in
                        VStack(alignment: .leading, spacing: 6) {
                            Button { selectedRoom = room.name } label: {
                                HStack(spacing: 4) {
                                    Text(room.name.uppercased())
                                        .font(.system(size: 9, weight: .medium))
                                        .tracking(0.8)
                                        .foregroundStyle(EditorialTheme.secondaryText)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 7, weight: .semibold))
                                        .foregroundStyle(EditorialTheme.tertiaryText)
                                }
                            }
                            .buttonStyle(.plain)

                            ForEach(room.devices) { device in
                                let fade: Double? = device.category == .shadesAndDrapes ? 2 : nil
                                DimmablePill(device: device, fadeTime: fade)
                            }
                        }
                    }
                }
            } else {
                // Other categories: room cards with masonry layout
                MasonryTwoColumn(spacing: EditorialTheme.gridSpacing) {
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
    }

    private var alarmZonesSection: some View {
        VStack(alignment: .leading, spacing: EditorialTheme.gridSpacing) {
            EditorialSectionHeader(title: "Alarm Zones")

            let allZones = totalConnect.panels.flatMap { panel in
                (totalConnect.zones[panel.locationId] ?? []).map { (panel, $0) }
            }

            if allZones.isEmpty {
                Text("No zones reported")
                    .font(.system(size: 10, weight: .medium))
                    .tracking(0.6)
                    .foregroundStyle(EditorialTheme.secondaryText)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(EditorialTheme.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: EditorialTheme.cardRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: EditorialTheme.cardRadius)
                            .stroke(EditorialTheme.cardBorder, lineWidth: 0.5)
                    )
            } else {
                VStack(spacing: 1) {
                    ForEach(allZones, id: \.1.id) { _, zone in
                        AlarmZoneRow(zone: zone)
                    }
                }
                .background(EditorialTheme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: EditorialTheme.cardRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: EditorialTheme.cardRadius)
                        .stroke(EditorialTheme.cardBorder, lineWidth: 0.5)
                )
            }
        }
    }

    private var emptyState: some View {
        HStack {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: categories.first?.icon ?? "questionmark")
                    .font(.largeTitle)
                    .foregroundStyle(EditorialTheme.secondaryText)
                Text(store.isConnected ? "No \(title.lowercased()) found" : "Not connected")
                    .foregroundStyle(EditorialTheme.secondaryText)
                    .font(.system(size: 12, weight: .medium))
            }
            Spacer()
        }
        .padding(.vertical, 40)
        .background(EditorialTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: EditorialTheme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: EditorialTheme.cardRadius)
                .stroke(EditorialTheme.cardBorder, lineWidth: 0.5)
        )
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
    @Environment(MyQManager.self) var myQ
    @Environment(EcobeeManager.self) var ecobee
    @Environment(SonosManager.self) var sonos

    @State private var showDishwasherStartSheet = false
    @State private var selectedDishwasherId: String?

    var body: some View {
        ScrollView {
            VStack(spacing: EditorialTheme.sectionSpacing) {
                EditorialTopBar()
                EditorialHeroSection()
                EditorialStatsRow()
                EditorialSuggestedAction()
                EditorialStatusGrid()
                EditorialClimateSection()
                EditorialCameraSection()
                EditorialLightsSection()
                EditorialShadesSection()
            }
            .padding(.horizontal)
            .padding(.top, 12)
        }
        .refreshable {
            await store.refresh()
        }
        .background(EditorialTheme.background.ignoresSafeArea())
        .scrollContentBackground(.hidden)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showDishwasherStartSheet) {
            if let id = selectedDishwasherId {
                DishwasherStartSheet(applianceId: id)
            }
        }
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

    // MARK: - Status Glance (Instrument Panel)

    private struct StatusCell: Identifiable {
        let id: String
        let label: String
        let value: String
        let suffix: String?
        let isActive: Bool
        let isAlarming: Bool

        init(_ id: String, label: String, value: String, suffix: String? = nil, isActive: Bool, isAlarming: Bool = false) {
            self.id = id; self.label = label; self.value = value
            self.suffix = suffix; self.isActive = isActive; self.isAlarming = isAlarming
        }
    }

    private var statusCells: [StatusCell] {
        var cells: [StatusCell] = []

        // Thermostats (first — top row)
        for thermo in ecobee.thermostats {
            let value = "\(Int(thermo.currentTemp))°"
            let suffix = thermo.hvacMode.label
            cells.append(StatusCell("thermo_\(thermo.id)", label: thermo.displayName, value: value, suffix: suffix, isActive: thermo.hvacMode != .off))
        }

        // Alarm
        if totalConnect.isLinked, let panel = totalConnect.panels.first {
            if totalConnect.authFailed {
                cells.append(StatusCell("alarm", label: "Alarm", value: "Unavailable", suffix: nil, isActive: false))
            } else {
                let faults = (totalConnect.zones[panel.locationId] ?? []).filter { $0.faulted }.count
                let value = panel.state.label
                let suffix: String? = faults > 0 ? "\(faults)f" : nil
                let active = panel.state.isArmed || panel.state == .alarming || faults > 0
                cells.append(StatusCell("alarm", label: "Alarm", value: value, suffix: suffix, isActive: active, isAlarming: panel.state == .alarming))
            }
        }

        // Dishwashers
        if homeConnect.isLinked {
            let dws = homeConnect.dishwashers
            for dw in dws {
                var value = dw.operationState.label
                if dw.operationState.isActive, let time = dw.remainingTimeFormatted {
                    value = time
                }
                let active = dw.operationState.isActive || dw.operationState == .finished
                let label: String
                if dws.count > 1 {
                    let name = dw.applianceName.lowercased()
                    if name.contains("left") { label = "Dish L" }
                    else if name.contains("right") { label = "Dish R" }
                    else { label = dw.applianceName.isEmpty ? "Dishes" : String(dw.applianceName.prefix(7)) }
                } else {
                    label = "Dishes"
                }
                cells.append(StatusCell("dw_\(dw.applianceId)", label: label, value: value, isActive: active))
            }
        }

        // Washer / Dryer
        if smartHQ.isLinked {
            for app in smartHQ.appliances {
                var value = app.machineState.label
                if app.machineState.isActive, let time = app.remainingTimeFormatted {
                    value = time
                }
                let active = app.machineState.isActive || app.machineState == .endOfCycle
                let label = app.isWasher ? "Washer" : "Dryer"
                cells.append(StatusCell("shq_\(app.id)", label: label, value: value, isActive: active))
            }
        }

        // Garage
        if myQ.isLinked {
            for door in myQ.doors {
                let active = door.state == .open || door.state.isMoving
                cells.append(StatusCell("garage_\(door.id)", label: "Garage", value: door.state.label, isActive: active))
            }
        }

        // Heat Pump
        if myUplink.isLinked, myUplink.heatPump.connected {
            let hp = myUplink.heatPump
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
            cells.append(StatusCell("hvac", label: "HVAC", value: value, suffix: suffix, isActive: true))
        }

        // Sonos speakers
        for player in sonos.coordinators {
            let value: String
            let active: Bool
            if player.state == .playing, let track = player.currentTrack {
                value = track.title
                active = true
            } else {
                value = "Off"
                active = false
            }
            cells.append(StatusCell("sonos_\(player.id)", label: player.name, value: value, isActive: active))
        }

        // Lutron lights summary
        if store.connectionState == .connected {
            let onCount = store.devices.values.filter { $0.category == .light && $0.level > 0 }.count
            let value = onCount == 0 ? "All off" : "\(onCount) on"
            cells.append(StatusCell("lights", label: "Lights", value: value, isActive: onCount > 0))
        }

        return cells
    }

    private var hasAlarmTriggered: Bool {
        statusCells.contains { $0.isAlarming }
    }

    @ViewBuilder
    private var statusGlanceSection: some View {
        let cells = statusCells
        if !cells.isEmpty {
            let colCount = 4
            let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: colCount)
            let rows: [[StatusCell]] = stride(from: 0, to: cells.count, by: colCount).map {
                Array(cells[$0..<min($0 + colCount, cells.count)])
            }

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                    if rowIdx > 0 {
                        Divider().overlay(Color(.separator).opacity(0.15))
                    }
                    LazyVGrid(columns: columns, spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.element.id) { index, cell in
                            statusCellView(cell, showRightBorder: index < colCount - 1)
                        }
                        if row.count < colCount {
                            ForEach(row.count..<colCount, id: \.self) { index in
                                Color.clear.frame(maxWidth: .infinity)
                                    .overlay(alignment: .trailing) {
                                        if index < colCount - 1 && index + row.count < colCount - 1 {
                                            Rectangle().fill(Color(.separator).opacity(0.15)).frame(width: 0.5)
                                        }
                                    }
                            }
                        }
                    }
                }
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(hasAlarmTriggered ? Color.red.opacity(0.25) : Color(.separator).opacity(0.3), lineWidth: 0.5)
            )
        }
    }

    @ViewBuilder
    private func statusCellView(_ cell: StatusCell, showRightBorder: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(cell.label)
                .font(.system(size: 9))
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(
                    cell.isAlarming ? Color.red.opacity(0.7) :
                    cell.isActive ? Color.blue.opacity(0.6) :
                    Color.primary.opacity(0.35)
                )

            HStack(spacing: 2) {
                Text(cell.value)
                    .font(.system(size: 14, weight: cell.isAlarming ? .heavy : cell.isActive ? .bold : .medium))
                    .foregroundStyle(
                        cell.isAlarming ? .red :
                        cell.isActive ? .blue :
                        Color.primary.opacity(0.35)
                    )
                    .lineLimit(1)

                if let suffix = cell.suffix {
                    Text(suffix)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.primary.opacity(0.45))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 10)
        .background(
            cell.isAlarming ? Color.red.opacity(0.10) :
            cell.isActive ? Color.blue.opacity(0.07) :
            Color.clear
        )
        .overlay(alignment: .trailing) {
            if showRightBorder {
                Rectangle()
                    .fill(Color(.separator).opacity(0.15))
                    .frame(width: 0.5)
            }
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

    // MARK: - Unified Home Control (max 8 items, priority-ranked)

    private enum DashboardItem: Identifiable {
        case contextualAction(title: String, icon: String, actionId: String)
        case dishwasher(DishwasherStatus)
        case laundry(LaundryApplianceStatus)
        case forYouEvening
        case forYouDevice(deviceId: Int)
        case alarmPanel(AlarmPanel)
        case thermostat(EcobeeThermostat)
        case sonosPlayer(SonosPlayer)
        case staticAction(title: String, icon: String, color: Color, actionId: String)
        case room(name: String, icon: String)

        var id: String {
            switch self {
            case .contextualAction(_, _, let id): return "ctx_\(id)"
            case .dishwasher(let dw): return "dw_\(dw.applianceId)"
            case .laundry(let app): return "lnd_\(app.id)"
            case .forYouEvening: return "foryou_evening"
            case .forYouDevice(let id): return "foryou_\(id)"
            case .alarmPanel(let panel): return "alarm_\(panel.id)"
            case .thermostat(let t): return "thermo_\(t.id)"
            case .sonosPlayer(let p): return "sonos_\(p.id)"
            case .staticAction(_, _, _, let id): return "static_\(id)"
            case .room(let name, _): return "room_\(name)"
            }
        }
    }

    private var dashboardItems: [DashboardItem] {
        let maxItems = 8
        var items: [DashboardItem] = []

        let contextualActions = SunCalculator.contextualActions()
        let isEvening = TimeBucket.current() == .evening
        let hasEveningContextual = contextualActions.contains(where: { $0.id == "evening" })
        let topDevices = usageTracker.topDevices(isEvening ? 3 : 4, timeWindowSeconds: 30 * 24 * 60 * 60)
        let hasForYou = isEvening || (!topDevices.isEmpty && usageTracker.events.count >= 5)

        // 1. Contextual actions (time-sensitive, ephemeral)
        for action in contextualActions {
            guard items.count < maxItems else { break }
            items.append(.contextualAction(title: action.title, icon: action.icon, actionId: action.id))
        }

        // 2a. Alarm panels (safety/security — high priority)
        if totalConnect.isLinked {
            for panel in totalConnect.panels {
                guard items.count < maxItems else { break }
                items.append(.alarmPanel(panel))
            }
        }

        // 2b. Thermostats (climate — high priority like alarm)
        if ecobee.hasThermostats {
            for thermo in ecobee.thermostats {
                guard items.count < maxItems else { break }
                items.append(.thermostat(thermo))
            }
        }

        // 2c. Sonos speakers (media — high priority like alarm/climate)
        for player in sonos.coordinators where player.state == .playing || player.currentTrack != nil {
            guard items.count < maxItems else { break }
            items.append(.sonosPlayer(player))
        }

        // 3. Active/startable appliances only (skip idle)
        if homeConnect.isLinked {
            for dw in homeConnect.dishwashers where dw.operationState.isActive || dw.canRemoteStart {
                guard items.count < maxItems else { break }
                items.append(.dishwasher(dw))
            }
        }
        if smartHQ.isLinked {
            for app in smartHQ.appliances where app.machineState.isActive {
                guard items.count < maxItems else { break }
                items.append(.laundry(app))
            }
        }

        // 3. For You device shortcuts (personalized)
        if hasForYou {
            if isEvening && !hasEveningContextual && items.count < maxItems {
                items.append(.forYouEvening)
            }
            for device in topDevices {
                guard items.count < maxItems else { break }
                items.append(.forYouDevice(deviceId: Int(device.id) ?? 0))
            }
        }

        // 4. Static quick actions (high-utility bulk operations)
        let statics: [(String, String, Color, String)] = [
            ("Main Floor Off", "power", .orange, "main_floor_off"),
            ("Upstairs Off", "power", .orange, "upstairs_off"),
            ("Main Shades Toggle", "blinds.vertical.closed", .blue, "shades_toggle"),
        ]
        for (title, icon, color, actionId) in statics {
            guard items.count < maxItems else { break }
            items.append(.staticAction(title: title, icon: icon, color: color, actionId: actionId))
        }

        // 5. Room controls fill remaining slots
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
        let allRooms = usageTracker.events.isEmpty ? defaultRooms : Array(sorted)

        for room in allRooms {
            guard items.count < maxItems else { break }
            items.append(.room(name: room, icon: roomIcons[room] ?? "🏠"))
        }

        return items
    }

    private var unifiedControlSection: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(dashboardItems) { item in
                switch item {
                case .contextualAction(let title, let icon, let actionId):
                    QuickActionButton(title: title, icon: icon, color: .orange) {
                        handleContextualAction(actionId)
                    }

                case .dishwasher(let dw):
                    if dw.canRemoteStart {
                        Button {
                            selectedDishwasherId = dw.applianceId
                            showDishwasherStartSheet = true
                            Task { await homeConnect.fetchAvailablePrograms(for: dw.applianceId) }
                        } label: {
                            AppliancePill(
                                title: dw.applianceName.isEmpty ? "Dishwasher" : dw.applianceName,
                                icon: "dishwasher",
                                status: "Ready to Start",
                                color: .green,
                                isActive: false,
                                progress: nil,
                                timeRemaining: nil
                            )
                        }
                        .buttonStyle(.plain)
                    } else {
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

                case .laundry(let app):
                    AppliancePill(
                        title: app.applianceName,
                        icon: app.typeIcon,
                        status: app.machineState.label,
                        color: app.isWasher ? .indigo : .purple,
                        isActive: app.machineState.isActive,
                        progress: nil,
                        timeRemaining: app.remainingTimeFormatted
                    )

                case .forYouEvening:
                    Button {
                        store.activateEveningScene()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "moon.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(Color.orange)
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
                                .fill(Color.orange.opacity(0.06))
                                .strokeBorder(Color.orange.opacity(0.15))
                        )
                    }
                    .buttonStyle(.plain)

                case .forYouDevice(let deviceId):
                    if let device = store.devices[deviceId] {
                        Button {
                            let newLevel: Double = device.level > 0 ? 0 : 100
                            store.setLevel(device.integrationId, level: newLevel, fadeTime: 1)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: device.category == .light ? "lightbulb.fill" : "blinds.vertical.open")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Color.orange)
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
                                    .fill(Color.orange.opacity(0.06))
                                    .strokeBorder(Color.orange.opacity(0.15))
                            )
                        }
                        .buttonStyle(.plain)
                    }

                case .alarmPanel(let panel):
                    AlarmPill(panel: panel, manager: totalConnect)

                case .thermostat(let thermo):
                    ThermostatPill(thermostat: thermo, manager: ecobee)

                case .sonosPlayer(let player):
                    SonosPill(player: player)

                case .staticAction(let title, let icon, let color, let actionId):
                    QuickActionButton(title: title, icon: icon, color: color) {
                        handleStaticAction(actionId)
                    }

                case .room(let name, let icon):
                    RoomControlCard(roomName: name, icon: icon, store: store)
                }
            }
        }
    }

    private func handleContextualAction(_ id: String) {
        switch id {
        case "morning":
            store.setRoomLights("Kitchen", level: 60)
            store.setRoomLights("Family Room", level: 40)
        case "shades_open":
            store.toggleMainShades()
        case "shades_close":
            store.toggleMainShades()
        case "all_off":
            store.turnOffAllLights(excludingNames: ["Bed 2 Entry"])
        case "evening":
            store.activateEveningScene()
        case "goodnight":
            store.turnOffAllLights(excludingNames: ["Bed 2 Entry"])
        default:
            break
        }
    }

    private func handleStaticAction(_ id: String) {
        switch id {
        case "main_floor_off":
            store.turnOffLights(on: .mainFloor)
        case "upstairs_off":
            store.turnOffLights(on: .upstairs)
        case "shades_toggle":
            store.toggleMainShades()
        default:
            break
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
                                .foregroundStyle(Color.orange)
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
                        .fill(Color.orange.opacity(0.06))
                        .strokeBorder(Color.orange.opacity(0.15))
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
                    .foregroundStyle(Color.secondary)

                Text("\(store.lightsOn.count)")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        store.lightsOn.isEmpty
                            ? Color(.systemGray5)
                            : Color.orange.opacity(0.2)
                    )
                    .foregroundColor(store.lightsOn.isEmpty ? .secondary : Color.orange)
                    .clipShape(Capsule())
            }

            if store.lightsOn.isEmpty {
                Text("All lights are off")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
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
                                    .background(Color.orange.opacity(0.15))
                                    .foregroundStyle(Color.orange)
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

// MARK: - Dishwasher Start Sheet

struct DishwasherStartSheet: View {
    @Environment(HomeConnectManager.self) var homeConnect
    let applianceId: String
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let programs = homeConnect.availablePrograms[applianceId], !programs.isEmpty {
                    Section("Select Program") {
                        ForEach(programs) { program in
                            Button {
                                Task {
                                    let success = await homeConnect.startProgram(program.key, for: applianceId)
                                    if success { dismiss() }
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "play.circle.fill")
                                        .foregroundStyle(.green)
                                    Text(program.name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                }
                            }
                            .disabled(homeConnect.isStarting)
                        }
                    }
                } else {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView("Loading programs…")
                            Spacer()
                        }
                    }
                }

                if let error = homeConnect.startError {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Start Dishwasher")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
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
    @State private var showDetail = false

    private var stateColor: Color {
        if manager.authFailed { return .secondary }
        switch panel.state {
        case .disarmed:              return .green
        case .armedAway, .armedHome, .armedNight: return .orange
        case .alarming:              return .red
        default:                     return .secondary
        }
    }

    private var faultedCount: Int {
        (manager.zones[panel.locationId] ?? []).filter { $0.faulted }.count
    }

    private var hasFault: Bool { faultedCount > 0 && !manager.authFailed }

    var body: some View {
        Button { showDetail = true } label: {
            HStack(spacing: 10) {
                Image(systemName: manager.authFailed ? "exclamationmark.shield" : panel.state.icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(stateColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Alarm")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(manager.authFailed ? "Sign-in required" : panel.state.label)
                        .font(.system(size: 11))
                        .foregroundStyle(manager.authFailed ? .red : .secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }

                Spacer(minLength: 6)

                if hasFault {
                    Text(faultedCount == 1 ? "1 fault" : "\(faultedCount) faults")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(Color.orange.opacity(0.15))
                        )
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(minHeight: 56)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(stateColor.opacity(panel.state == .alarming ? 0.6 : 0.2), lineWidth: panel.state == .alarming ? 1 : 0.5)
            )
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showDetail) {
            AlarmDetailView(panel: panel, manager: manager)
        }
    }
}

// MARK: - Alarm Detail Sheet

struct AlarmDetailView: View {
    let panel: AlarmPanel
    let manager: TotalConnectManager
    @Environment(\.dismiss) private var dismiss

    private var stateColor: Color {
        switch panel.state {
        case .disarmed:              return .green
        case .armedAway, .armedHome, .armedNight: return .orange
        case .alarming:              return .red
        default:                     return .secondary
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Big state header
                    VStack(spacing: 8) {
                        Image(systemName: panel.state.icon)
                            .font(.system(size: 44, weight: .medium))
                            .foregroundStyle(stateColor)
                            .symbolEffect(.pulse, isActive: panel.state.isTransitioning || panel.state == .alarming)
                        Text(panel.state.label)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(stateColor)
                        Text(panel.name)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal)

                    // Arm / Disarm buttons
                    VStack(spacing: 10) {
                        ArmActionButton(
                            title: "Disarm", icon: "lock.open.fill", color: .green,
                            isCurrent: panel.state == .disarmed,
                            isDisabled: panel.state == .disarmed || panel.state.isTransitioning
                        ) {
                            Task { await manager.disarm(panel) }
                        }
                        ArmActionButton(
                            title: "Arm Away", icon: "lock.fill", color: .orange,
                            isCurrent: panel.state == .armedAway,
                            isDisabled: panel.state == .armedAway || panel.state.isTransitioning
                        ) {
                            Task { await manager.armAway(panel) }
                        }
                        ArmActionButton(
                            title: "Arm Home", icon: "house.lock.fill", color: .orange,
                            isCurrent: panel.state == .armedHome,
                            isDisabled: panel.state == .armedHome || panel.state.isTransitioning
                        ) {
                            Task { await manager.armHome(panel) }
                        }
                        ArmActionButton(
                            title: "Arm Night", icon: "moon.fill", color: .indigo,
                            isCurrent: panel.state == .armedNight,
                            isDisabled: panel.state == .armedNight || panel.state.isTransitioning
                        ) {
                            Task { await manager.armNight(panel) }
                        }
                    }
                    .padding(.horizontal)

                    if let error = manager.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Alarm")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct ArmActionButton: View {
    let title: String
    let icon: String
    let color: Color
    let isCurrent: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isCurrent ? .white : color)
                    .frame(width: 28)
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isCurrent ? .white : .primary)
                Spacer()
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isCurrent ? AnyShapeStyle(color) : AnyShapeStyle(.ultraThinMaterial))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(color.opacity(isCurrent ? 0 : 0.25), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled && !isCurrent ? 0.5 : 1)
    }
}

private struct AlarmZoneRow: View {
    let zone: AlarmZone

    private var statusColor: Color {
        if zone.faulted { return .orange }
        if zone.lowBattery { return .red }
        if zone.bypassed { return .yellow }
        return .green
    }

    private var statusLabel: String {
        var parts: [String] = []
        if zone.faulted { parts.append("Open") }
        if zone.bypassed { parts.append("Bypassed") }
        if zone.lowBattery { parts.append("Low Battery") }
        if parts.isEmpty { parts.append("Closed") }
        return parts.joined(separator: " • ")
    }

    private var statusIcon: String {
        if zone.faulted { return "exclamationmark.circle.fill" }
        if zone.lowBattery { return "battery.25" }
        if zone.bypassed { return "minus.circle.fill" }
        return "checkmark.circle.fill"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: statusIcon)
                .font(.system(size: 16))
                .foregroundStyle(statusColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(zone.name)
                    .font(.system(size: 14, weight: .medium))
                Text(statusLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Thermostat Pill

struct ThermostatPill: View {
    let thermostat: EcobeeThermostat
    let manager: EcobeeManager
    @State private var showDetail = false

    private var modeColor: Color {
        switch thermostat.hvacMode {
        case .heat: return .orange
        case .cool:               return .cyan
        case .auto:               return .green
        case .off:                return .secondary
        }
    }

    var body: some View {
        Button { showDetail = true } label: {
            HStack(spacing: 10) {
                Image(systemName: thermostat.hvacMode.icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(modeColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(thermostat.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text("\(Int(thermostat.currentTemp))\u{00B0}")
                            .font(.system(size: 14, weight: .bold))
                        Text(thermostat.hvacMode.label)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 6)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(minHeight: 56)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(modeColor.opacity(0.15), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showDetail) {
            ThermostatDetailView(thermostat: thermostat, manager: manager)
        }
    }
}

// MARK: - Sonos Pill

struct SonosPill: View {
    let player: SonosPlayer
    @Environment(SonosManager.self) var sonos
    @State private var showDetail = false

    var body: some View {
        Button { showDetail = true } label: {
            HStack(spacing: 10) {
                Image(systemName: player.state == .playing ? "speaker.wave.2.fill" : "speaker.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text(player.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    if let track = player.currentTrack {
                        HStack(spacing: 4) {
                            Text(track.title)
                                .font(.system(size: 11))
                                .lineLimit(1)
                            if !track.artist.isEmpty {
                                Text("·")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                Text(track.artist)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    } else {
                        Text("Not Playing")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 6)

                // Inline play/pause button
                Button {
                    Task {
                        if player.state == .playing {
                            try? await sonos.pausePlayback(playerId: player.id)
                        } else {
                            try? await sonos.play(playerId: player.id)
                        }
                    }
                } label: {
                    Image(systemName: player.state == .playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .frame(width: 28, height: 28)
                        .background(Color.orange.opacity(0.15), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            .frame(minHeight: 56)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.orange.opacity(0.15), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showDetail) {
            SonosDetailView(player: player)
        }
    }
}

// MARK: - Thermostat Detail Sheet

struct ThermostatDetailView: View {
    let thermostat: EcobeeThermostat
    let manager: EcobeeManager
    @Environment(\.dismiss) private var dismiss
    @State private var heatTarget: Double
    @State private var coolTarget: Double

    init(thermostat: EcobeeThermostat, manager: EcobeeManager) {
        self.thermostat = thermostat
        self.manager = manager
        self._heatTarget = State(initialValue: thermostat.desiredHeat)
        self._coolTarget = State(initialValue: thermostat.desiredCool)
    }

    private var modeColor: Color {
        switch thermostat.hvacMode {
        case .heat: return .orange
        case .cool:               return .cyan
        case .auto:               return .green
        case .off:                return .secondary
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Big temp header
                    VStack(spacing: 8) {
                        Image(systemName: thermostat.hvacMode.icon)
                            .font(.system(size: 44, weight: .medium))
                            .foregroundStyle(modeColor)
                        Text("\(Int(thermostat.currentTemp))\u{00B0}F")
                            .font(.system(size: 44, weight: .bold))
                        Text(thermostat.displayName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            if let humidity = thermostat.humidity {
                                Label("\(humidity)%", systemImage: "humidity")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(thermostat.hvacMode.label)
                                .font(.caption)
                                .foregroundStyle(modeColor)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal)

                    // Setpoint controls
                    if thermostat.hvacMode != .off {
                        VStack(spacing: 12) {
                            if thermostat.hvacMode == .heat || thermostat.hvacMode == .auto {
                                HStack {
                                    Image(systemName: "flame.fill")
                                        .foregroundStyle(.orange)
                                    Text("Heat to")
                                    Spacer()
                                    Button { heatTarget -= 1 } label: {
                                        Image(systemName: "minus.circle.fill")
                                            .font(.title2)
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    Text("\(Int(heatTarget))\u{00B0}")
                                        .font(.title3.weight(.semibold))
                                        .frame(width: 44)
                                    Button { heatTarget += 1 } label: {
                                        Image(systemName: "plus.circle.fill")
                                            .font(.title2)
                                            .foregroundStyle(.orange)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            if thermostat.hvacMode == .cool || thermostat.hvacMode == .auto {
                                HStack {
                                    Image(systemName: "snowflake")
                                        .foregroundStyle(.cyan)
                                    Text("Cool to")
                                    Spacer()
                                    Button { coolTarget -= 1 } label: {
                                        Image(systemName: "minus.circle.fill")
                                            .font(.title2)
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    Text("\(Int(coolTarget))\u{00B0}")
                                        .font(.title3.weight(.semibold))
                                        .frame(width: 44)
                                    Button { coolTarget += 1 } label: {
                                        Image(systemName: "plus.circle.fill")
                                            .font(.title2)
                                            .foregroundStyle(.cyan)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            if heatTarget != thermostat.desiredHeat || coolTarget != thermostat.desiredCool {
                                Button {
                                    Task {
                                        if thermostat.hvacMode == .auto {
                                            try? await manager.setHeatCoolTargets(
                                                thermostatId: thermostat.identifier,
                                                heat: heatTarget,
                                                cool: coolTarget
                                            )
                                        } else {
                                            let target = thermostat.hvacMode == .heat ? heatTarget : coolTarget
                                            try? await manager.setTargetTemp(
                                                thermostatId: thermostat.identifier,
                                                temp: target
                                            )
                                        }
                                    }
                                } label: {
                                    Text("Set Temperature")
                                        .font(.body.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(modeColor, in: RoundedRectangle(cornerRadius: 10))
                                        .foregroundStyle(.white)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }

                    // Mode picker
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Mode")
                            .font(.caption.weight(.semibold))
                            .textCase(.uppercase)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            ForEach([HvacMode.heat, .cool, .auto, .off], id: \.rawValue) { mode in
                                Button {
                                    Task { try? await manager.setMode(thermostatId: thermostat.identifier, mode: mode) }
                                } label: {
                                    VStack(spacing: 4) {
                                        Image(systemName: mode.icon)
                                            .font(.system(size: 16))
                                        Text(mode.label)
                                            .font(.caption2)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(
                                        thermostat.hvacMode == mode
                                            ? AnyShapeStyle(modeColor.opacity(0.2))
                                            : AnyShapeStyle(.ultraThinMaterial)
                                    , in: RoundedRectangle(cornerRadius: 10))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(thermostat.hvacMode == mode ? modeColor.opacity(0.5) : Color.clear, lineWidth: 1)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal)

                    // Sensors
                    let thermoSensors = manager.sensors.filter { $0.parentThermostatId == thermostat.identifier }
                    if !thermoSensors.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Sensors")
                                .font(.caption.weight(.semibold))
                                .textCase(.uppercase)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal)

                            VStack(spacing: 0) {
                                ForEach(thermoSensors) { sensor in
                                    HStack(spacing: 12) {
                                        Image(systemName: sensor.occupancy ? "person.fill" : "person")
                                            .font(.system(size: 14))
                                            .foregroundStyle(sensor.occupancy ? .green : .secondary)
                                            .frame(width: 22)
                                        Text(sensor.name)
                                            .font(.system(size: 14, weight: .medium))
                                        Spacer()
                                        if let temp = sensor.temp {
                                            Text("\(Int(temp))\u{00B0}F")
                                                .font(.system(size: 14, weight: .semibold))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                }
                            }
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .padding(.horizontal)
                    }

                    if let error = manager.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Thermostat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
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
                .stroke(isActive ? Color.orange.opacity(0.2) : Color(.separator).opacity(0.5), lineWidth: 0.5)
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
                    .stroke(Color.orange.opacity(0.3), lineWidth: 0.5)

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
                    .stroke(accentColor.opacity(isOn ? 0.3 : 0.15), lineWidth: 0.5)

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

    private var accentColor: Color { EditorialTheme.accent }

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
                        Text(name.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.8)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .foregroundStyle(EditorialTheme.primaryText)
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
            .padding(10)
            .background(EditorialTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: EditorialTheme.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: EditorialTheme.cardRadius)
                    .stroke(hasActiveDevice ? EditorialTheme.accent.opacity(0.3) : EditorialTheme.cardBorder, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
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
                    accentColor: EditorialTheme.accent, leftIcon: "power", rightIcon: "lightbulb.max.fill")
        case .shadesAndDrapes:
            DimPill(devices: [device], displayName: displayName,
                    accentColor: EditorialTheme.accent, leftIcon: "blinds.vertical.closed", rightIcon: "blinds.vertical.open")
        default:
            HStack(spacing: 6) {
                Image(systemName: deviceIcon)
                    .font(.system(size: 9))
                    .foregroundStyle(device.isOn ? EditorialTheme.accent : EditorialTheme.secondaryText)
                    .frame(width: 14)

                Text(displayName)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(device.isOn ? EditorialTheme.primaryText : EditorialTheme.secondaryText)

                Spacer()

                Button {
                    store.setLevel(device.integrationId, level: device.isOn ? 0 : 100, fadeTime: 1)
                } label: {
                    Circle()
                        .fill(device.isOn ? EditorialTheme.accent : EditorialTheme.cardBackground)
                        .frame(width: 20, height: 20)
                        .overlay(
                            Image(systemName: "power")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(device.isOn ? .white : EditorialTheme.secondaryText)
                        )
                        .overlay(
                            Circle().stroke(EditorialTheme.cardBorder, lineWidth: 0.5)
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
}

// MARK: - Grouped Device Toggle Row (controls multiple devices as one)

struct GroupedDeviceToggleRow: View {
    @Environment(LutronStore.self) var store
    let label: String
    let devices: [DeviceState]

    private var isOn: Bool { devices.contains { $0.isOn } }
    private var isLightGroup: Bool { devices.first?.category == .light }
    private var isShadeGroup: Bool { devices.first?.category == .shadesAndDrapes }

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

    var body: some View {
        if isLightGroup {
            DimPill(devices: devices, displayName: label,
                    accentColor: EditorialTheme.accent, leftIcon: "power", rightIcon: "lightbulb.max.fill")
        } else if isShadeGroup {
            DimPill(devices: devices, displayName: label,
                    accentColor: EditorialTheme.accent, leftIcon: "blinds.vertical.closed", rightIcon: "blinds.vertical.open")
        } else {
            HStack(spacing: 6) {
                Image(systemName: deviceIcon)
                    .font(.system(size: 9))
                    .foregroundStyle(isOn ? EditorialTheme.accent : EditorialTheme.secondaryText)
                    .frame(width: 14)

                Text(label)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(isOn ? EditorialTheme.primaryText : EditorialTheme.secondaryText)

                Spacer()

                Button {
                    let newLevel: Double = isOn ? 0 : 100
                    for device in devices {
                        store.setLevel(device.integrationId, level: newLevel, fadeTime: 1)
                    }
                } label: {
                    Circle()
                        .fill(isOn ? EditorialTheme.accent : EditorialTheme.cardBackground)
                        .frame(width: 20, height: 20)
                        .overlay(
                            Image(systemName: "power")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(isOn ? .white : EditorialTheme.secondaryText)
                        )
                        .overlay(
                            Circle().stroke(EditorialTheme.cardBorder, lineWidth: 0.5)
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
                        accentColor: EditorialTheme.accent, leftIcon: "power", rightIcon: "lightbulb.max.fill")
            }
        } else if device.category == .shadesAndDrapes {
            HStack(spacing: 6) {
                Text(roomIcon).font(.system(size: 14))
                DimPill(devices: [device], displayName: roomName,
                        accentColor: EditorialTheme.accent, leftIcon: "blinds.vertical.closed", rightIcon: "blinds.vertical.open")
            }
        } else {
            HStack(spacing: 6) {
                Text(roomIcon)
                    .font(.system(size: 14))
                Text(roomName.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(EditorialTheme.primaryText)

                Spacer()

                Button {
                    let newLevel: Double = device.isOn ? 0 : 100
                    store.setLevel(device.integrationId, level: newLevel, fadeTime: 1)
                } label: {
                    Circle()
                        .fill(device.isOn ? EditorialTheme.accent : EditorialTheme.cardBackground)
                        .frame(width: 24, height: 24)
                        .overlay(
                            Image(systemName: "power")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(device.isOn ? .white : EditorialTheme.secondaryText)
                        )
                        .overlay(
                            Circle().stroke(EditorialTheme.cardBorder, lineWidth: 0.5)
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
                    .stroke(position == .open ? Color.orange.opacity(0.3) : Color(.separator).opacity(0.5), lineWidth: 0.5)
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
                .stroke(tint.opacity(0.2), lineWidth: 0.5)
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
                .stroke(status.operationState.isActive ? Color.cyan.opacity(0.3) : Color(.separator).opacity(0.5), lineWidth: 0.5)
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
                    .stroke(Color(.separator).opacity(0.5), lineWidth: 0.5)
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
