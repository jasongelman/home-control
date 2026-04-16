import WidgetKit

struct LutronWidgetEntry: TimelineEntry {
    let date: Date
    let suggestions: [SuggestedAction]
    let lightsOnCount: Int
    let activeAppliance: AppGroupManager.ApplianceInfo?
    let statusCells: [AppGroupManager.StatusCellSnapshot]
}

struct LutronTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> LutronWidgetEntry {
        LutronWidgetEntry(
            date: Date(),
            suggestions: [
                SuggestedAction(type: .scene, id: "placeholder", label: "Evening Scene", subtitle: "5 devices", level: nil),
                SuggestedAction(type: .device, id: "placeholder2", label: "Kitchen Lights", subtitle: "Set to 80%", level: 80),
            ],
            lightsOnCount: 3,
            activeAppliance: nil,
            statusCells: placeholderStatusCells()
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (LutronWidgetEntry) -> Void) {
        completion(buildEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LutronWidgetEntry>) -> Void) {
        let entry = buildEntry()
        // Request refresh every 15 minutes. iOS may honor less frequently based
        // on widget budget; BGAppRefreshTask in the main app keeps App Group
        // data fresh even when the widget timeline itself hasn't rolled over.
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: entry.date)!
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func buildEntry() -> LutronWidgetEntry {
        let devices = AppGroupManager.readDevices()
        let scenes = AppGroupManager.readScenes()
        let events = AppGroupManager.readUsageEvents()
        let lightsOn = AppGroupManager.readLightsOnCount()
        let appliances = AppGroupManager.readApplianceStatus()
        let statusCells = AppGroupManager.readStatusCells()

        let suggestions = RecommendationEngine.recommend(
            events: events, devices: devices, scenes: scenes, maxCount: 3
        )

        let activeAppliance = appliances
            .filter { $0.remainingMinutes > 0 }
            .min(by: { $0.remainingMinutes < $1.remainingMinutes })

        return LutronWidgetEntry(
            date: Date(),
            suggestions: suggestions,
            lightsOnCount: lightsOn,
            activeAppliance: activeAppliance,
            statusCells: statusCells
        )
    }

    private func placeholderStatusCells() -> [AppGroupManager.StatusCellSnapshot] {
        [
            .init(id: "t1", label: "Main Floor", value: "72°", suffix: "Auto", isActive: true, isAlarming: false),
            .init(id: "t2", label: "Upstairs", value: "70°", suffix: "Heat", isActive: true, isAlarming: false),
            .init(id: "alarm", label: "Alarm", value: "Disarmed", suffix: nil, isActive: false, isAlarming: false),
            .init(id: "lights", label: "Lights", value: "3 on", suffix: nil, isActive: true, isAlarming: false),
        ]
    }
}
