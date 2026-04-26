import AppIntents

struct LowerShadesIntent: AppIntent {
    static var title: LocalizedStringResource = "Lower Main Shades"
    static var description = IntentDescription("Lower the Family Room and Dining Room shades")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await ServerAPIClient.lowerMainShades()
        return .result(dialog: "Shades lowered.")
    }
}
