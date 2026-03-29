import Foundation

enum ServerAPIClient {
    enum APIError: Error, LocalizedError {
        case noServer
        case httpError(Int)
        case networkError(Error)

        var errorDescription: String? {
            switch self {
            case .noServer: return "Server address not configured"
            case .httpError(let code): return "Server returned HTTP \(code)"
            case .networkError(let err): return err.localizedDescription
            }
        }
    }

    private static func baseURL() -> URL? {
        let host = AppGroupManager.readServerHost()
        return URL(string: "http://\(host):3001")
    }

    /// Set a device to a specific level
    static func setDeviceLevel(deviceId: Int, level: Double, fadeTime: Double = 1.0) async throws {
        guard let base = baseURL() else { throw APIError.noServer }
        let url = base.appendingPathComponent("/api/devices/\(deviceId)")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let body: [String: Any] = ["level": level, "fadeTime": fadeTime]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    /// Activate a scene by ID
    static func activateScene(sceneId: String) async throws {
        guard let base = baseURL() else { throw APIError.noServer }
        let url = base.appendingPathComponent("/api/scenes/\(sceneId)/activate")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    /// Turn off all lights except those in Sebastian's Room
    static func turnOffAllLights() async throws {
        let devices = AppGroupManager.readDevices()
        let lightsToTurnOff = devices.filter {
            $0.category == .light && $0.level > 0 && $0.room != "Sebastian's Room"
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for device in lightsToTurnOff {
                group.addTask {
                    try await setDeviceLevel(deviceId: device.integrationId, level: 0, fadeTime: 1.0)
                }
            }
            try await group.waitForAll()
        }
    }

    /// Send a chat message and execute resulting actions via server
    static func sendChatMessage(_ text: String) async throws -> String {
        guard let base = baseURL() else { throw APIError.noServer }
        let url = base.appendingPathComponent("/api/chat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let body: [String: Any] = ["message": text]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let reply = json["reply"] as? String {
            return reply
        }
        return "Done"
    }
}
