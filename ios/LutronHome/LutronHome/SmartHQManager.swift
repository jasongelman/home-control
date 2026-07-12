import Foundation
import AuthenticationServices
import Observation

// MARK: - Models

enum LaundryMachineState: Int {
    case idle = 0
    case standby = 1
    case run = 2
    case pause = 3
    case endOfCycle = 4
    case dsmDelayRun = 5
    case delayRun = 6
    case delayPause = 7
    case drainTimeout = 8

    var label: String {
        switch self {
        case .idle: return "Off"
        case .standby: return "Standby"
        case .run: return "Running"
        case .pause: return "Paused"
        case .endOfCycle: return "Cycle Complete"
        case .dsmDelayRun, .delayRun: return "Delayed Start"
        case .delayPause: return "Delay Paused"
        case .drainTimeout: return "Drain Timeout"
        }
    }

    var icon: String {
        switch self {
        case .idle: return "power"
        case .standby: return "powersleep"
        case .run: return "play.circle.fill"
        case .pause: return "pause.circle.fill"
        case .endOfCycle: return "checkmark.circle.fill"
        case .dsmDelayRun, .delayRun: return "clock"
        case .delayPause: return "clock.badge.exclamationmark"
        case .drainTimeout: return "exclamationmark.triangle.fill"
        }
    }

    var isActive: Bool {
        switch self {
        case .run, .pause, .delayRun, .dsmDelayRun, .delayPause: return true
        default: return false
        }
    }

    var isRunning: Bool { self == .run }
}

/// Washer-specific cycle types
enum WasherCycle: String {
    case normal = "Normal"
    case delicates = "Delicates"
    case heavy = "Heavy Duty"
    case quick = "Quick Wash"
    case sanitize = "Sanitize"
    case whites = "Whites"
    case towels = "Towels"
    case coldWash = "Cold Wash"
    case rinseAndSpin = "Rinse & Spin"
    case drainAndSpin = "Drain & Spin"
    case unknown = "Unknown"
}

/// Dryer-specific cycle types
enum DryerCycle: String {
    case cottons = "Cottons"
    case casuals = "Casuals"
    case delicates = "Delicates"
    case heavy = "Heavy Duty"
    case quick = "Quick Dry"
    case towels = "Towels"
    case sanitize = "Sanitize"
    case airFluff = "Air Fluff"
    case steam = "Steam"
    case unknown = "Unknown"
}

struct LaundryApplianceStatus: Identifiable {
    var id: String { applianceId }
    var applianceId: String = ""
    var applianceName: String = ""
    var applianceType: String = ""  // "Washer" or "Dryer"
    var online: Bool = false

    var machineState: LaundryMachineState = .idle
    var remainingMinutes: Int? = nil
    var cycleName: String? = nil
    var doorLocked: Bool = false

    // Washer-specific
    var soilLevel: String? = nil
    var washTemp: String? = nil
    var spinSpeed: String? = nil

    // Dryer-specific
    var dryLevel: String? = nil
    var dryTemp: String? = nil

    var remainingTimeFormatted: String? {
        guard let minutes = remainingMinutes, minutes > 0 else { return nil }
        let h = minutes / 60
        let m = minutes % 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    var isWasher: Bool { applianceType.lowercased().contains("washer") }
    var isDryer: Bool { applianceType.lowercased().contains("dryer") }

    var typeIcon: String {
        if isWasher { return "washer" }
        if isDryer { return "dryer" }
        return "washer"
    }
}

/// Lightweight cached appliance identity (ID, name, type) for instant startup.
private struct CachedAppliance: Codable {
    let applianceId: String
    let applianceName: String
    let applianceType: String
}

struct SmartHQTokens: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
}

// MARK: - ERD Constants

/// GE ERD (Event Report Data) codes for laundry appliances
private enum ERDCode {
    static let machineState     = "0x2000"
    static let machineSubCycle  = "0x2001"
    static let endOfCycle       = "0x2002"
    static let cycleSelected    = "0x2003"
    static let timeRemaining    = "0x2007"
    static let doorLock         = "0x200A"
    static let operatingMode    = "0x200B"
    static let soilLevel        = "0x2010"
    static let washTemp         = "0x2011"
    static let spinSpeed        = "0x2012"
    static let dryLevel         = "0x2013"
    static let dryTemp          = "0x2014"
}

