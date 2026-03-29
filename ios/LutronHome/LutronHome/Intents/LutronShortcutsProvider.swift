import AppIntents

struct LutronShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ActivateSceneIntent(),
            phrases: [
                "Activate a scene in \(.applicationName)",
                "Turn on a scene in \(.applicationName)"
            ],
            shortTitle: "Activate Scene",
            systemImageName: "lightswitch.on"
        )
        AppShortcut(
            intent: AllLightsOffIntent(),
            phrases: [
                "Turn off all lights in \(.applicationName)",
                "Lights off in \(.applicationName)"
            ],
            shortTitle: "All Lights Off",
            systemImageName: "lightbulb.slash"
        )
        AppShortcut(
            intent: VoiceCommandIntent(),
            phrases: [
                "Tell \(.applicationName) a command",
                "Ask \(.applicationName) something"
            ],
            shortTitle: "Voice Command",
            systemImageName: "mic"
        )
    }
}
