import AppIntents

struct ActivateSceneIntent: AppIntent {
    static var title: LocalizedStringResource = "Activate Scene"
    static var description = IntentDescription("Activate a saved lighting scene")

    @Parameter(title: "Scene Name")
    var sceneName: String

    static var parameterSummary: some ParameterSummary {
        Summary("Activate \(\.$sceneName)")
    }

    init() {}

    init(sceneName: String) {
        self.sceneName = sceneName
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let scenes = AppGroupManager.readScenes()
        guard let scene = scenes.first(where: {
            $0.name.localizedCaseInsensitiveCompare(sceneName) == .orderedSame
        }) else {
            return .result(dialog: "I couldn't find a scene called \"\(sceneName)\".")
        }

        try await ServerAPIClient.activateScene(sceneId: scene.id)
        return .result(dialog: "Activated \(scene.name).")
    }
}