// MARK: - Manager

@Observable
class SmartHQManager: @unchecked Sendable {
    var isLinked: Bool { tokens != nil }
    var appliances: [LaundryApplianceStatus] = []
    var isLoading = false
    var errorMessage: String?

    private var previousStates: [String: LaundryMachineState] = [:]
    private static let appliancesCacheKey = "smarthq_appliances_cache"


    /// Convenience: first washer
    var washer: LaundryApplianceStatus? { appliances.first(where: { $0.isWasher }) }
    /// Convenience: first dryer
    var dryer: LaundryApplianceStatus? { appliances.first(where: { $0.isDryer }) }

    // GE SmartHQ / Brillion OAuth2 — authorization_code flow.
    // Community-reverse-engineered from the GE SmartHQ mobile app; same values as the gehome SDK.
    // Standing exception under CLAUDE.md § "Never commit secrets" rule 1.
    private let loginBase    = "https://accounts.brillion.geappliances.com"
    private let apiBase      = "https://api.brillion.geappliances.com"
    private let clientId     = "564c31616c4f7474434b307435412b4d2f6e7672"
    private let clientSecret = "6476512b5246446d452f697154444941387052645938466e5671746e5847593d"
    private let redirectURI  = "brillion.4e617a766474657344444e562b5935566e51324a://oauth/redirect"

    private var tokens: SmartHQTokens? {
        didSet { saveTokens() }
    }
    private var webAuthSession: ASWebAuthenticationSession?
    private var pollTimer: Timer?

    init() {
        loadTokens()
        // Load cached appliance list for instant startup
        if let data = UserDefaults.standard.data(forKey: Self.appliancesCacheKey),
           let cached = try? JSONDecoder().decode([CachedAppliance].self, from: data) {
            appliances = cached.map { c in
                var s = LaundryApplianceStatus()
                s.applianceId = c.applianceId
                s.applianceName = c.applianceName
                s.applianceType = c.applianceType
                return s
            }
        }
    }

    // MARK: - Authentication (OAuth2 authorization_code via ASWebAuthenticationSession)

