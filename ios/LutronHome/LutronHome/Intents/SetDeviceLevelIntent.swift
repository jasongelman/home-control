import AppIntents

struct SetDeviceLevelIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Device Level"
    static var description = IntentDescription("Set a light or shade to a specific level")

    @Parameter(title: "Device Name")
    var deviceName: String

    @Parameter(title: "Level", controlStyle: .slider, inclusiveRange: (0, 100))
    var level: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Set \(\.$deviceName) to \(\.$level)%")
    }

    init() {}

    init(deviceName: String, level: Int) {
        self.deviceName = deviceName
        self.level = level
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let devices = AppGroupManager.readDevices()
        guard let device = devices.first(where: {
            $0.name.localizedCaseInsensitiveContains(deviceName)
        }) else {
            return .result(dialog: "I couldn't find a device called \"\(deviceName)\".")
        }

        try await ServerAPIClient.setDeviceLevel(
            deviceId: device.integrationId, level: Double(level)
        )

        let verb = level == 0 ? "Turned off" : "Set"
        let suffix = level == 0 ? "" : " to \(level)%"
        return .result(dialog: "\(verb) \(device.name)\(suffix).")
    }
}

private extension String {
    func localizedCaseInsensitiveContains(_ other: String) -> Bool {
        range(of: other, options: .caseInsensitive) != nil
    }
}
