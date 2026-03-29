import AppIntents

struct VoiceCommandIntent: AppIntent {
    static var title: LocalizedStringResource = "Voice Command"
    static var description = IntentDescription("Tell Lutron Home what to do using natural language")

    @Parameter(title: "Command")
    var spokenText: String

    static var parameterSummary: some ParameterSummary {
        Summary("Tell Lutron Home \(\.$spokenText)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let reply = try await ServerAPIClient.sendChatMessage(spokenText)
        return .result(dialog: "\(reply)")
    }
}
