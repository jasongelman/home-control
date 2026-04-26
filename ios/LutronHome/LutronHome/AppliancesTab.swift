import SwiftUI

// MARK: - Appliances Tab

struct AppliancesTab: View {
    @Environment(HomeConnectManager.self) var homeConnect
    @Environment(MyUplinkManager.self) var myUplink
    @Environment(SmartHQManager.self) var smartHQ
    @Environment(MyQManager.self) var myQ

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: EditorialTheme.sectionSpacing) {
                    // Tab header
                    HStack(alignment: .firstTextBaseline) {
                        Text("APPLIANCES")
                            .font(EditorialTheme.bebasNeue(size: 32))
                            .foregroundStyle(EditorialTheme.primaryText)
                        Spacer()
                    }

                    // Garage Doors (MyQ)
                    if myQ.isLinked && !myQ.doors.isEmpty {
                        garageSection
                    }

                    // Dishwashers (Bosch Home Connect)
                    if homeConnect.isLinked && !homeConnect.dishwashers.isEmpty {
                        dishwasherSection
                    }

                    // Laundry (GE SmartHQ)
                    if smartHQ.isLinked && !smartHQ.appliances.isEmpty {
                        laundrySection
                    }

                    // Heat Pump (myUplink)
                    if myUplink.isLinked {
                        climateSection
                    }

                    // Empty state
                    if !myQ.isLinked && !homeConnect.isLinked && !smartHQ.isLinked && !myUplink.isLinked {
                        emptyState
                    }
                }
                .padding(.horizontal)
                .padding(.top, 12)
            }
            .refreshable {
                async let garage: () = myQ.fetchDevices()
                async let dw: () = homeConnect.fetchAllStatuses()
                async let ge: () = smartHQ.fetchAllStatuses()
                async let hp: () = myUplink.fetchDataPoints()
                _ = await (garage, dw, ge, hp)
            }
            .background(EditorialTheme.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    // MARK: - Garage Doors

    private var garageSection: some View {
        VStack(alignment: .leading, spacing: EditorialTheme.gridSpacing) {
            EditorialSectionHeader(title: "Garage", trailing: "\(myQ.doors.count)")
            ForEach(myQ.doors) { door in
                GarageRow(door: door)
            }
        }
    }

    // MARK: - Dishwashers

    private var dishwasherSection: some View {
        VStack(alignment: .leading, spacing: EditorialTheme.gridSpacing) {
            EditorialSectionHeader(title: "Dishwashers", trailing: "\(homeConnect.dishwashers.count)")

            ForEach(homeConnect.dishwashers) { dw in
                NavigationLink(destination: DishwasherDetailView(dishwasherId: dw.applianceId)) {
                    DishwasherRow(status: dw)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Laundry

    private var laundrySection: some View {
        VStack(alignment: .leading, spacing: EditorialTheme.gridSpacing) {
            EditorialSectionHeader(title: "Laundry", trailing: "\(smartHQ.appliances.count)")

            ForEach(smartHQ.appliances) { appliance in
                NavigationLink(destination: LaundryDetailView(applianceId: appliance.applianceId)) {
                    LaundryRow(status: appliance)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Climate

    private var climateSection: some View {
        VStack(alignment: .leading, spacing: EditorialTheme.gridSpacing) {
            EditorialSectionHeader(title: "Climate")

            NavigationLink(destination: HeatPumpDetailView()) {
                HeatPumpRow()
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        HStack(spacing: 8) {
            Image(systemName: "washer")
                .font(.system(size: 14))
                .foregroundStyle(EditorialTheme.secondaryText)
            Text("No appliances linked — connect in Settings")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(EditorialTheme.secondaryText)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Dishwasher Row (for Appliances tab list)

struct DishwasherRow: View {
    let status: DishwasherStatus

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: status.operationState.icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(status.operationState.isActive ? EditorialTheme.accent : EditorialTheme.secondaryText)
                .symbolEffect(.pulse, isActive: status.operationState == .run)
                .frame(width: 32)

            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text((status.applianceName.isEmpty ? "Dishwasher" : status.applianceName).uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(EditorialTheme.primaryText)

                HStack(spacing: 4) {
                    Text(status.operationState.label.uppercased())
                        .font(.system(size: 9, weight: .medium))
                        .tracking(0.4)
                        .foregroundStyle(status.operationState.isActive ? EditorialTheme.accent : EditorialTheme.secondaryText)

                    if let program = status.programDisplayName {
                        Text("· \(program)")
                            .font(.system(size: 9))
                            .foregroundStyle(EditorialTheme.secondaryText)
                    }
                }
            }

            Spacer()

            // Right side
            if status.operationState.isActive {
                VStack(alignment: .trailing, spacing: 2) {
                    if let progress = status.progress {
                        Text("\(progress)%")
                            .font(EditorialTheme.monoValue(size: 14))
                            .foregroundStyle(EditorialTheme.accent)
                    }
                    if let time = status.remainingTimeFormatted {
                        Text(time)
                            .font(EditorialTheme.monoValue(size: 10, weight: .medium))
                            .foregroundStyle(EditorialTheme.secondaryText)
                    }
                }
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(EditorialTheme.tertiaryText)
            }
        }
        .padding(12)
        .background(EditorialTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: EditorialTheme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: EditorialTheme.cardRadius)
                .stroke(status.operationState.isActive ? EditorialTheme.accent.opacity(0.3) : EditorialTheme.cardBorder, lineWidth: 0.5)
        )
    }
}

// MARK: - Laundry Row (for Appliances tab list)

struct LaundryRow: View {
    let status: LaundryApplianceStatus

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: status.typeIcon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(status.machineState.isActive ? EditorialTheme.accent : EditorialTheme.secondaryText)
                .symbolEffect(.pulse, isActive: status.machineState.isRunning)
                .frame(width: 32)

            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(status.applianceName.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(EditorialTheme.primaryText)

                HStack(spacing: 4) {
                    Text(status.machineState.label.uppercased())
                        .font(.system(size: 9, weight: .medium))
                        .tracking(0.4)
                        .foregroundStyle(status.machineState.isActive ? EditorialTheme.accent : EditorialTheme.secondaryText)

                    if let cycle = status.cycleName {
                        Text("· \(cycle)")
                            .font(.system(size: 9))
                            .foregroundStyle(EditorialTheme.secondaryText)
                    }
                }
            }

            Spacer()

            // Right side
            if status.machineState.isActive {
                if let time = status.remainingTimeFormatted {
                    Text(time)
                        .font(EditorialTheme.monoValue(size: 14))
                        .foregroundStyle(EditorialTheme.accent)
                }
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(EditorialTheme.tertiaryText)
            }
        }
        .padding(12)
        .background(EditorialTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: EditorialTheme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: EditorialTheme.cardRadius)
                .stroke(status.machineState.isActive ? EditorialTheme.accent.opacity(0.3) : EditorialTheme.cardBorder, lineWidth: 0.5)
        )
    }
}

// MARK: - Heat Pump Row (for Appliances tab list)

struct HeatPumpRow: View {
    @Environment(MyUplinkManager.self) var myUplink

    private var status: HeatPumpStatus { myUplink.heatPump }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: modeIcon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(EditorialTheme.accent)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text((status.systemName.isEmpty ? "Geothermal" : status.systemName).uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(EditorialTheme.primaryText)

                HStack(spacing: 4) {
                    if let mode = status.operatingMode {
                        Text(mode.uppercased())
                            .font(.system(size: 9, weight: .medium))
                            .tracking(0.4)
                            .foregroundStyle(EditorialTheme.accent)
                    }
                    if let outdoor = status.outdoorTemp {
                        Text(String(format: "%.0f°F OUTSIDE", outdoor))
                            .font(.system(size: 9, weight: .medium))
                            .tracking(0.4)
                            .foregroundStyle(EditorialTheme.secondaryText)
                    }
                }
            }

            Spacer()

            HStack(spacing: 8) {
                if let power = status.currentPower {
                    Text(String(format: "%.1f kW", power))
                        .font(EditorialTheme.monoValue(size: 12))
                        .foregroundStyle(EditorialTheme.accent)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(EditorialTheme.tertiaryText)
            }
        }
        .padding(12)
        .background(EditorialTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: EditorialTheme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: EditorialTheme.cardRadius)
                .stroke(EditorialTheme.cardBorder, lineWidth: 0.5)
        )
    }

    private var modeIcon: String {
        let mode = (status.operatingMode ?? "").lowercased()
        if mode.contains("heat") { return "flame.fill" }
        if mode.contains("cool") { return "snowflake" }
        if mode.contains("hot water") || mode.contains("dhw") { return "drop.fill" }
        return "leaf.fill"
    }
}

// MARK: - Garage Row

struct GarageRow: View {
    @Environment(MyQManager.self) var myQ
    let door: MyQDoor

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: door.state.icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(door.state == .open ? EditorialTheme.accent : EditorialTheme.secondaryText)
                .symbolEffect(.pulse, isActive: door.state.isMoving)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(door.name.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(EditorialTheme.primaryText)

                Text(door.state.label.uppercased())
                    .font(.system(size: 9, weight: .medium))
                    .tracking(0.4)
                    .foregroundStyle(door.state == .open ? EditorialTheme.accent : EditorialTheme.secondaryText)
            }

            Spacer()

            if door.online && !door.state.isMoving {
                Button {
                    Task {
                        if door.state == .closed {
                            await myQ.openDoor(door)
                        } else if door.state == .open {
                            await myQ.closeDoor(door)
                        }
                    }
                } label: {
                    Text((door.state == .closed ? "OPEN" : door.state == .open ? "CLOSE" : "").uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.8)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(EditorialTheme.accent.opacity(0.1))
                        .foregroundStyle(EditorialTheme.accent)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(EditorialTheme.accent.opacity(0.3), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .opacity((door.state == .open || door.state == .closed) ? 1 : 0)
            } else if door.state.isMoving {
                ProgressView()
                    .scaleEffect(0.8)
            }
        }
        .padding(12)
        .background(EditorialTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: EditorialTheme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: EditorialTheme.cardRadius)
                .stroke(door.state == .open ? EditorialTheme.accent.opacity(0.3) : EditorialTheme.cardBorder, lineWidth: 0.5)
        )
    }
}

// MARK: - Circular Progress View

struct CircularProgressView: View {
    let progress: Double
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.15), lineWidth: 3)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(progress * 100))")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
        }
    }
}

