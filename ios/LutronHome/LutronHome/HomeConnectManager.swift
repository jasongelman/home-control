import Foundation
import AuthenticationServices
import Observation

// MARK: - Models

struct HomeConnectTokens: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
}

enum DishwasherOperationState: String {
    case inactive = "BSH.Common.EnumType.OperationState.Inactive"
    case ready = "BSH.Common.EnumType.OperationState.Ready"
    case delayedStart = "BSH.Common.EnumType.OperationState.DelayedStart"
    case run = "BSH.Common.EnumType.OperationState.Run"
    case pause = "BSH.Common.EnumType.OperationState.Pause"
    case actionRequired = "BSH.Common.EnumType.OperationState.ActionRequired"
    case finished = "BSH.Common.EnumType.OperationState.Finished"
    case error = "BSH.Common.EnumType.OperationState.Error"
    case aborting = "BSH.Common.EnumType.OperationState.Aborting"
    case unknown = "unknown"

    var label: String {
        switch self {
        case .inactive: return "Off"
        case .ready: return "Ready"
        case .delayedStart: return "Delayed Start"
        case .run: return "Running"
        case .pause: return "Paused"
        case .actionRequired: return "Action Required"
        case .finished: return "Finished"
        case .error: return "Error"
        case .aborting: return "Cancelling"
        case .unknown: return "Unknown"
        }
    }

    var icon: String {
        switch self {
        case .inactive: return "power"
        case .ready: return "checkmark.circle"
        case .delayedStart: return "clock"
        case .run: return "play.circle.fill"
        case .pause: return "pause.circle"
        case .actionRequired: return "exclamationmark.circle"
        case .finished: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .aborting: return "xmark.circle"
        case .unknown: return "questionmark.circle"
        }
    }

    var isActive: Bool {
        switch self {
        case .run, .delayedStart, .pause, .actionRequired: return true
        default: return false
        }
    }
}

enum DishwasherDoorState: String {
    case open = "BSH.Common.EnumType.DoorState.Open"
    case closed = "BSH.Common.EnumType.DoorState.Closed"
    case locked = "BSH.Common.EnumType.DoorState.Locked"
    case unknown = "unknown"

    var label: String {
        switch self {
        case .open: return "Open"
        case .closed: return "Closed"
        case .locked: return "Locked"
        case .unknown: return "Unknown"
        }
    }
}

struct DishwasherStatus: Identifiable {
    var id: String { applianceId }
    var operationState: DishwasherOperationState = .unknown
    var doorState: DishwasherDoorState = .unknown
    var remoteControlActive: Bool = false
    var remainingTime: Int? = nil        // seconds
    var progress: Int? = nil             // 0-100
    var activeProgram: String? = nil
    var applianceId: String = ""
    var applianceName: String = ""
    var connected: Bool = false

    var remainingTimeFormatted: String? {
        guard let seconds = remainingTime, seconds > 0 else { return nil }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        if h > 0 {
            return "\(h)h \(m)m"
        }
        return "\(m)m"
    }

    var programDisplayName: String? {
        guard let program = activeProgram else { return nil }
        // "Dishcare.Dishwasher.Program.Eco50" → "Eco 50"
        let parts = program.split(separator: ".")
        guard let last = parts.last else { return program }
        // Insert spaces before uppercase letters
        var result = ""
        for (i, char) in last.enumerated() {
            if i > 0 && char.isUppercase {
                result += " "
            }
            result += String(char)
        }
        // Insert space before trailing digits
        return result.replacingOccurrences(of: "([a-zA-Z])(\\d)", with: "$1 $2", options: .regularExpression)
    }

    var canRemoteStart: Bool {
        operationState == .ready && remoteControlActive && connected &&
        (doorState == .closed || doorState == .locked)
    }
}

// MARK: - Dishwasher Program

struct DishwasherProgram: Identifiable {
    let key: String       // e.g. "Dishcare.Dishwasher.Program.Auto2"
    let name: String      // e.g. "Auto 2"
    var id: String { key }

