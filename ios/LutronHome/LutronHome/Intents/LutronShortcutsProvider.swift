import AppIntents

struct LutronShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ActivateSceneIntent(),
            phrases: [
                "Activate \(\.$sceneName) in \(.applicationName)",
                "Turn on \(\.$sceneName) scene in \(.applicationName)"
            ],
            shortTitle: "Activate Scene",
            systemImageName: "lightswitch.on"
        )
        AppShortcut(
            intent: SetDeviceLevelIntent(),
            phrases: [
                "Set \(\.$deviceName) to \(\.$level) percent in \(.applicationName)",
                "Turn \(\.$deviceName) to \(\.$level) in \(.applicationName)"
            ],
            shortTitle: "Set Device Level",
            systemImageName: "slider.horizontal.3"
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
                "Tell \(.applicationName) \(\.$spokenText)",
                "Ask \(.applicationName) \(\.$spokenText)"
            ],
            shortTitle: "Voice Command",
            systemImageName: "mic"
        )
    }
}
