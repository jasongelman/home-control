import WidgetKit

struct LutronWidgetEntry: TimelineEntry {
    let date: Date
    let suggestions: [SuggestedAction]
    let lightsOnCount: Int
    let activeAppliance: AppGroupManager.ApplianceInfo?
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
            activeAppliance: nil
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (LutronWidgetEntry) -> Void) {
        completion(buildEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LutronWidgetEntry>) -> Void) {
        let entry = buildEntry()
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: entry.date)!
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func buildEntry() -> LutronWidgetEntry {
        let devices = AppGroupManager.readDevices()
        let scenes = AppGroupManager.readScenes()
        let events = AppGroupManager.readUsageEvents()
        let lightsOn = AppGroupManager.readLightsOnCount()
        let appliances = AppGroupManager.readApplianceStatus()

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
            activeAppliance: activeAppliance
        )
    }
}