    static func displayName(for key: String) -> String {
        let parts = key.split(separator: ".")
        guard let last = parts.last else { return key }
        var result = ""
        for (i, char) in last.enumerated() {
            if i > 0 && char.isUppercase { result += " " }
            result += String(char)
        }
        return result.replacingOccurrences(of: "([a-zA-Z])(\\d)", with: "$1 $2", options: .regularExpression)
    }
}

// MARK: - Manager

@Observable
class HomeConnectManager: @unchecked Sendable {
    var isLinked: Bool { tokens != nil }
    var dishwashers: [DishwasherStatus] = []
    var isLoading = false
    var errorMessage: String?
    var availablePrograms: [String: [DishwasherProgram]] = [:]  // keyed by applianceId
    var isStarting = false
    var startError: String?

    private var previousStates: [String: DishwasherOperationState] = [:]

    /// Convenience: first dishwasher (backward compat for single-dishwasher UI)
    var dishwasher: DishwasherStatus {
        get { dishwashers.first ?? DishwasherStatus() }
        set {
            if let idx = dishwashers.firstIndex(where: { $0.applianceId == newValue.applianceId }) {
                dishwashers[idx] = newValue
            }
        }
    }

    // Configuration — user fills these in from developer.home-connect.com
    var clientId: String {
        get { KeychainHelper.loadString(for: "hc_clientId") ?? "" }
        set { KeychainHelper.save(newValue, for: "hc_clientId") }
    }
    var clientSecret: String {
        get { KeychainHelper.loadString(for: "hc_clientSecret") ?? "" }
        set { KeychainHelper.save(newValue, for: "hc_clientSecret") }
    }

    private let baseURL = "https://api.home-connect.com"
    private let authURL = "https://api.home-connect.com/security/oauth/authorize"
    private let tokenURL = "https://api.home-connect.com/security/oauth/token"
    private let redirectScheme = "com.jasongelman.lutronhome"
    private let redirectURI = "com.jasongelman.lutronhome://oauth/homeconnect"

    private var tokens: HomeConnectTokens? {
        didSet { saveTokens() }
    }
    private var sseTask: URLSessionDataTask?
    private var pollTimer: Timer?
    private var webAuthSession: ASWebAuthenticationSession?

    init() {
        loadTokens()
    }

    // MARK: - OAuth2

