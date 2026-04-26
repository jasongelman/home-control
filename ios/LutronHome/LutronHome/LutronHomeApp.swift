import SwiftUI
import BackgroundTasks

@main
struct LutronHomeApp: App {
    @State private var store = LutronStore()
    @State private var usageTracker = UsageTracker()
    @State private var homeKit = HomeKitManager()
    @State private var homeConnect = HomeConnectManager()
    @State private var myUplink = MyUplinkManager()
    @State private var smartHQ = SmartHQManager()
    @State private var myQ = MyQManager()
    @State private var chatService = ChatService()
    @State private var totalConnect = TotalConnectManager()
    @State private var ecobee = EcobeeManager()
    @State private var sonos = SonosManager()
    @State private var weather = WeatherManager()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showVoiceInput = false

    static let widgetRefreshTaskId = "com.jasongelman.LutronHome.widgetRefresh"

    init() {
        // Register background refresh task handler. Must happen before the
        // first scene phase transition or the scheduler will reject submits.
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.widgetRefreshTaskId,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else { return }
            WidgetBackgroundRefresh.handle(task: refreshTask)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(usageTracker)
                .environment(homeKit)
                .environment(homeConnect)
                .environment(myUplink)
                .environment(smartHQ)
                .environment(myQ)
                .environment(chatService)
                .environment(totalConnect)
                .environment(ecobee)
                .environment(sonos)
                .environment(weather)
                .preferredColorScheme(.light)
                .onAppear {
                    store.usageTracker = usageTracker
                    homeKit.onGarageDoorOpened = { [weak store] in
                        store?.triggerGarageDoorLights()
                    }
                    homeKit.start()
                    homeKit.cleanupOldActivitySnapshots()
                    homeKit.loadTodayActivitySnapshots()
                    NotificationManager.shared.requestPermission()
                    weather.resume()
                    // Register Siri shortcuts
                    LutronShortcutsProvider.updateAppShortcutParameters()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    homeKit.handleScenePhase(active: newPhase == .active)
                    if newPhase == .active {
                        if !store.isConnected { store.connect() }
                        homeConnect.resume()
                        myUplink.resume()
                        smartHQ.resume()
                        myQ.resume()
                        totalConnect.resume()
                        ecobee.resume()
                        sonos.resume()
                        weather.resume()
                        // Sync widget state on foreground
                        syncWidgetState()
                    } else if newPhase == .background {
                        sonos.suspendLocal()
                        // Sync once more with the freshest data we have,
                        // then schedule a background refresh so the widget
                        // keeps updating while the app is closed.
                        syncWidgetState()
                        scheduleWidgetRefresh()
                    }
                }
                .onOpenURL { url in
                    if url.host == "voice" {
                        showVoiceInput = true
                    }
                }
                .sheet(isPresented: $showVoiceInput) {
                    NavigationStack {
                        VoiceInputView()
                            .environment(store)
                            .environment(chatService)
                            .navigationTitle("Voice Command")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("Done") { showVoiceInput = false }
                                }
                            }
                    }
                }
        }
    }

    // MARK: - Widget State Sync

    /// Build the full widget snapshot from in-memory manager state and write it
    /// to the App Group. Called on every scene phase transition so the widget
    /// always has the freshest data we can provide from the foreground.
    private func syncWidgetState() {
        var snapshot = AppGroupManager.WidgetDataSnapshot()

        // Thermostats (Ecobee via HomeKit — foreground-only)
        snapshot.thermostats = ecobee.thermostats.map { thermo in
            AppGroupManager.ThermostatSnapshot(
                id: thermo.id,
                name: thermo.displayName,
                currentTemp: thermo.currentTemp,
                modeLabel: thermo.hvacMode.label,
                isOn: thermo.hvacMode != .off
            )
        }

        // Alarm (Total Connect)
        if totalConnect.isLinked, let panel = totalConnect.panels.first {
            let faults = (totalConnect.zones[panel.locationId] ?? []).filter { $0.faulted }.count
            snapshot.alarm = AppGroupManager.AlarmSnapshot(
                stateLabel: panel.state.label,
                isArmed: panel.state.isArmed,
                isAlarming: panel.state == .alarming,
                faultCount: faults
            )
        }

        // Dishwashers (Home Connect)
        if homeConnect.isLinked {
            let dws = homeConnect.dishwashers
            snapshot.dishwashers = dws.map { dw in
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
                return AppGroupManager.ApplianceSnapshot(
                    id: dw.applianceId,
                    label: label,
                    value: value,
                    isActive: active
                )
            }
        }

        // Washer / Dryer (SmartHQ)
        if smartHQ.isLinked {
            snapshot.smartHQAppliances = smartHQ.appliances.map { app in
                var value = app.machineState.label
                if app.machineState.isActive, let time = app.remainingTimeFormatted {
                    value = time
                }
                let active = app.machineState.isActive || app.machineState == .endOfCycle
                let label = app.isWasher ? "Washer" : "Dryer"
                return AppGroupManager.ApplianceSnapshot(
                    id: app.id,
                    label: label,
                    value: value,
                    isActive: active
                )
            }
        }

        // Garage (MyQ)
        if myQ.isLinked {
            snapshot.garageDoors = myQ.doors.map { door in
                let active = door.state == .open || door.state.isMoving
                return AppGroupManager.GarageSnapshot(
                    id: door.id,
                    stateLabel: door.state.label,
                    isActive: active
                )
            }
        }

        // Heat Pump (MyUplink)
        if myUplink.isLinked, myUplink.heatPump.connected {
            snapshot.heatPump = AppGroupManager.HeatPumpSnapshot(
                connected: true,
                outdoorTemp: myUplink.heatPump.outdoorTemp,
                operatingMode: myUplink.heatPump.operatingMode
            )
        }

        // Sonos (local UPnP — foreground-only)
        snapshot.sonosCoordinators = sonos.coordinators.map { player in
            AppGroupManager.SonosSnapshot(
                id: player.id,
                name: player.name,
                isPlaying: player.state == .playing,
                trackTitle: player.currentTrack?.title
            )
        }

        // Lutron lights summary (LEAP — foreground-only)
        if store.connectionState == .connected {
            let onCount = store.devices.values.filter { $0.category == .light && $0.level > 0 }.count
            snapshot.lights = AppGroupManager.LightsSnapshot(
                connected: true,
                onCount: onCount
            )
        }

        snapshot.lastUpdated = Date()

        // Also keep the legacy appliance-status list in sync for any older
        // timeline provider reads.
        var legacyAppliances: [AppGroupManager.ApplianceInfo] = []
        for dw in homeConnect.dishwashers where dw.operationState == .run {
            if let seconds = dw.remainingTime, seconds > 0 {
                legacyAppliances.append(.init(name: "Dishwasher", remainingMinutes: seconds / 60))
            }
        }
        for app in smartHQ.appliances where app.machineState == .run {
            if let minutes = app.remainingMinutes, minutes > 0 {
                let name = app.isWasher ? "Washer" : "Dryer"
                legacyAppliances.append(.init(name: name, remainingMinutes: minutes))
            }
        }

        AppGroupManager.writeApplianceStatus(legacyAppliances)
        AppGroupManager.writeWidgetData(snapshot)
        AppGroupManager.reloadWidgets()
    }

    // MARK: - Background Task Scheduling

    private func scheduleWidgetRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.widgetRefreshTaskId)
        // iOS won't honor more frequent than ~15-30 min anyway; request 30.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("LutronHomeApp: failed to schedule widget refresh — \(error)")
        }
    }
}
