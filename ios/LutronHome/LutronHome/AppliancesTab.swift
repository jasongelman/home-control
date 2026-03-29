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
                VStack(alignment: .leading, spacing: 24) {
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
            .background(Color(.systemBackground))
            .navigationTitle("Appliances")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    // MARK: - Garage Doors

    private var garageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(icon: "door.garage.closed", color: .brown, title: "Garage")
            ForEach(myQ.doors) { door in
                GarageRow(door: door)
            }
        }
    }

    // MARK: - Dishwashers

    private var dishwasherSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(icon: "dishwasher", color: .cyan, title: "Dishwashers")

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
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(icon: "washer", color: .indigo, title: "Laundry")

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
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(icon: "leaf.fill", color: .green, title: "Climate")

            NavigationLink(destination: HeatPumpDetailView()) {
                HeatPumpRow()
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Helpers

    private func sectionHeader(icon: String, color: Color, title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 60)
            Image(systemName: "washer")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No Appliances Linked")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Connect your Bosch, GE, or NIBE appliances in Settings to see them here.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Dishwasher Row (for Appliances tab list)

struct DishwasherRow: View {
    let status: DishwasherStatus

    var body: some View {
        HStack(spacing: 14) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(statusColor.opacity(0.12))
                    .frame(width: 48, height: 48)
                Image(systemName: status.operationState.icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(statusColor)
                    .symbolEffect(.pulse, isActive: status.operationState == .run)
            }

            // Info
            VStack(alignment: .leading, spacing: 3) {
                Text(status.applianceName.isEmpty ? "Dishwasher" : status.applianceName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)

                HStack(spacing: 6) {
                    Text(status.operationState.label)
                        .font(.system(size: 13))
                        .foregroundStyle(statusColor)

                    if let program = status.programDisplayName {
                        Text("- \(program)")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            // Right side: progress or time
            if status.operationState.isActive {
                VStack(alignment: .trailing, spacing: 4) {
                    if let progress = status.progress {
                        CircularProgressView(progress: Double(progress) / 100, color: statusColor)
                            .frame(width: 32, height: 32)
                    }
                    if let time = status.remainingTimeFormatted {
                        Text(time)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(status.operationState.isActive ? statusColor.opacity(0.3) : Color(.separator).opacity(0.3), lineWidth: 1)
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
        if status.operationState.isActive {
            LinearGradient(
                colors: [statusColor.opacity(0.06), Color(.secondarySystemBackground)],
                startPoint: .leading,
                endPoint: .trailing
            )
        } else {
            Color(.secondarySystemBackground)
        }
    }
}

// MARK: - Laundry Row (for Appliances tab list)

struct LaundryRow: View {
    let status: LaundryApplianceStatus

    var body: some View {
        HStack(spacing: 14) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(statusColor.opacity(0.12))
                    .frame(width: 48, height: 48)
                Image(systemName: status.typeIcon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(statusColor)
                    .symbolEffect(.pulse, isActive: status.machineState.isRunning)
            }

            // Info
            VStack(alignment: .leading, spacing: 3) {
                Text(status.applianceName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)

                HStack(spacing: 6) {
                    Text(status.machineState.label)
                        .font(.system(size: 13))
                        .foregroundStyle(statusColor)

                    if let cycle = status.cycleName {
                        Text("- \(cycle)")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            // Right side: time remaining
            if status.machineState.isActive {
                VStack(alignment: .trailing, spacing: 4) {
                    Image(systemName: status.machineState.icon)
                        .font(.system(size: 18))
                        .foregroundStyle(statusColor)
                    if let time = status.remainingTimeFormatted {
                        Text(time)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(status.machineState.isActive ? statusColor.opacity(0.3) : Color(.separator).opacity(0.3), lineWidth: 1)
        )
    }

    private var statusColor: Color {
        if status.isWasher {
            switch status.machineState {
            case .run: return .indigo
            case .endOfCycle: return .green
            case .pause, .delayRun, .delayPause, .dsmDelayRun: return .orange
            case .drainTimeout: return .red
            default: return .secondary
            }
        } else {
            switch status.machineState {
            case .run: return .purple
            case .endOfCycle: return .green
            case .pause, .delayRun, .delayPause, .dsmDelayRun: return .orange
            case .drainTimeout: return .red
            default: return .secondary
            }
        }
    }

    @ViewBuilder
    private var cardBackground: some View {
        if status.machineState.isActive {
            LinearGradient(
                colors: [statusColor.opacity(0.06), Color(.secondarySystemBackground)],
                startPoint: .leading,
                endPoint: .trailing
            )
        } else {
            Color(.secondarySystemBackground)
        }
    }
}

// MARK: - Heat Pump Row (for Appliances tab list)

struct HeatPumpRow: View {
    @Environment(MyUplinkManager.self) var myUplink

    private var status: HeatPumpStatus { myUplink.heatPump }

    var body: some View {
        HStack(spacing: 14) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(modeColor.opacity(0.12))
                    .frame(width: 48, height: 48)
                Image(systemName: modeIcon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(modeColor)
            }

            // Info
            VStack(alignment: .leading, spacing: 3) {
                Text(status.systemName.isEmpty ? "Geothermal" : status.systemName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)

                HStack(spacing: 6) {
                    if let mode = status.operatingMode {
                        Text(mode)
                            .font(.system(size: 13))
                            .foregroundStyle(modeColor)
                    }
                    if let outdoor = status.outdoorTemp {
                        Text(String(format: "%.0f°F outside", outdoor))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                if let power = status.currentPower {
                    HStack(spacing: 2) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 10))
                        Text(String(format: "%.1f kW", power))
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.yellow)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color(.separator).opacity(0.3), lineWidth: 1)
        )
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

// MARK: - Garage Row

struct GarageRow: View {
    @Environment(MyQManager.self) var myQ
    let door: MyQDoor

    private var statusColor: Color {
        switch door.state {
        case .open:            return .orange
        case .closed:          return .green
        case .opening, .closing, .transition: return .yellow
        case .stopped:         return .red
        case .unknown:         return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(statusColor.opacity(0.12))
                    .frame(width: 48, height: 48)
                Image(systemName: door.state.icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(statusColor)
                    .symbolEffect(.pulse, isActive: door.state.isMoving)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(door.name)
                    .font(.system(size: 15, weight: .semibold))
                Text(door.state.label)
                    .font(.system(size: 13))
                    .foregroundStyle(statusColor)
            }

            Spacer()

            // Open / Close button
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
                    Text(door.state == .closed ? "Open" : door.state == .open ? "Close" : "")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(statusColor.opacity(0.15))
                        )
                        .foregroundStyle(statusColor)
                }
                .buttonStyle(.plain)
                .opacity((door.state == .open || door.state == .closed) ? 1 : 0)
            } else if door.state.isMoving {
                ProgressView()
                    .scaleEffect(0.8)
            }
        }
        .padding(14)
        .background(
            door.state == .open
                ? LinearGradient(colors: [Color.orange.opacity(0.06), Color(.secondarySystemBackground)], startPoint: .leading, endPoint: .trailing)
                : LinearGradient(colors: [Color(.secondarySystemBackground), Color(.secondarySystemBackground)], startPoint: .leading, endPoint: .trailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(door.state == .open ? Color.orange.opacity(0.3) : Color(.separator).opacity(0.3), lineWidth: 1)
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