// MARK: - Dishwasher Detail View

struct DishwasherDetailView: View {
    @Environment(HomeConnectManager.self) var homeConnect
    let dishwasherId: String
    @State private var showStartSheet = false

    private var status: DishwasherStatus? {
        homeConnect.dishwashers.first(where: { $0.applianceId == dishwasherId })
    }

    var body: some View {
        if let dw = status {
            List {
                // Status hero
                Section {
                    VStack(spacing: 16) {
                        Image(systemName: dw.operationState.icon)
                            .font(.system(size: 52, weight: .medium))
                            .foregroundStyle(statusColor(dw))
                            .symbolEffect(.pulse, isActive: dw.operationState == .run)

                        Text(dw.applianceName.isEmpty ? "Dishwasher" : dw.applianceName)
                            .font(.title2)
                            .fontWeight(.bold)

                        Text(dw.operationState.label)
                            .font(.headline)
                            .foregroundStyle(statusColor(dw))

                        // Progress
                        if dw.operationState.isActive {
                            VStack(spacing: 8) {
                                if let progress = dw.progress {
                                    ProgressView(value: Double(progress), total: 100)
                                        .tint(statusColor(dw))
                                        .scaleEffect(y: 2)
                                    Text("\(progress)% complete")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                if let time = dw.remainingTimeFormatted {
                                    HStack(spacing: 4) {
                                        Image(systemName: "clock")
                                            .font(.subheadline)
                                        Text("\(time) remaining")
                                            .font(.subheadline)
                                    }
                                    .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.top, 4)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowBackground(Color.clear)
                }

                // Details
                Section("Details") {
                    LabeledContent("Status", value: dw.operationState.label)
                    LabeledContent("Door", value: dw.doorState.label)
                    LabeledContent("Remote Control", value: dw.remoteControlActive ? "Active" : "Inactive")
                    if let program = dw.programDisplayName {
                        LabeledContent("Program", value: program)
                    }
                    LabeledContent("Connected", value: dw.connected ? "Yes" : "No")
                }

                // Program info (when active)
                if dw.operationState.isActive {
                    Section("Active Cycle") {
                        if let program = dw.programDisplayName {
                            LabeledContent("Program", value: program)
                        }
                        if let progress = dw.progress {
                            LabeledContent("Progress", value: "\(progress)%")
                        }
                        if let time = dw.remainingTimeFormatted {
                            LabeledContent("Time Remaining", value: time)
                        }
                    }
                }

                // Remote start (when preconditions met)
                if dw.canRemoteStart {
                    Section {
                        Button {
                            showStartSheet = true
                            Task { await homeConnect.fetchAvailablePrograms(for: dw.applianceId) }
                        } label: {
                            Label("Start Dishwasher", systemImage: "play.circle.fill")
                                .foregroundStyle(.green)
                                .font(.headline)
                        }
                    }
                }
            }
            .navigationTitle(dw.applianceName.isEmpty ? "Dishwasher" : dw.applianceName)
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                if let idx = homeConnect.dishwashers.firstIndex(where: { $0.applianceId == dishwasherId }) {
                    await homeConnect.fetchStatus(for: idx)
                }
            }
            .sheet(isPresented: $showStartSheet) {
                DishwasherStartSheet(applianceId: dw.applianceId)
            }
        } else {
            ContentUnavailableView("Dishwasher Not Found", systemImage: "dishwasher", description: Text("This appliance is no longer available."))
        }
    }

    private func statusColor(_ dw: DishwasherStatus) -> Color {
        switch dw.operationState {
        case .run: return .cyan
        case .finished: return .green
        case .error, .actionRequired: return .red
        case .ready: return .green
        case .delayedStart, .pause: return .orange
        default: return .secondary
        }
    }
}

// MARK: - Laundry Detail View

struct LaundryDetailView: View {
    @Environment(SmartHQManager.self) var smartHQ
    let applianceId: String

    private var status: LaundryApplianceStatus? {
        smartHQ.appliances.first(where: { $0.applianceId == applianceId })
    }

    var body: some View {
        if let app = status {
            List {
                // Status hero
                Section {
                    VStack(spacing: 16) {
                        Image(systemName: app.typeIcon)
                            .font(.system(size: 52, weight: .medium))
                            .foregroundStyle(statusColor(app))
                            .symbolEffect(.pulse, isActive: app.machineState.isRunning)

                        Text(app.applianceName)
                            .font(.title2)
                            .fontWeight(.bold)

                        Text(app.machineState.label)
                            .font(.headline)
                            .foregroundStyle(statusColor(app))

                        // Time remaining
                        if app.machineState.isActive {
                            VStack(spacing: 8) {
                                if let time = app.remainingTimeFormatted {
                                    HStack(spacing: 4) {
                                        Image(systemName: "clock")
                                            .font(.subheadline)
                                        Text("\(time) remaining")
                                            .font(.subheadline)
                                    }
                                    .foregroundStyle(.secondary)
                                }
                                if let cycle = app.cycleName {
                                    Text(cycle)
                                        .font(.subheadline)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.top, 4)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowBackground(Color.clear)
                }

                // Machine status
                Section("Status") {
                    LabeledContent("State", value: app.machineState.label)
                    if let cycle = app.cycleName {
                        LabeledContent("Cycle", value: cycle)
                    }
                    if let time = app.remainingTimeFormatted {
                        LabeledContent("Time Remaining", value: time)
                    }
                    LabeledContent("Door", value: app.doorLocked ? "Locked" : "Unlocked")
                    LabeledContent("Online", value: app.online ? "Yes" : "No")
                }

                // Washer-specific settings
                if app.isWasher {
                    Section("Wash Settings") {
                        if let soil = app.soilLevel {
                            LabeledContent("Soil Level", value: soil)
                        }
                        if let temp = app.washTemp {
                            LabeledContent("Temperature", value: temp)
                        }
                        if let spin = app.spinSpeed {
                            LabeledContent("Spin Speed", value: spin)
                        }
                    }
                }

                // Dryer-specific settings
                if app.isDryer {
                    Section("Dry Settings") {
                        if let level = app.dryLevel {
                            LabeledContent("Dry Level", value: level)
                        }
                        if let temp = app.dryTemp {
                            LabeledContent("Temperature", value: temp)
                        }
                    }
                }
            }
            .navigationTitle(app.applianceName)
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                if let idx = smartHQ.appliances.firstIndex(where: { $0.applianceId == applianceId }) {
                    await smartHQ.fetchERD(for: idx)
                }
            }
        } else {
            ContentUnavailableView("Appliance Not Found", systemImage: "washer", description: Text("This appliance is no longer available."))
        }
    }

    private func statusColor(_ app: LaundryApplianceStatus) -> Color {
        if app.isWasher {
            switch app.machineState {
            case .run: return .indigo
            case .endOfCycle: return .green
            case .pause, .delayRun, .delayPause, .dsmDelayRun: return .orange
            case .drainTimeout: return .red
            default: return .secondary
            }
        } else {
            switch app.machineState {
            case .run: return .purple
            case .endOfCycle: return .green
            case .pause, .delayRun, .delayPause, .dsmDelayRun: return .orange
            case .drainTimeout: return .red
            default: return .secondary
            }
        }
    }
}