    func startOAuth(from anchor: ASWebAuthenticationPresentationContextProviding) {
        guard !clientId.isEmpty else {
            errorMessage = "Set Client ID in Settings first"
            return
        }

        var components = URLComponents(string: authURL)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "IdentifyAppliance Dishwasher Dishwasher-Control"),
        ]

        let session = ASWebAuthenticationSession(
            url: components.url!,
            callbackURLScheme: redirectScheme
        ) { [weak self] callbackURL, error in
            guard let self else { return }
            if let error {
                self.errorMessage = "Auth cancelled: \(error.localizedDescription)"
                return
            }
            guard let callbackURL,
                  let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
                      .queryItems?.first(where: { $0.name == "code" })?.value else {
                self.errorMessage = "No auth code received"
                return
            }
            Task { await self.exchangeCode(code) }
        }

        session.presentationContextProvider = anchor
        session.prefersEphemeralWebBrowserSession = false
        webAuthSession = session
        session.start()
    }

    private func exchangeCode(_ code: String) async {
        isLoading = true
        defer { isLoading = false }

        var request = URLRequest(url: URL(string: tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "grant_type=authorization_code",
            "client_id=\(clientId)",
            "client_secret=\(clientSecret)",
            "redirect_uri=\(redirectURI)",
            "code=\(code)"
        ].joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                errorMessage = "Token exchange failed (HTTP \(statusCode))"
                print("HomeConnect: token exchange failed — \(String(data: data, encoding: .utf8) ?? "")")
                return
            }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let accessToken = json["access_token"] as? String ?? ""
            let refreshToken = json["refresh_token"] as? String ?? ""
            let expiresIn = json["expires_in"] as? Int ?? 86400

            tokens = HomeConnectTokens(
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn - 60))
            )
            errorMessage = nil
            print("HomeConnect: OAuth complete, token expires in \(expiresIn)s")

            await fetchAppliances()
            startPolling()
        } catch {
            errorMessage = "Token exchange error: \(error.localizedDescription)"
        }
    }

    func refreshTokenIfNeeded() async -> Bool {
        guard let currentTokens = tokens else { return false }
        guard Date() >= currentTokens.expiresAt else { return true }

        var request = URLRequest(url: URL(string: tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "grant_type=refresh_token",
            "client_id=\(clientId)",
            "client_secret=\(clientSecret)",
            "refresh_token=\(currentTokens.refreshToken)"
        ].joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                print("HomeConnect: token refresh failed")
                tokens = nil
                return false
            }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            tokens = HomeConnectTokens(
                accessToken: json["access_token"] as? String ?? "",
                refreshToken: json["refresh_token"] as? String ?? currentTokens.refreshToken,
                expiresAt: Date().addingTimeInterval(TimeInterval((json["expires_in"] as? Int ?? 86400) - 60))
            )
            return true
        } catch {
            print("HomeConnect: token refresh error — \(error)")
            return false
        }
    }

    func unlink() {
        tokens = nil
        sseTask?.cancel()
        sseTask = nil
        pollTimer?.invalidate()
        pollTimer = nil
        dishwashers = []
        KeychainHelper.delete(for: "hc_tokens")
    }

    // MARK: - API Requests

    private func apiRequest(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> [String: Any] {
        guard await refreshTokenIfNeeded(), let tok = tokens else {
            throw URLError(.userAuthenticationRequired)
        }

        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        request.httpMethod = method
        request.setValue("Bearer \(tok.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.bsh.sdk.v1+json", forHTTPHeaderField: "Accept")

        if let body {
            request.setValue("application/vnd.bsh.sdk.v1+json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw URLError(.badServerResponse, userInfo: ["statusCode": code])
        }

        if data.isEmpty { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: - Appliance Discovery

    func fetchAppliances() async {
        do {
            let json = try await apiRequest("/api/homeappliances")
            guard let items = (json["data"] as? [String: Any])?["homeappliances"] as? [[String: Any]] else {
                print("HomeConnect: no appliances found")
                return
            }

            // Find ALL dishwashers
            var found: [DishwasherStatus] = []
            for appliance in items {
                let type = appliance["type"] as? String ?? ""
                let haId = appliance["haId"] as? String ?? ""
                let name = appliance["name"] as? String ?? "Dishwasher"
                let connected = appliance["connected"] as? Bool ?? false

                print("HomeConnect: appliance '\(name)' type=\(type) id=\(haId) connected=\(connected)")

                if type == "Dishwasher" {
                    // Preserve existing state if we already have this appliance
                    if let existing = dishwashers.first(where: { $0.applianceId == haId }) {
                        var updated = existing
                        updated.applianceName = name
                        updated.connected = connected
                        found.append(updated)
                    } else {
                        var status = DishwasherStatus()
                        status.applianceId = haId
                        status.applianceName = name
                        status.connected = connected
                        found.append(status)
                    }
                }
            }

            dishwashers = found
            print("HomeConnect: found \(found.count) dishwasher(s) among \(items.count) appliances")

            // Fetch status for each
            for i in 0..<dishwashers.count {
                await fetchStatus(for: i)
            }
        } catch {
            errorMessage = "Failed to fetch appliances"
            print("HomeConnect: fetchAppliances error — \(error)")
        }
    }

    // MARK: - Status Fetching

    /// Fetch status for a specific dishwasher by index
    func fetchStatus(for index: Int) async {
        guard index < dishwashers.count else { return }
        let applianceId = dishwashers[index].applianceId
        guard !applianceId.isEmpty else { return }

        do {
            // Fetch status
            let statusJson = try await apiRequest("/api/homeappliances/\(applianceId)/status")
            if let items = (statusJson["data"] as? [String: Any])?["status"] as? [[String: Any]] {
                for item in items {
                    let key = item["key"] as? String ?? ""
                    let value = item["value"] as? String ?? ""
                    switch key {
                    case "BSH.Common.Status.OperationState":
                        dishwashers[index].operationState = DishwasherOperationState(rawValue: value) ?? .unknown
                    case "BSH.Common.Status.DoorState":
                        dishwashers[index].doorState = DishwasherDoorState(rawValue: value) ?? .unknown
                    case "BSH.Common.Status.RemoteControlActive":
                        dishwashers[index].remoteControlActive = (item["value"] as? Bool) ?? false
                    default:
                        break
                    }
                }
            }

            // Fetch active program (if any)
            if dishwashers[index].operationState.isActive {
                do {
                    let progJson = try await apiRequest("/api/homeappliances/\(applianceId)/programs/active")
                    if let data = progJson["data"] as? [String: Any] {
                        dishwashers[index].activeProgram = data["key"] as? String
                        if let options = data["options"] as? [[String: Any]] {
                            for opt in options {
                                let key = opt["key"] as? String ?? ""
                                switch key {
                                case "BSH.Common.Option.RemainingProgramTime":
                                    dishwashers[index].remainingTime = opt["value"] as? Int
                                case "BSH.Common.Option.ProgramProgress":
                                    dishwashers[index].progress = opt["value"] as? Int
                                default:
                                    break
                                }
                            }
                        }
                    }
                } catch {
                    // No active program is expected when not running
                    dishwashers[index].activeProgram = nil
                    dishwashers[index].remainingTime = nil
                    dishwashers[index].progress = nil
                }
            } else {
                dishwashers[index].activeProgram = nil
                dishwashers[index].remainingTime = nil
                dishwashers[index].progress = nil
            }

            dishwashers[index].connected = true
            errorMessage = nil

            // Check for cycle completion transition
            let dw = dishwashers[index]
            let prev = previousStates[dw.applianceId]
            if let prev, prev.isActive, dw.operationState == .finished {
                NotificationManager.shared.notifyCycleComplete(appliance: "Dishwasher", id: dw.applianceId)
            }
            previousStates[dw.applianceId] = dw.operationState
        } catch {
            print("HomeConnect: fetchStatus error for \(dishwashers[index].applianceName) — \(error)")
        }
    }

    /// Fetch status for all dishwashers
    func fetchAllStatuses() async {
        for i in 0..<dishwashers.count {
            await fetchStatus(for: i)
        }
    }

    // MARK: - Remote Start

    func fetchAvailablePrograms(for applianceId: String) async -> [DishwasherProgram] {
        do {
            let json = try await apiRequest("/api/homeappliances/\(applianceId)/programs/available")
            guard let programs = (json["data"] as? [String: Any])?["programs"] as? [[String: Any]] else {
                return []
            }
            let result = programs.compactMap { prog -> DishwasherProgram? in
                guard let key = prog["key"] as? String else { return nil }
                return DishwasherProgram(key: key, name: DishwasherProgram.displayName(for: key))
            }
            availablePrograms[applianceId] = result
            return result
        } catch {
            print("HomeConnect: fetchAvailablePrograms error — \(error)")
            return []
        }
    }

    func startProgram(_ programKey: String, for applianceId: String) async -> Bool {
        isStarting = true
        startError = nil
        defer { isStarting = false }

        guard let dw = dishwashers.first(where: { $0.applianceId == applianceId }),
              dw.canRemoteStart else {
            startError = "Dishwasher is not ready for remote start"
            return false
        }

        do {
            let body: [String: Any] = [
                "data": [
                    "key": programKey,
                    "options": [] as [[String: Any]]
                ] as [String: Any]
            ]
            _ = try await apiRequest(
                "/api/homeappliances/\(applianceId)/programs/active",
                method: "PUT",
                body: body
            )

            // Refresh status after starting
            if let idx = dishwashers.firstIndex(where: { $0.applianceId == applianceId }) {
                await fetchStatus(for: idx)
            }
            return true
        } catch {
            let nsError = error as NSError
            let code = nsError.userInfo["statusCode"] as? Int
            if code == 403 {
                startError = "Permission denied. Re-link Home Connect in Settings to grant control permissions."
            } else {
                startError = "Failed to start: \(error.localizedDescription)"
            }
            print("HomeConnect: startProgram error — \(error)")
            return false
        }
    }

    // MARK: - SSE Event Stream

    func startEventStream() {
        guard let tok = tokens else { return }
        sseTask?.cancel()

        // Use the global events endpoint to get events for ALL appliances
        var request = URLRequest(url: URL(string: "\(baseURL)/api/homeappliances/events")!)
        request.setValue("Bearer \(tok.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 300

        let session = URLSession(configuration: .default)
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self, let data else { return }
            let text = String(data: data, encoding: .utf8) ?? ""
            self.parseSSEEvents(text)
        }
        task.resume()
        sseTask = task
        print("HomeConnect: SSE stream started for all appliances")
    }

    private func parseSSEEvents(_ text: String) {
        let lines = text.components(separatedBy: "\n")
        var eventType = ""
        var eventData = ""

        for line in lines {
            if line.hasPrefix("event: ") {
                eventType = String(line.dropFirst(7))
            } else if line.hasPrefix("data: ") {
                eventData = String(line.dropFirst(6))
            } else if line.isEmpty && !eventData.isEmpty {
                handleSSEEvent(type: eventType, data: eventData)
                eventType = ""
                eventData = ""
            }
        }
    }

    private func handleSSEEvent(type: String, data: String) {
        guard let jsonData = data.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else { return }

        // Try to determine which appliance this event belongs to
        let haId = json["haId"] as? String ?? ""

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            // Find the matching dishwasher (or default to first if no haId)
            guard let idx = self.dishwashers.firstIndex(where: { $0.applianceId == haId }) ?? self.dishwashers.indices.first else { return }

            let prevState = self.previousStates[self.dishwashers[idx].applianceId]

            for item in items {
                let key = item["key"] as? String ?? ""
                switch key {
                case "BSH.Common.Status.OperationState":
                    if let val = item["value"] as? String {
                        self.dishwashers[idx].operationState = DishwasherOperationState(rawValue: val) ?? .unknown
                    }
                case "BSH.Common.Status.DoorState":
                    if let val = item["value"] as? String {
                        self.dishwashers[idx].doorState = DishwasherDoorState(rawValue: val) ?? .unknown
                    }
                case "BSH.Common.Option.RemainingProgramTime":
                    self.dishwashers[idx].remainingTime = item["value"] as? Int
                case "BSH.Common.Option.ProgramProgress":
                    self.dishwashers[idx].progress = item["value"] as? Int
                default:
                    break
                }
            }

            // Check for cycle completion transition
            let dw = self.dishwashers[idx]
            if let prevState, prevState.isActive, dw.operationState == .finished {
                NotificationManager.shared.notifyCycleComplete(appliance: "Dishwasher", id: dw.applianceId)
            }
            self.previousStates[dw.applianceId] = dw.operationState
        }
    }

    // MARK: - Polling Fallback

    func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { await self?.fetchAllStatuses() }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        sseTask?.cancel()
        sseTask = nil
    }

    // MARK: - Resume (app foreground)

    func resume() {
        guard isLinked else { return }
        Task {
            if dishwashers.isEmpty || dishwashers.allSatisfy({ $0.applianceId.isEmpty }) {
                // Need to rediscover appliances (e.g., after app restart)
                await fetchAppliances()
            } else {
                await fetchAllStatuses()
            }
            startPolling()
        }
    }

    // MARK: - Token Persistence

    private func saveTokens() {
        guard let tokens else {
            KeychainHelper.delete(for: "hc_tokens")
            return
        }
        KeychainHelper.save(tokens, for: "hc_tokens")
    }

    private func loadTokens() {
        // Migrate from UserDefaults if present
        if let data = UserDefaults.standard.data(forKey: "hc_tokens"),
           let saved = try? JSONDecoder().decode(HomeConnectTokens.self, from: data) {
            tokens = saved
            UserDefaults.standard.removeObject(forKey: "hc_tokens")
            return
        }
        tokens = KeychainHelper.load(HomeConnectTokens.self, for: "hc_tokens")
    }
}
