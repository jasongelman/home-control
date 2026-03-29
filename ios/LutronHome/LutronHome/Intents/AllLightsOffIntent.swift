import AppIntents

struct AllLightsOffIntent: AppIntent {
    static var title: LocalizedStringResource = "Turn Off All Lights"
    static var description = IntentDescription("Turn off all lights in the house, except Sebastian's Room")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await ServerAPIClient.turnOffAllLights()
        return .result(dialog: "All lights turned off.")
    }
}
