import AppIntents

struct EveningSceneIntent: AppIntent {
    static var title: LocalizedStringResource = "Evening Scene"
    static var description = IntentDescription("Set the main floor to evening lighting levels")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await ServerAPIClient.activateEveningScene()
        return .result(dialog: "Evening scene activated.")
    }
}
