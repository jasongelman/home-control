import SwiftUI
import HomeKit

struct EditorialStatusGrid: View {
    @Environment(HomeKitManager.self) var homeKit
    @Environment(MyQManager.self) var myQ
    @Environment(TotalConnectManager.self) var totalConnect
    @Environment(SonosManager.self) var sonos
    @Environment(HomeConnectManager.self) var homeConnect
    @Environment(SmartHQManager.self) var smartHQ

    @State private var showAlarmSheet = false
    @State private var showSonosSheet = false
    @State private var showDishwasherSheet: String?
    @State private var showLaundrySheet: String?

    private let columns = [
        GridItem(.flexible(), spacing: EditorialTheme.gridSpacing),
        GridItem(.flexible(), spacing: EditorialTheme.gridSpacing),
        GridItem(.flexible(), spacing: EditorialTheme.gridSpacing),
    ]

    var body: some View {
        let items = buildItems()
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                let activeCount = items.filter(\.isActive).count
                EditorialSectionHeader(
                    title: "STATUS",
                    trailing: "\(activeCount) ACTIVE"
                )

                LazyVGrid(columns: columns, spacing: EditorialTheme.gridSpacing) {
                    ForEach(items) { item in
                        statusCell(item)
                    }
                }
            }
            .sheet(isPresented: $showAlarmSheet) {
                if let panel = totalConnect.panels.first {
                    AlarmDetailView(panel: panel, manager: totalConnect)
                }
            }
            .sheet(isPresented: $showSonosSheet) {
                NavigationStack {
                    SonosControlView()
                }
            }
            .sheet(item: $showDishwasherSheet) { id in
                NavigationStack {
                    DishwasherDetailView(dishwasherId: id)
                }
            }
            .sheet(item: $showLaundrySheet) { id in
                NavigationStack {
                    LaundryDetailView(applianceId: id)
                }
            }
        }
    }

    // MARK: - Status Cell (compact 3-column layout)

    private func statusCell(_ item: StatusItem) -> some View {
        Button {
            item.onTap?()
        } label: {
            VStack(spacing: 6) {
                HStack(spacing: 0) {
                    Image(systemName: item.icon)
                        .font(.system(size: 11))
                        .foregroundStyle(item.isActive ? EditorialTheme.accent : EditorialTheme.secondaryText)
                    Spacer(minLength: 0)
                    if let actionText = item.actionLabel {
                        if let quickAction = item.quickAction {
                            Button {
                                quickAction()
                            } label: {
                                Text(actionText)
                                    .font(.system(size: 8, weight: .bold))
                                    .tracking(0.4)
                                    .foregroundStyle(EditorialTheme.primaryText)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text(actionText)
                                .font(EditorialTheme.monoValue(size: 10))
                                .foregroundStyle(item.isActive ? EditorialTheme.accent : EditorialTheme.secondaryText)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.label)
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.4)
                        .textCase(.uppercase)
                        .foregroundStyle(EditorialTheme.primaryText)
                        .lineLimit(1)

                    Text(item.subtitle)
                        .font(.system(size: 7, weight: .medium))
                        .foregroundStyle(EditorialTheme.secondaryText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .editorialCard(padding: 8)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Data Model

    struct StatusItem: Identifiable {
        let id: String
        let icon: String
        let label: String
        let subtitle: String
        let isActive: Bool
        var actionLabel: String? = nil
        var quickAction: (() -> Void)? = nil
        var onTap: (() -> Void)? = nil
    }

    private func buildItems() -> [StatusItem] {
        var items: [StatusItem] = []

        // Garage doors (HomeKit)
        for door in homeKit.garageDoors {
            let state = homeKit.garageDoorStates[door.uniqueIdentifier]
            let isOpen = state?.current == .open || state?.current == .opening
            let stateLabel = state?.current.label ?? "Unknown"
            let shortName = door.name
                .replacingOccurrences(of: " Door", with: "")
                .replacingOccurrences(of: " door", with: "")
            items.append(StatusItem(
                id: "hk_garage_\(door.uniqueIdentifier)",
                icon: "door.garage.open",
                label: shortName,
                subtitle: stateLabel,
                isActive: isOpen,
                actionLabel: isOpen ? "CLOSE" : "OPEN",
                quickAction: { toggleGarageDoor(door) }
            ))
        }

        // Garage doors (MyQ)
        for door in myQ.doors {
            let isOpen = door.state == .open || door.state.isMoving
            let shortName = door.name
                .replacingOccurrences(of: " Door", with: "")
                .replacingOccurrences(of: " door", with: "")
            items.append(StatusItem(
                id: "myq_\(door.serialNumber)",
                icon: "door.garage.open",
                label: shortName,
                subtitle: door.state.label,
                isActive: isOpen,
                actionLabel: isOpen ? "CLOSE" : "OPEN",
                quickAction: { toggleMyQDoor(door) }
            ))
        }

        // Alarm
        if totalConnect.isLinked, let panel = totalConnect.panels.first {
            let faults = (totalConnect.zones[panel.locationId] ?? []).filter(\.faulted).count
            let subtitle = faults > 0 ? "\(faults) FAULT\(faults == 1 ? "" : "S")" : "ALL CLEAR"
            items.append(StatusItem(
                id: "alarm",
                icon: panel.state.isArmed ? "lock.fill" : "lock.open.fill",
                label: "ALARM",
                subtitle: subtitle,
                isActive: panel.state.isArmed || panel.state == .alarming,
                actionLabel: panel.state == .disarmed ? "OFF" : panel.state.label.uppercased(),
                onTap: { showAlarmSheet = true }
            ))
        }

        // Sonos (single card for entire system)
        if sonos.hasPlayers {
            let playingCount = sonos.coordinators.filter { $0.state == .playing }.count
            let subtitle: String
            let isActive: Bool
            if playingCount > 0 {
                let track = sonos.coordinators.first(where: { $0.state == .playing })?.currentTrack?.title ?? "Playing"
                subtitle = playingCount == 1 ? track : "\(playingCount) playing"
                isActive = true
            } else {
                subtitle = "\(sonos.coordinators.count) speaker\(sonos.coordinators.count == 1 ? "" : "s")"
                isActive = false
            }
            items.append(StatusItem(
                id: "sonos",
                icon: playingCount > 0 ? "speaker.wave.2.fill" : "speaker.fill",
                label: "SONOS",
                subtitle: subtitle,
                isActive: isActive,
                onTap: { showSonosSheet = true }
            ))
        }

        // Dishwashers (active)
        for dw in homeConnect.dishwashers where dw.operationState.isActive {
            let time = dw.remainingTimeFormatted ?? ""
            items.append(StatusItem(
                id: "dw_\(dw.applianceId)",
                icon: "dishwasher",
                label: dishwasherLabel(dw),
                subtitle: "\(dw.operationState.label)",
                isActive: true,
                actionLabel: time,
                onTap: { showDishwasherSheet = dw.applianceId }
            ))
        }

        // Washer/Dryer (active)
        for app in smartHQ.appliances where app.machineState.isActive {
            let time = app.remainingTimeFormatted ?? ""
            items.append(StatusItem(
                id: "shq_\(app.applianceId)",
                icon: app.applianceType == "Washer" ? "washer" : "dryer",
                label: app.applianceType.uppercased(),
                subtitle: app.cycleName ?? app.machineState.label,
                isActive: true,
                actionLabel: time,
                onTap: { showLaundrySheet = app.applianceId }
            ))
        }

        return items
    }

    // MARK: - Actions

    private func toggleGarageDoor(_ door: HMAccessory) {
        Task { await homeKit.toggleGarageDoor(door) }
    }

    private func toggleMyQDoor(_ door: MyQDoor) {
        Task {
            if door.state == .open {
                await myQ.closeDoor(door)
            } else {
                await myQ.openDoor(door)
            }
        }
    }

    private func dishwasherLabel(_ dw: DishwasherStatus) -> String {
        if homeConnect.dishwashers.count > 1 {
            let name = dw.applianceName.lowercased()
            if name.contains("left") { return "DISH L" }
            if name.contains("right") { return "DISH R" }
        }
        return "DISHWASHER"
    }
}

// MARK: - Sheet item binding helper

private extension View {
    func sheet<ID: Hashable, Content: View>(item binding: Binding<ID?>, @ViewBuilder content: @escaping (ID) -> Content) -> some View {
        let itemBinding = Binding<SheetItem<ID>?>(
            get: { binding.wrappedValue.map { SheetItem(id: $0) } },
            set: { binding.wrappedValue = $0?.id }
        )
        return self.sheet(item: itemBinding) { item in
            content(item.id)
        }
    }
}

private struct SheetItem<ID: Hashable>: Identifiable {
    let id: ID
}
