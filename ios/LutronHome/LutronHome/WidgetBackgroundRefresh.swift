import Foundation
import BackgroundTasks

/// Orchestrates the BGAppRefreshTask that keeps widget data fresh when the
/// main app isn't in the foreground. Only cloud-based integrations can be
/// polled here — HomeKit (Ecobee), LEAP/TLS (Lutron), and local UPnP (Sonos)
/// all require foreground state, so those portions of the widget snapshot
/// are preserved from the last foreground sync.
enum WidgetBackgroundRefresh {

    /// Maximum wall-clock time we'll spend polling before we give up and
    /// write whatever we got. iOS typically grants ~30 seconds per BG task.
    private static let overallTimeout: TimeInterval = 25

    static func handle(task: BGAppRefreshTask) {
        // Always schedule the next refresh before doing any work so the system
        // keeps cadence even if we fail or time out.
        scheduleNext()

        let work = Task {
            await performRefresh()
            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }

    static func scheduleNext() {
        let request = BGAppRefreshTaskRequest(
            identifier: LutronHomeApp.widgetRefreshTaskId
        )
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("WidgetBackgroundRefresh: failed to schedule — \(error)")
        }
    }

    private static func performRefresh() async {
        // Start with whatever the foreground last wrote. Ecobee / Sonos /
        // Lutron parts of the snapshot will be preserved; we only replace
        // the cloud-backed slots.
        var snapshot = AppGroupManager.readWidgetData()

        let homeConnect = HomeConnectManager()
        let smartHQ = SmartHQManager()
        let myQ = MyQManager()
        let myUplink = MyUplinkManager()
        let totalConnect = TotalConnectManager()

        // Kick off every cloud fetch in parallel, bounded by an overall
        // timeout so a single slow endpoint doesn't burn the whole task.
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await withTimeout(overallTimeout) {
                    await homeConnect.fetchAllStatuses()
                }
            }
            group.addTask {
                await withTimeout(overallTimeout) {
                    await smartHQ.fetchAllStatuses()
                }
            }
            group.addTask {
                await withTimeout(overallTimeout) {
                    await myQ.fetchDevices()
                }
            }
            group.addTask {
                await withTimeout(overallTimeout) {
                    await myUplink.fetchSystems()
                    await myUplink.fetchDataPoints()
                }
            }
            group.addTask {
                await withTimeout(overallTimeout) {
                    await totalConnect.refreshOnce()
                }
            }
            await group.waitForAll()
        }

        // Merge fresh cloud data into the snapshot.

        // Alarm
        if totalConnect.isLinked, let panel = totalConnect.panels.first {
            let faults = (totalConnect.zones[panel.locationId] ?? []).filter { $0.faulted }.count
            snapshot.alarm = AppGroupManager.AlarmSnapshot(
                stateLabel: panel.state.label,
                isArmed: panel.state.isArmed,
                isAlarming: panel.state == .alarming,
                faultCount: faults
            )
        }

        // Dishwashers
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

        // Washer / Dryer
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

        // Garage
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

        // Heat Pump
        if myUplink.isLinked, myUplink.heatPump.connected {
            snapshot.heatPump = AppGroupManager.HeatPumpSnapshot(
                connected: true,
                outdoorTemp: myUplink.heatPump.outdoorTemp,
                operatingMode: myUplink.heatPump.operatingMode
            )
        }

        snapshot.lastUpdated = Date()

        AppGroupManager.writeWidgetData(snapshot)
        AppGroupManager.reloadWidgets()
    }

    /// Run `work` with a timeout. If it doesn't complete in time, just return.
    private static func withTimeout(
        _ seconds: TimeInterval,
        _ work: @escaping @Sendable () async -> Void
    ) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
            }
            // Whichever finishes first wins; cancel the rest.
            _ = await group.next()
            group.cancelAll()
        }
    }
}