    func startOAuth(from anchor: ASWebAuthenticationPresentationContextProviding) {
        var components = URLComponents(string: "\(loginBase)/oauth2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id",     value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri",  value: redirectURI),
            URLQueryItem(name: "access_type",   value: "offline"),
        ]

        guard let authURL = components.url else { return }

        let callbackScheme = String(redirectURI.split(separator: ":").first ?? "")

        let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: callbackScheme) { [weak self] callbackURL, error in
            guard let self else { return }
            if let error {
                self.errorMessage = "Authentication cancelled or failed: \(error.localizedDescription)"
                return
            }
            guard let callbackURL,
                  let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
                              .queryItems?.first(where: { $0.name == "code" })?.value
            else {
                self.errorMessage = "No authorization code in callback"
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

        var request = URLRequest(url: URL(string: "\(loginBase)/oauth2/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        // Basic Auth header (matches gehomesdk)
        let credentials = "\(clientId):\(clientSecret)"
        if let credData = credentials.data(using: .utf8) {
            request.setValue("Basic \(credData.base64EncodedString())", forHTTPHeaderField: "Authorization")
        }

        let body = [
            "grant_type=authorization_code",
            "code=\(code)",
            "client_id=\(clientId)",
            "client_secret=\(clientSecret)",
            "redirect_uri=\(redirectURI.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? redirectURI)",
        ].joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }

            if http.statusCode == 200 {
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                let expiresIn = json["expires_in"] as? Int ?? 3600
                tokens = SmartHQTokens(
                    accessToken:  json["access_token"]  as? String ?? "",
                    refreshToken: json["refresh_token"] as? String ?? "",
                    expiresAt:    Date().addingTimeInterval(TimeInterval(expiresIn - 60))
                )
                errorMessage = nil
                print("SmartHQ: OAuth successful, token expires in \(expiresIn)s")
                await fetchAppliances()
                startPolling()
            } else {
                let bodyText = String(data: data, encoding: .utf8) ?? ""
                errorMessage = "Token exchange failed (HTTP \(http.statusCode))"
                print("SmartHQ: token exchange failed — \(bodyText)")
            }
        } catch {
            errorMessage = "Token exchange error: \(error.localizedDescription)"
            print("SmartHQ: token exchange error — \(error)")
        }
    }

    func refreshTokenIfNeeded() async -> Bool {
        guard let currentTokens = tokens else { return false }
        guard Date() >= currentTokens.expiresAt else { return true }

        var request = URLRequest(url: URL(string: "\(loginBase)/oauth2/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        // Basic Auth header (matches gehomesdk)
        let credentials = "\(clientId):\(clientSecret)"
        if let credData = credentials.data(using: .utf8) {
            request.setValue("Basic \(credData.base64EncodedString())", forHTTPHeaderField: "Authorization")
        }

        let body = [
            "grant_type=refresh_token",
            "refresh_token=\(currentTokens.refreshToken)",
            "client_id=\(clientId)",
            "client_secret=\(clientSecret)",
            "redirect_uri=\(redirectURI.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? redirectURI)",
        ].joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                print("SmartHQ: token refresh failed")
                tokens = nil
                return false
            }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            tokens = SmartHQTokens(
                accessToken: json["access_token"] as? String ?? "",
                refreshToken: json["refresh_token"] as? String ?? currentTokens.refreshToken,
                expiresAt: Date().addingTimeInterval(TimeInterval((json["expires_in"] as? Int ?? 3600) - 60))
            )
            return true
        } catch {
            print("SmartHQ: token refresh error — \(error)")
            return false
        }
    }

    func unlink() {
        tokens = nil
        pollTimer?.invalidate()
        pollTimer = nil
        appliances = []
        webAuthSession?.cancel()
        webAuthSession = nil
        KeychainHelper.delete(for: "ge_tokens")
        KeychainHelper.delete(for: "ge_email")
        KeychainHelper.delete(for: "ge_password")
    }

    // MARK: - API Requests

    private func apiRequest(_ path: String, method: String = "GET") async throws -> Any {
        guard await refreshTokenIfNeeded(), let tok = tokens else {
            throw URLError(.userAuthenticationRequired)
        }

        // URL-encode path components (e.g. appliance JIDs containing @)
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        guard let url = URL(string: "\(apiBase)\(encodedPath)") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(tok.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? ""
            print("SmartHQ: API \(method) \(path) failed (\(code)): \(body.prefix(300))")
            throw URLError(.badServerResponse, userInfo: ["statusCode": code])
        }

        return try JSONSerialization.jsonObject(with: data)
    }

    // MARK: - Appliance Discovery

    func fetchAppliances() async {
        do {
            let json = try await apiRequest("/v1/appliance")
            guard let items = json as? [[String: Any]] else {
                // Try nested format
                if let dict = json as? [String: Any], let items = dict["items"] as? [[String: Any]] {
                    parseAppliances(items)
                } else {
                    print("SmartHQ: unexpected appliance response format")
                }
                return
            }
            parseAppliances(items)
        } catch {
            errorMessage = "Failed to fetch appliances"
            print("SmartHQ: fetchAppliances error — \(error)")
        }
    }

    private func parseAppliances(_ items: [[String: Any]]) {
        var found: [LaundryApplianceStatus] = []

        for appliance in items {
            let type = appliance["type"] as? String ?? ""
            let jid = appliance["jid"] as? String ?? appliance["applianceId"] as? String ?? ""
            let nickname = appliance["nickname"] as? String ?? appliance["name"] as? String ?? type
            let online = appliance["online"] as? Bool ?? false

            print("SmartHQ: appliance '\(nickname)' type=\(type) id=\(jid) online=\(online)")

            let lowerType = type.lowercased()
            if lowerType.contains("washer") || lowerType.contains("dryer") {
                // Preserve existing state if we already have this appliance
                if let existing = appliances.first(where: { $0.applianceId == jid }) {
                    var updated = existing
                    updated.applianceName = nickname
                    updated.online = online
                    updated.applianceType = type
                    found.append(updated)
                } else {
                    var status = LaundryApplianceStatus()
                    status.applianceId = jid
                    status.applianceName = nickname
                    status.applianceType = type
                    status.online = online
                    found.append(status)
                }
            }
        }

        appliances = found
        print("SmartHQ: found \(found.count) laundry appliance(s) among \(items.count) total appliances")

        // Cache appliance identities for instant startup
        let cached = found.map { CachedAppliance(applianceId: $0.applianceId, applianceName: $0.applianceName, applianceType: $0.applianceType) }
        if let data = try? JSONEncoder().encode(cached) {
            UserDefaults.standard.set(data, forKey: Self.appliancesCacheKey)
        }

        Task {
            for i in 0..<appliances.count {
                await fetchERD(for: i)
            }
        }
    }

    // MARK: - ERD Status Fetching

    func fetchERD(for index: Int) async {
        guard index < appliances.count else { return }
        let applianceId = appliances[index].applianceId
        guard !applianceId.isEmpty else { return }
        guard appliances[index].online else { return }

        do {
            let json = try await apiRequest("/v1/appliance/\(applianceId)/erd")

            // ERD response can be an array of {erd: "0x...", value: "..."} or a dict
            var erdMap: [String: String] = [:]

            if let items = json as? [[String: Any]] {
                for item in items {
                    let erd = item["erd"] as? String ?? item["key"] as? String ?? ""
                    let value = item["value"] as? String ?? ""
                    if !erd.isEmpty { erdMap[erd.lowercased()] = value }
                }
            } else if let dict = json as? [String: Any] {
                // Might be nested: { "items": [...] } or flat ERD map
                if let items = dict["items"] as? [[String: Any]] {
                    for item in items {
                        let erd = item["erd"] as? String ?? item["key"] as? String ?? ""
                        let value = item["value"] as? String ?? ""
                        if !erd.isEmpty { erdMap[erd.lowercased()] = value }
                    }
                } else {
                    for (key, val) in dict {
                        if let strVal = val as? String {
                            erdMap[key.lowercased()] = strVal
                        }
                    }
                }
            }

            // Parse machine state
            if let stateHex = erdMap[ERDCode.machineState.lowercased()] {
                let stateValue = parseHexInt(stateHex)
                appliances[index].machineState = LaundryMachineState(rawValue: stateValue) ?? .idle
            }

            // Parse time remaining (2 bytes = minutes)
            if let timeHex = erdMap[ERDCode.timeRemaining.lowercased()] {
                let minutes = parseHexInt(timeHex)
                appliances[index].remainingMinutes = minutes > 0 ? minutes : nil
            }

            // Parse door lock
            if let lockHex = erdMap[ERDCode.doorLock.lowercased()] {
                appliances[index].doorLocked = parseHexInt(lockHex) != 0
            }

            // Parse cycle name
            if let cycleHex = erdMap[ERDCode.cycleSelected.lowercased()] {
                appliances[index].cycleName = parseCycleName(cycleHex, isWasher: appliances[index].isWasher)
            }

            // Washer-specific
            if appliances[index].isWasher {
                if let hex = erdMap[ERDCode.soilLevel.lowercased()] { appliances[index].soilLevel = parseSoilLevel(hex) }
                if let hex = erdMap[ERDCode.washTemp.lowercased()] { appliances[index].washTemp = parseWashTemp(hex) }
                if let hex = erdMap[ERDCode.spinSpeed.lowercased()] { appliances[index].spinSpeed = parseSpinSpeed(hex) }
            }

            // Dryer-specific
            if appliances[index].isDryer {
                if let hex = erdMap[ERDCode.dryLevel.lowercased()] { appliances[index].dryLevel = parseDryLevel(hex) }
                if let hex = erdMap[ERDCode.dryTemp.lowercased()] { appliances[index].dryTemp = parseDryTemp(hex) }
            }

            appliances[index].online = true
            errorMessage = nil

            // Check for cycle completion transition
            let app = appliances[index]
            let prev = previousStates[app.id]
            if let prev, prev.isActive, app.machineState == .endOfCycle {
                let name = app.isWasher ? "Washer" : "Dryer"
                NotificationManager.shared.notifyCycleComplete(appliance: name, id: app.id)
            }
            previousStates[app.id] = app.machineState

            print("SmartHQ: fetched ERD for \(appliances[index].applianceName) — state=\(appliances[index].machineState.label)")
        } catch {
            print("SmartHQ: fetchERD error for \(appliances[index].applianceName) — \(error)")
        }
    }

    func fetchAllStatuses() async {
        for i in 0..<appliances.count {
            await fetchERD(for: i)
        }
    }

    // MARK: - Polling

    func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { await self?.fetchAllStatuses() }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Resume

    func resume() {
        guard isLinked else { return }
        Task {
            if appliances.isEmpty {
                await fetchAppliances()
            } else {
                await fetchAllStatuses()
            }
            startPolling()
        }
    }

    // MARK: - Hex Parsing Helpers

    private func parseHexInt(_ hex: String) -> Int {
        let cleaned = hex.replacingOccurrences(of: "0x", with: "")
            .replacingOccurrences(of: " ", with: "")
        return Int(cleaned, radix: 16) ?? 0
    }

    private func parseCycleName(_ hex: String, isWasher: Bool) -> String? {
        let value = parseHexInt(hex)
        guard value > 0 else { return nil }

        // Common cycle mappings (simplified from gehome)
        if isWasher {
            switch value {
            case 0: return nil
            case 1: return "Normal"
            case 2: return "Heavy Duty"
            case 3: return "Delicates"
            case 4: return "Quick Wash"
            case 5: return "Towels"
            case 6: return "Sanitize"
            case 7: return "Whites"
            case 8: return "Cold Wash"
            case 9: return "Rinse & Spin"
            case 10: return "Drain & Spin"
            default: return "Cycle \(value)"
            }
        } else {
            switch value {
            case 0: return nil
            case 1: return "Cottons"
            case 2: return "Casuals"
            case 3: return "Delicates"
            case 4: return "Heavy Duty"
            case 5: return "Quick Dry"
            case 6: return "Towels"
            case 7: return "Sanitize"
            case 8: return "Air Fluff"
            case 9: return "Steam"
            default: return "Cycle \(value)"
            }
        }
    }

    private func parseSoilLevel(_ hex: String) -> String? {
        switch parseHexInt(hex) {
        case 1: return "Extra Light"
        case 2: return "Light"
        case 3: return "Normal"
        case 4: return "Heavy"
        case 5: return "Extra Heavy"
        default: return nil
        }
    }

    private func parseWashTemp(_ hex: String) -> String? {
        switch parseHexInt(hex) {
        case 1: return "Tap Cold"
        case 2: return "Cold"
        case 3: return "Cool"
        case 4: return "Colors"
        case 5: return "Warm"
        case 6: return "Hot"
        default: return nil
        }
    }

    private func parseSpinSpeed(_ hex: String) -> String? {
        switch parseHexInt(hex) {
        case 1: return "No Spin"
        case 2: return "Low"
        case 3: return "Medium"
        case 4: return "High"
        case 5: return "Extra High"
        default: return nil
        }
    }

    private func parseDryLevel(_ hex: String) -> String? {
        switch parseHexInt(hex) {
        case 1: return "Damp"
        case 2: return "Less Dry"
        case 3: return "Dry"
        case 4: return "More Dry"
        case 5: return "Extra Dry"
        default: return nil
        }
    }

    private func parseDryTemp(_ hex: String) -> String? {
        switch parseHexInt(hex) {
        case 1: return "No Heat"
        case 2: return "Low"
        case 3: return "Medium"
        case 4: return "Medium High"
        case 5: return "High"
        default: return nil
        }
    }

    // MARK: - Token Persistence

    private func saveTokens() {
        guard let tokens else {
            KeychainHelper.delete(for: "ge_tokens")
            return
        }
        KeychainHelper.save(tokens, for: "ge_tokens")
    }

    private func loadTokens() {
        tokens = KeychainHelper.load(SmartHQTokens.self, for: "ge_tokens")
    }
}
