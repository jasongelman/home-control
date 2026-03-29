import SwiftUI
import WidgetKit

@main
struct LutronHomeWidgetBundle: WidgetBundle {
    var body: some Widget {
        LutronHomeSmallWidget()
        LutronHomeMediumWidget()
    }
}

struct LutronHomeSmallWidget: Widget {
    let kind = "LutronHomeSmallWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LutronTimelineProvider()) { entry in
            SmallWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Lutron Home")
        .description("Quick actions for your home")
        .supportedFamilies([.systemSmall])
    }
}

struct LutronHomeMediumWidget: Widget {
    let kind = "LutronHomeMediumWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LutronTimelineProvider()) { entry in
            MediumWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Lutron Home")
        .description("Quick actions, status, and controls")
        .supportedFamilies([.systemMedium])
    }
}
