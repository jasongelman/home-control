import SwiftUI

// MARK: - Appliances Tab

struct AppliancesTab: View {
    @Environment(HomeConnectManager.self) var homeConnect
    @Environment(MyUplinkManager.self) var myUplink
    @Environment(SmartHQManager.self) var smartHQ
    @Environment(MyQManager.self) var myQ
    @Environment(ChargePointManager.self) var chargePoint
    @Environment(SubZeroManager.self) var subZero

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

                    // EV Charging (ChargePoint)
                    if chargePoint.isLinked && !chargePoint.chargers.isEmpty {
                        evChargingSection
                    }

                    // Refrigerators (Sub-Zero)
                    if subZero.isLinked && !subZero.refrigerators.isEmpty {
                        refrigeratorSection
                    }

                    // Ovens (Wolf)
                    if subZero.isLinked && !subZero.ovens.isEmpty {
                        ovenSection
                    }

                    // Empty state
                    if !myQ.isLinked && !homeConnect.isLinked && !smartHQ.isLinked && !myUplink.isLinked && !chargePoint.isLinked && !subZero.isLinked {
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
                async let sz: () = subZero.fetchAppliances()
                _ = await (garage, dw, ge, hp, sz)
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

    // MARK: - EV Charging

    private var evChargingSection: some View {
        VStack(alignment: .leading, spacing: EditorialTheme.gridSpacing) {
            EditorialSectionHeader(title: "EV Charging", trailing: chargingSummary)

            ForEach(chargePoint.chargers) { charger in
                NavigationLink(destination: EVChargerDetailView(charger: charger)) {
                    ChargerRow(charger: charger)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var chargingSummary: String? {
        let active = chargePoint.chargers.filter { $0.status == .charging }.count
        if active > 0 { return "\(active) charging" }
        return "\(chargePoint.chargers.count)"
    }

    // MARK: - Refrigerators (Sub-Zero)

    private var refrigeratorSection: some View {
        VStack(alignment: .leading, spacing: EditorialTheme.gridSpacing) {
            EditorialSectionHeader(title: "Refrigerators", trailing: "\(subZero.refrigerators.count)")

            ForEach(subZero.refrigerators) { fridge in
                NavigationLink(destination: RefrigeratorDetailView(fridge: fridge)) {
                    RefrigeratorRow(fridge: fridge)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Ovens (Wolf)

    private var ovenSection: some View {
        VStack(alignment: .leading, spacing: EditorialTheme.gridSpacing) {
            EditorialSectionHeader(title: "Ovens", trailing: "\(subZero.ovens.count)")

            ForEach(subZero.ovens) { oven in
                NavigationLink(destination: WolfOvenDetailView(oven: oven)) {
                    WolfOvenRow(oven: oven)
                }
                .buttonStyle(.plain)
            }
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

// MARK: - Charger Row

struct ChargerRow: View {
    let charger: ChargePointCharger

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: charger.status.icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(statusColor)
                .symbolEffect(.pulse, isActive: charger.status == .charging)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(charger.nickname.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(EditorialTheme.primaryText)

                HStack(spacing: 4) {
                    Text(charger.status.label.uppercased())
                        .font(.system(size: 9, weight: .medium))
                        .tracking(0.4)
                        .foregroundStyle(charger.status.isActive ? EditorialTheme.accent : EditorialTheme.secondaryText)

                    if let kw = charger.powerKw, kw > 0 {
                        Text("· \(String(format: "%.1f kW", kw))")
                            .font(.system(size: 9))
                            .foregroundStyle(EditorialTheme.secondaryText)
                    }
                }
            }

            Spacer()

            if charger.status == .charging || charger.isPluggedIn {
                VStack(alignment: .trailing, spacing: 2) {
                    if let kwh = charger.energyKwh, kwh > 0 {
                        Text(String(format: "%.1f kWh", kwh))
                            .font(EditorialTheme.monoValue(size: 12))
                            .foregroundStyle(EditorialTheme.accent)
                    }
                    if charger.amperage > 0 {
                        Text("\(charger.amperage)A")
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
                .stroke(charger.status == .charging ? EditorialTheme.accent.opacity(0.3) : EditorialTheme.cardBorder, lineWidth: 0.5)
        )
    }

    private var statusColor: Color {
        switch charger.status {
        case .charging:  return .green
        case .pluggedIn: return .blue
        case .complete:  return .green
        case .error:     return .red
        default:         return EditorialTheme.secondaryText
        }
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

// MARK: - Refrigerator Row

struct RefrigeratorRow: View {
    let fridge: SubZeroRefrigerator

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "refrigerator.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(fridge.online ? EditorialTheme.accent : EditorialTheme.secondaryText)

                Text(fridge.applianceName.uppercased())
                    .font(.system(size: 9, weight: .medium))
                    .tracking(0.8)
                    .foregroundStyle(EditorialTheme.secondaryText)

                Spacer()

                if fridge.fridgeDoorOpen || fridge.freezerDoorOpen {
                    Text("DOOR OPEN")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(.orange)
                } else if !fridge.online {
                    Text("OFFLINE")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(EditorialTheme.secondaryText)
                }
            }

            HStack(spacing: 16) {
                if let temp = fridge.fridgeTemp {
                    statBlock(label: "FRIDGE", value: "\(Int(temp))°F")
                }
                if let temp = fridge.freezerTemp {
                    statBlock(label: "FREEZER", value: "\(Int(temp))°F")
                }
                if let pct = fridge.waterFilterPct {
                    statBlock(label: "FILTER", value: "\(Int(pct))%")
                }
                if fridge.iceMakerOn {
                    statBlock(label: "ICE", value: fridge.maxIceOn ? "MAX" : "ON")
                }
            }
        }
        .padding(12)
        .background(EditorialTheme.cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke((fridge.fridgeDoorOpen || fridge.freezerDoorOpen) ? Color.orange.opacity(0.3) : EditorialTheme.cardBorder, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func statBlock(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 7, weight: .medium))
                .tracking(0.5)
                .foregroundStyle(EditorialTheme.secondaryText)
            Text(value)
                .font(.system(size: 12, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(EditorialTheme.primaryText)
        }
    }
}

// MARK: - Refrigerator Detail View

struct RefrigeratorDetailView: View {
    let fridge: SubZeroRefrigerator
    @Environment(SubZeroManager.self) var subZero

    var body: some View {
        List {
            // Setpoints section (matching native app layout)
            Section {
                if let setpoint = fridge.fridgeSetpoint {
                    HStack {
                        Image(systemName: "thermometer.medium")
                            .foregroundStyle(.secondary)
                        Text("Refrigerator Setpoint")
                        Spacer()
                        Stepper("\(Int(setpoint))°", value: Binding(
                            get: { Int(setpoint) },
                            set: { newVal in Task { await subZero.setFridgeTemp(applianceId: fridge.applianceId, temp: newVal) } }
                        ), in: 33...45)
                        .labelsHidden()
                        Text("\(Int(setpoint))°")
                            .fontWeight(.semibold)
                    }
                }
                if let setpoint = fridge.crisperSetpoint {
                    HStack {
                        Image(systemName: "thermometer.medium")
                            .foregroundStyle(.secondary)
                        Text("Crisper Setpoint")
                        Spacer()
                        Stepper("\(Int(setpoint))°", value: Binding(
                            get: { Int(setpoint) },
                            set: { newVal in Task { await subZero.setCrisperTemp(applianceId: fridge.applianceId, temp: newVal) } }
                        ), in: 33...45)
                        .labelsHidden()
                        Text("\(Int(setpoint))°")
                            .fontWeight(.semibold)
                    }
                }
                if let setpoint = fridge.freezerSetpoint {
                    HStack {
                        Image(systemName: "thermometer.medium")
                            .foregroundStyle(.secondary)
                        Text("Freezer Setpoint")
                        Spacer()
                        Stepper("\(Int(setpoint))°", value: Binding(
                            get: { Int(setpoint) },
                            set: { newVal in Task { await subZero.setFreezerTemp(applianceId: fridge.applianceId, temp: newVal) } }
                        ), in: -5...5)
                        .labelsHidden()
                        Text("\(Int(setpoint))°")
                            .fontWeight(.semibold)
                    }
                }
                // Mode
                HStack {
                    Image(systemName: "snowflake")
                        .foregroundStyle(.secondary)
                    Picker("Mode", selection: Binding(
                        get: { fridge.mode },
                        set: { newMode in Task { await subZero.setMode(applianceId: fridge.applianceId, mode: newMode.rawValue) } }
                    )) {
                        Text("Normal").tag(RefrigeratorMode.normal)
                        Text("Vacation").tag(RefrigeratorMode.vacation)
                        Text("Sabbath").tag(RefrigeratorMode.sabbath)
                    }
                }
                // Water Filter
                if let pct = fridge.waterFilterPct {
                    HStack {
                        Image(systemName: "drop.triangle")
                            .foregroundStyle(.secondary)
                        Text("Water Filter")
                        Spacer()
                        Text("\(Int(pct))%")
                            .fontWeight(.semibold)
                            .foregroundStyle(pct < 20 ? .orange : .primary)
                    }
                }
                // Air Purification
                if let pct = fridge.airPurificationPct {
                    HStack {
                        Image(systemName: "wind")
                            .foregroundStyle(.secondary)
                        Text("Air Purification")
                        Spacer()
                        Text("\(Int(pct))%")
                            .fontWeight(.semibold)
                            .foregroundStyle(pct < 20 ? .orange : .primary)
                    }
                }
                // Night Mode
                HStack {
                    Image(systemName: "moon")
                        .foregroundStyle(.secondary)
                    Toggle("Night Mode", isOn: Binding(
                        get: { fridge.nightMode },
                        set: { newVal in Task { await subZero.setNightMode(applianceId: fridge.applianceId, on: newVal) } }
                    ))
                }
                // Humidity Control
                if let humidity = fridge.humidityControl {
                    HStack {
                        Image(systemName: "humidity")
                            .foregroundStyle(.secondary)
                        Text("Humidity Control")
                        Spacer()
                        Text(humidity)
                            .fontWeight(.semibold)
                    }
                }
                // Ice Maker
                HStack {
                    Image(systemName: "cube")
                        .foregroundStyle(.secondary)
                    Toggle("Ice Maker", isOn: Binding(
                        get: { fridge.iceMakerOn },
                        set: { newVal in Task { await subZero.setIceMaker(applianceId: fridge.applianceId, on: newVal) } }
                    ))
                }
                // Light (Accent Light for beverage centers)
                HStack {
                    Image(systemName: "light.max")
                        .foregroundStyle(.secondary)
                    Toggle("Light", isOn: Binding(
                        get: { fridge.lightOn },
                        set: { newVal in Task { await subZero.toggleLight(applianceId: fridge.applianceId, on: newVal) } }
                    ))
                }
            }

            // Doors & Status
            Section("Status") {
                HStack {
                    Text("Fridge Door")
                    Spacer()
                    Text(fridge.fridgeDoorOpen ? "Open" : "Closed")
                        .foregroundStyle(fridge.fridgeDoorOpen ? .orange : .secondary)
                }
                if fridge.freezerSetpoint != nil {
                    HStack {
                        Text("Freezer Door")
                        Spacer()
                        Text(fridge.freezerDoorOpen ? "Open" : "Closed")
                            .foregroundStyle(fridge.freezerDoorOpen ? .orange : .secondary)
                    }
                }
                if fridge.maxIceOn {
                    HStack {
                        Text("Max Ice")
                        Spacer()
                        Text("Active")
                            .foregroundStyle(.blue)
                    }
                }
            }

            Section("Info") {
                HStack {
                    Text("Model")
                    Spacer()
                    Text(fridge.model.isEmpty ? "Sub-Zero" : fridge.model)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Status")
                    Spacer()
                    Text(fridge.online ? "Online" : "Offline")
                        .foregroundStyle(fridge.online ? .green : .secondary)
                }
            }
        }
        .navigationTitle(fridge.applianceName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Wolf Oven Row

struct WolfOvenRow: View {
    let oven: WolfOven

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "oven.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(oven.unitOn ? .orange : EditorialTheme.secondaryText)

                Text(oven.applianceName.uppercased())
                    .font(.system(size: 9, weight: .medium))
                    .tracking(0.8)
                    .foregroundStyle(EditorialTheme.secondaryText)

                Spacer()

                if oven.unitOn {
                    Text(oven.cookMode.label.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(.orange)
                } else if !oven.online {
                    Text("OFFLINE")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(EditorialTheme.secondaryText)
                } else {
                    Text("OFF")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(EditorialTheme.secondaryText)
                }
            }

            if oven.unitOn {
                HStack(spacing: 16) {
                    if let temp = oven.currentTemp {
                        statBlock(label: "CURRENT", value: "\(Int(temp))°F")
                    }
                    if let target = oven.targetTemp {
                        statBlock(label: "TARGET", value: "\(Int(target))°F")
                    }
                    if let probe = oven.probeTemp {
                        statBlock(label: "PROBE", value: "\(Int(probe))°F")
                    }
                    if let time = oven.timerFormatted {
                        statBlock(label: "TIMER", value: time)
                    }
                }
            }
        }
        .padding(12)
        .background(EditorialTheme.cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(oven.unitOn ? Color.orange.opacity(0.3) : EditorialTheme.cardBorder, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func statBlock(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 7, weight: .medium))
                .tracking(0.5)
                .foregroundStyle(EditorialTheme.secondaryText)
            Text(value)
                .font(.system(size: 12, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(EditorialTheme.primaryText)
        }
    }
}

// MARK: - Wolf Oven Detail View

struct WolfOvenDetailView: View {
    let oven: WolfOven
    @Environment(SubZeroManager.self) var subZero
    @State private var showRemoteReadyInstructions = false
    @State private var showStartOven = false
    @State private var showTimerPicker = false
    @State private var pickerTimerIndex = 1

    var body: some View {
        List {
            // Action buttons
            if oven.online && !oven.unitOn {
                Section {
                    if oven.remoteReady {
                        Button {
                            showStartOven = true
                        } label: {
                            HStack {
                                Spacer()
                                Text("START UPPER OVEN")
                                    .font(.system(size: 14, weight: .semibold))
                                    .tracking(0.5)
                                Spacer()
                            }
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.primary)

                        Button {
                            showRemoteReadyInstructions = true
                        } label: {
                            HStack {
                                Spacer()
                                Text("MAKE LOWER OVEN REMOTE READY")
                                    .font(.system(size: 12, weight: .medium))
                                    .tracking(0.3)
                                Spacer()
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button {
                            showRemoteReadyInstructions = true
                        } label: {
                            HStack {
                                Spacer()
                                Text("MAKE REMOTE READY")
                                    .font(.system(size: 14, weight: .semibold))
                                    .tracking(0.5)
                                Spacer()
                            }
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.primary)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            }

            // Kitchen Timers
            Section("Kitchen Timers") {
                kitchenTimerRow(index: 1, remaining: oven.timerFormatted)
                kitchenTimerRow(index: 2, remaining: oven.timer2Formatted)
            }

            // Upper Oven
            Section("Upper Oven") {
                ovenCavityRow(icon: "thermometer.medium", label: "Temperature",
                              value: oven.unitOn && oven.currentTemp != nil ? "\(Int(oven.currentTemp!))°F" : nil)
                ovenCavityRow(icon: "flame", label: "Mode",
                              value: oven.unitOn && oven.cookMode != .off && oven.cookMode != .unknown ? oven.cookMode.label : nil)
                // Light toggle
                HStack {
                    Image(systemName: "light.max")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    Text("Light")
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { oven.lightOn },
                        set: { newValue in
                            Task { await subZero.toggleOvenLight(applianceId: oven.applianceId, on: newValue) }
                        }
                    ))
                    .labelsHidden()
                }
                ovenCavityRow(icon: "fork.knife", label: "Probe",
                              value: oven.probeTemp != nil ? "\(Int(oven.probeTemp!))°F" : nil)
            }

            // Lower Oven
            Section("Lower Oven") {
                ovenCavityRow(icon: "thermometer.medium", label: "Temperature", value: nil)
                ovenCavityRow(icon: "flame", label: "Mode", value: nil)
                ovenCavityRow(icon: "light.max", label: "Light", value: nil)
                ovenCavityRow(icon: "fork.knife", label: "Probe", value: nil)
            }

            Section("Info") {
                HStack {
                    Text("Model")
                    Spacer()
                    Text(oven.model.isEmpty ? "Wolf" : oven.model)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Status")
                    Spacer()
                    Text(oven.online ? "Online" : "Offline")
                        .foregroundStyle(oven.online ? .green : .secondary)
                }
            }
        }
        .navigationTitle(oven.applianceName)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showRemoteReadyInstructions) {
            RemoteReadyInstructionsSheet(isPresented: $showRemoteReadyInstructions)
        }
        .sheet(isPresented: $showStartOven) {
            StartOvenSheet(oven: oven, isPresented: $showStartOven)
        }
        .sheet(isPresented: $showTimerPicker) {
            KitchenTimerPickerSheet(oven: oven, timerIndex: pickerTimerIndex, isPresented: $showTimerPicker)
        }
    }

    private func kitchenTimerRow(index: Int, remaining: String?) -> some View {
        Button {
            pickerTimerIndex = index
            showTimerPicker = true
        } label: {
            HStack {
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
                Text("Kitchen Timer \(index)")
                    .foregroundStyle(.primary)
                Spacer()
                if let remaining {
                    Text(remaining).foregroundStyle(.orange)
                } else {
                    Text("Off").foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func ovenCavityRow(icon: String, label: String, value: String?) -> some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            Text(label)
            Spacer()
            Text(value ?? "Off")
                .foregroundStyle(value != nil ? .primary : .secondary)
        }
    }
}

// MARK: - Kitchen Timer Picker Sheet

struct KitchenTimerPickerSheet: View {
    let oven: WolfOven
    var timerIndex: Int = 1
    @Binding var isPresented: Bool
    @Environment(SubZeroManager.self) var subZero
    @State private var hours: Int = 0
    @State private var minutes: Int = 30

    private var isTimerRunning: Bool {
        if let remaining = oven.remaining(forTimer: timerIndex), remaining > 0 { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("Kitchen Timer \(timerIndex)")
                    .font(.title.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)

                Spacer()

                HStack(spacing: 0) {
                    // Hours picker
                    VStack(spacing: 8) {
                        Text("Hours")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        Picker("Hours", selection: $hours) {
                            ForEach(0..<24, id: \.self) { h in
                                Text("\(h)").tag(h)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(width: 100)
                    }

                    Text(":")
                        .font(.system(size: 36, weight: .medium))
                        .padding(.top, 28)

                    // Minutes picker
                    VStack(spacing: 8) {
                        Text("Minutes")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        Picker("Minutes", selection: $minutes) {
                            ForEach(0..<60, id: \.self) { m in
                                Text("\(m)").tag(m)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(width: 100)
                    }
                }

                Spacer()

                Button {
                    let totalMinutes = hours * 60 + minutes
                    Task {
                        await subZero.setKitchenTimer(applianceId: oven.applianceId, minutes: totalMinutes, timer: timerIndex)
                        isPresented = false
                    }
                } label: {
                    Text("SET TIMER")
                        .font(.system(size: 16, weight: .semibold))
                        .tracking(0.5)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(.primary)
                .disabled(hours == 0 && minutes == 0)
                .padding(.horizontal, 24)
                .padding(.bottom, isTimerRunning ? 8 : 32)

                if isTimerRunning {
                    Button(role: .destructive) {
                        Task {
                            await subZero.cancelKitchenTimer(applianceId: oven.applianceId, timer: timerIndex)
                            isPresented = false
                        }
                    } label: {
                        Text("TURN OFF TIMER")
                            .font(.system(size: 16, weight: .semibold))
                            .tracking(0.5)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") { isPresented = false }
                }
            }
            .onAppear {
                if let remaining = oven.timerRemaining, remaining > 0 {
                    hours = Int(remaining) / 3600
                    minutes = (Int(remaining) % 3600) / 60
                }
            }
        }
    }
}

// MARK: - Remote Ready Instructions Sheet

struct RemoteReadyInstructionsSheet: View {
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                Text("Make Remote Ready")
                    .font(.title.bold())

                VStack(alignment: .leading, spacing: 20) {
                    instructionStep(number: 1, text: "Select **More** on the upper or lower oven knob.")
                    instructionStep(number: 2, text: "Select **Connect** and press **Start** on the oven display.")
                    instructionStep(number: 3, text: "Follow the instructions on the oven display.")
                }

                Spacer()
            }
            .padding(24)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { isPresented = false }
                }
            }
        }
    }

    private func instructionStep(number: Int, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text("\(number).")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)
            Text(text)
                .font(.body)
        }
    }
}

// MARK: - Start Oven Sheet

struct StartOvenSheet: View {
    let oven: WolfOven
    @Binding var isPresented: Bool
    @Environment(SubZeroManager.self) var subZero
    @State private var selectedMode: OvenMode = .convection
    @State private var selectedTemp: Double = 325
    @State private var showModePicker = false
    @State private var showTempPicker = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Start Oven")
                        .font(.title.bold())
                        .padding(.horizontal, 24)

                    // Mode row
                    Button { showModePicker = true } label: {
                        HStack(spacing: 16) {
                            Image(systemName: "flame")
                                .font(.title3)
                                .foregroundStyle(.primary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Mode")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text(selectedMode.label)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                    }

                    // Temperature row
                    Button { showTempPicker = true } label: {
                        HStack(spacing: 16) {
                            Image(systemName: "thermometer.medium")
                                .font(.title3)
                                .foregroundStyle(.primary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Temperature")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text("\(Int(selectedTemp))°")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                    }
                }

                Spacer()

                // START OVEN button
                Button {
                    Task {
                        await subZero.preheatOven(applianceId: oven.applianceId, temp: Int(selectedTemp), mode: selectedMode.rawValue)
                        isPresented = false
                    }
                } label: {
                    Text("START OVEN")
                        .font(.system(size: 16, weight: .semibold))
                        .tracking(0.5)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(.primary)
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") { isPresented = false }
                }
            }
            .sheet(isPresented: $showModePicker) {
                OvenModePickerSheet(selectedMode: $selectedMode, isPresented: $showModePicker)
            }
            .sheet(isPresented: $showTempPicker) {
                OvenTempPickerSheet(selectedTemp: $selectedTemp, isPresented: $showTempPicker)
            }
        }
    }
}

// MARK: - Oven Mode Picker Sheet

struct OvenModePickerSheet: View {
    @Binding var selectedMode: OvenMode
    @Binding var isPresented: Bool
    @State private var tempSelection: OvenMode = .convection

    private let modes: [OvenMode] = [.convection, .bake, .convection_roast, .roast, .broil, .proof, .dehydrate, .stone, .warm]

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                Text("Mode")
                    .font(.title.bold())
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(modes, id: \.self) { mode in
                            Button {
                                tempSelection = mode
                            } label: {
                                HStack(spacing: 16) {
                                    Image(systemName: tempSelection == mode ? "checkmark.circle.fill" : "circle")
                                        .font(.title3)
                                        .foregroundStyle(tempSelection == mode ? .primary : .secondary)
                                    Text(mode.label)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                }
                                .padding(.horizontal, 24)
                                .padding(.vertical, 14)
                            }
                            if mode != modes.last {
                                Divider().padding(.leading, 64)
                            }
                        }
                    }
                }

                Spacer()

                Button {
                    selectedMode = tempSelection
                    isPresented = false
                } label: {
                    Text("SAVE")
                        .font(.system(size: 16, weight: .semibold))
                        .tracking(0.5)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(.primary)
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") { isPresented = false }
                }
            }
            .onAppear { tempSelection = selectedMode }
        }
    }
}

// MARK: - Oven Temperature Picker Sheet

struct OvenTempPickerSheet: View {
    @Binding var selectedTemp: Double
    @Binding var isPresented: Bool
    @State private var tempValue: Double = 325

    private let minTemp: Double = 200
    private let maxTemp: Double = 550

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("Temperature")
                    .font(.title.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)

                Spacer()

                // Temperature display and arc
                ZStack {
                    // Background arc
                    ArcShape(startAngle: .degrees(150), endAngle: .degrees(390))
                        .stroke(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                        .frame(width: 240, height: 240)

                    // Fill arc
                    ArcShape(startAngle: .degrees(150), endAngle: .degrees(150 + 240 * (tempValue - minTemp) / (maxTemp - minTemp)))
                        .stroke(Color.red, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                        .frame(width: 240, height: 240)

                    // Temperature text
                    Text("\(Int(tempValue))°")
                        .font(.system(size: 48, weight: .medium))
                        .monospacedDigit()
                }
                .padding(.bottom, 8)

                // Range labels
                HStack {
                    Text("\(Int(minTemp))°")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(maxTemp))°")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 48)

                // Slider for temperature
                Slider(value: $tempValue, in: minTemp...maxTemp, step: 5)
                    .tint(.red)
                    .padding(.horizontal, 32)
                    .padding(.top, 24)

                Spacer()

                Button {
                    selectedTemp = tempValue
                    isPresented = false
                } label: {
                    Text("SAVE")
                        .font(.system(size: 16, weight: .semibold))
                        .tracking(0.5)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(.primary)
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") { isPresented = false }
                }
            }
            .onAppear { tempValue = selectedTemp }
        }
    }
}

// MARK: - Arc Shape

struct ArcShape: Shape {
    let startAngle: Angle
    let endAngle: Angle

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY),
                     radius: rect.width / 2,
                     startAngle: startAngle,
                     endAngle: endAngle,
                     clockwise: false)
        return path
    }
}
