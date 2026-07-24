import Foundation
import AuthenticationServices
import Observation
import CryptoKit
import Security

// MARK: - Models

enum RefrigeratorMode: String, Codable {
    case normal, vacation, sabbath, night, unknown

    var label: String {
        switch self {
        case .normal:   return "Normal"
        case .vacation: return "Vacation"
        case .sabbath:  return "Sabbath"
        case .night:    return "Night"
        case .unknown:  return "Unknown"
        }
    }
}

enum OvenMode: String, Codable {
    case off, bake, broil, convection, convection_roast
    case roast, warm, proof, dehydrate, stone
    case gourmet, gourmet_plus, self_clean, sous_vide
    case steam, convection_steam, convection_humid
    case unknown

    var label: String {
        rawValue.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

struct SubZeroRefrigerator: Identifiable, Codable {
    var id: String { applianceId }
    let applianceId: String
    let applianceName: String
    let model: String
    let online: Bool
    let fridgeTemp: Double?
    let freezerTemp: Double?
    let fridgeSetpoint: Double?
    let freezerSetpoint: Double?
    let crisperSetpoint: Double?
    let fridgeDoorOpen: Bool
    let freezerDoorOpen: Bool
    let iceMakerOn: Bool
    let maxIceOn: Bool
    let mode: RefrigeratorMode
    let nightMode: Bool
    let lightOn: Bool
    let waterFilterPct: Double?
    let airPurificationPct: Double?
    let humidityControl: String?
    let lastUpdated: Date
}

struct WolfOven: Identifiable, Codable {
    var id: String { applianceId }
    let applianceId: String
    let applianceName: String
    let model: String
    let online: Bool
    let unitOn: Bool
    let currentTemp: Double?
    let targetTemp: Double?
    let cookMode: OvenMode
    let probeTemp: Double?
    let probeTargetTemp: Double?
    let timerRemaining: Int?
    let remoteReady: Bool
    let lightOn: Bool
    let lastUpdated: Date

    var timerFormatted: String? {
        guard let seconds = timerRemaining, seconds > 0 else { return nil }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}

// MARK: - Keychain

private enum SubZeroKeychain {
    private static let service = "com.jasongelman.LutronHome.subzero"

    static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func deleteAll() {
        for key in ["accessToken", "refreshToken", "tokenExpiresAt", "subscriptionKey", "userId"] {
            delete(key: key)
        }
    }
}

// MARK: - Manager

@Observable
class SubZeroManager: @unchecked Sendable {
    var refrigerators: [SubZeroRefrigerator] = []
    var ovens: [WolfOven] = []
    var isLoading = false
    var errorMessage: String?

    var isLinked: Bool {
        SubZeroKeychain.load(key: "accessToken") != nil
    }

    // Azure B2C (production)
    // Community-reverse-engineered from the Sub-Zero Group Owner's App; same B2C tenant used by all consumer app instances.
    private static let b2cBase = "https://login.subzero-wolf.com/subzerob2cprd.onmicrosoft.com/b2c_1a_signup_signin/oauth2/v2.0"
    private static let clientId = "6eefabd0-49a3-4b92-b329-81b9f638e940"
    private static let apiBase = "https://prod.iot.subzero.com"
    private static let defaultSubKey = "0e85d3216b604e51a711f147c09e228a"
    // Different APIM API products may require different subscription keys
    private static let allSubKeys = [
        "0e85d3216b604e51a711f147c09e228a",
        "16ca8ba0ad3f4eddaffcf8520454c2c9",
        "180fd5156a734e69b355970c9615403c",
        "25126214b7b7408283baefaec38010de",
        "a93bb184cbf944c7af266d5fa2680652",
        "e88bf0b60baf441583f822fa9ba9c895",
    ]
    private static var directMethodSubKey: String?
    // Must use the redirect URI registered in Sub-Zero's B2C app registration
    private static let redirectScheme = "com.szg.szgdigitalproductexperience"
    private static let redirectURI = "com.szg.szgdigitalproductexperience://oauth/redirect"
    private static let cacheKey = "subzero_appliances_cache"

    // The SignalR/"modern" APIM product key — required for /signal-r/negotiateUser.
    // This is a DIFFERENT product than the consumerapp key used elsewhere. Confirmed by live probe.
    private static let signalRSubKey = "e88bf0b60baf441583f822fa9ba9c895"
    private static let recordSeparator = "\u{1e}" // SignalR JSON protocol record separator

    /// Metadata for a discovered appliance, keyed by the hex device `id` (== SignalR DeviceId).
    private struct DeviceMeta {
        var name: String
        var model: String
        var online: Bool
        var isOven: Bool
    }

    @ObservationIgnored
    private var webAuthSession: ASWebAuthenticationSession?
    @ObservationIgnored
    private var codeVerifier: String?
    @ObservationIgnored
    private var pollTimer: Timer?
    // Live SignalR state, keyed by hex deviceId.
    @ObservationIgnored
    private var deviceProperties: [String: [String: Any]] = [:]
    @ObservationIgnored
    private var deviceMeta: [String: DeviceMeta] = [:]
    @ObservationIgnored
    private var webSocketTask: URLSessionWebSocketTask?
    @ObservationIgnored
    private var signalRHandshaken = false
    @ObservationIgnored
    private var wsReconnectPending = false
    @ObservationIgnored
    private var wsGeneration = 0

    init() {
        loadCache()
    }

    // MARK: - OAuth2 Authorization Code + PKCE

    func startOAuth(from anchor: ASWebAuthenticationPresentationContextProviding) {
        let verifier = generateCodeVerifier()
        codeVerifier = verifier
        let challenge = generateCodeChallenge(from: verifier)

        var components = URLComponents(string: "\(Self.b2cBase)/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "scope", value: "\(Self.clientId) openid offline_access"),
            URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]

        let session = ASWebAuthenticationSession(
            url: components.url!,
            callbackURLScheme: Self.redirectScheme
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
        guard let verifier = codeVerifier else {
            errorMessage = "No code verifier"
            return
        }
        isLoading = true
        defer { isLoading = false }

        var request = URLRequest(url: URL(string: "\(Self.b2cBase)/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var bodyComponents = URLComponents()
        bodyComponents.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "client_id", value: Self.clientId),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "code_verifier", value: verifier),
            URLQueryItem(name: "scope", value: "\(Self.clientId) openid offline_access"),
        ]
        request.httpBody = bodyComponents.percentEncodedQuery?.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                errorMessage = "Token exchange failed (HTTP \(status))"
                print("SubZero: token exchange failed — \(String(data: data, encoding: .utf8) ?? "")")
                return
            }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let accessToken = json["access_token"] as? String ?? ""
            let refreshToken = json["refresh_token"] as? String ?? ""
            let expiresIn = json["expires_in"] as? Int ?? 3600

            SubZeroKeychain.save(key: "accessToken", value: accessToken)
            SubZeroKeychain.save(key: "refreshToken", value: refreshToken)
            SubZeroKeychain.save(key: "tokenExpiresAt", value: "\(Date().addingTimeInterval(TimeInterval(expiresIn - 60)).timeIntervalSince1970)")
            if let userId = Self.extractUserId(from: accessToken) {
                SubZeroKeychain.save(key: "userId", value: userId)
                print("SubZero: extracted userId \(userId.prefix(8))…")
            }
            codeVerifier = nil
            errorMessage = nil
            print("SubZero: OAuth complete, token expires in \(expiresIn)s")

            await fetchAppliances()
            startPolling()
        } catch {
            errorMessage = "Token exchange error: \(error.localizedDescription)"
        }
    }

    // MARK: - JWT Helpers

    /// Decode a JWT access token payload and extract the Sub-Zero userId (extension_sitecoreUserId claim).
    private static func extractUserId(from jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // B2C puts the user ID in extension_sitecoreUserId; fall back to oid or sub
        return claims["extension_sitecoreUserId"] as? String
            ?? claims["oid"] as? String
            ?? claims["sub"] as? String
    }

    // MARK: - Token Management

    private func refreshTokenIfNeeded() async -> Bool {
        guard let refreshToken = SubZeroKeychain.load(key: "refreshToken") else { return false }

        if let expiresAtStr = SubZeroKeychain.load(key: "tokenExpiresAt"),
           let expiresAt = Double(expiresAtStr),
           Date().timeIntervalSince1970 < expiresAt {
            return true // token still valid
        }

        var request = URLRequest(url: URL(string: "\(Self.b2cBase)/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var bodyComponents = URLComponents()
        bodyComponents.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "client_id", value: Self.clientId),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "scope", value: "\(Self.clientId) openid offline_access"),
        ]
        request.httpBody = bodyComponents.percentEncodedQuery?.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                print("SubZero: refresh token failed (\((response as? HTTPURLResponse)?.statusCode ?? 0))")
                return false
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            if let at = json["access_token"] as? String { SubZeroKeychain.save(key: "accessToken", value: at) }
            if let rt = json["refresh_token"] as? String { SubZeroKeychain.save(key: "refreshToken", value: rt) }
            let expiresIn = json["expires_in"] as? Int ?? 3600
            SubZeroKeychain.save(key: "tokenExpiresAt", value: "\(Date().addingTimeInterval(TimeInterval(expiresIn - 60)).timeIntervalSince1970)")
            return true
        } catch {
            print("SubZero: refresh error — \(error)")
            return false
        }
    }

    // MARK: - API Calls

    private func apiGet(_ path: String) async throws -> Any {
        guard await refreshTokenIfNeeded(),
              let token = SubZeroKeychain.load(key: "accessToken") else {
            throw URLError(.userAuthenticationRequired)
        }

        var request = URLRequest(url: URL(string: "\(Self.apiBase)\(path)")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.defaultSubKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        if let uid = SubZeroKeychain.load(key: "userId") {
            request.setValue(uid, forHTTPHeaderField: "userId")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("SubZero API \(path): HTTP \(status) — \(String(data: data, encoding: .utf8) ?? "")")
            throw URLError(.badServerResponse)
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    private func apiPost(_ path: String, body: [String: Any]) async throws {
        guard await refreshTokenIfNeeded(),
              let token = SubZeroKeychain.load(key: "accessToken") else {
            throw URLError(.userAuthenticationRequired)
        }

        let isDirectMethod = path.contains("directmethod")

        // For directmethod endpoints, try to discover the correct subscription key
        if isDirectMethod, Self.directMethodSubKey == nil {
            print("SubZero: discovering subscription key for directmethod API...")
            for key in Self.allSubKeys {
                let result = try? await apiPostRaw(path, body: body, token: token, subKey: key)
                if let result = result {
                    if result.status != 404 && result.status != 401 && result.status != 403 {
                        print("SubZero: directmethod key found: \(key.prefix(8))... (HTTP \(result.status))")
                        Self.directMethodSubKey = key
                        if (200..<300).contains(result.status) { return }
                        // Got a non-404 response but not success — log and throw
                        print("SubZero API POST \(path): HTTP \(result.status) — \(result.body)")
                        throw URLError(.badServerResponse)
                    }
                }
            }
            if Self.directMethodSubKey == nil {
                print("SubZero: no subscription key works for \(path) — all returned 404/401/403")
                throw URLError(.badServerResponse)
            }
        }

        let subKey = isDirectMethod ? (Self.directMethodSubKey ?? Self.defaultSubKey) : Self.defaultSubKey
        let result = try await apiPostRaw(path, body: body, token: token, subKey: subKey)
        guard (200..<300).contains(result.status) else {
            print("SubZero API POST \(path): HTTP \(result.status) — \(result.body)")
            throw URLError(.badServerResponse)
        }
    }

    private func apiPostRaw(_ path: String, body: [String: Any], token: String, subKey: String) async throws -> (status: Int, body: String) {
        var request = URLRequest(url: URL(string: "\(Self.apiBase)\(path)")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(subKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let uid = SubZeroKeychain.load(key: "userId") {
            request.setValue(uid, forHTTPHeaderField: "userId")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let bodyStr = String(data: data, encoding: .utf8) ?? ""
        return (status, bodyStr)
    }

    // MARK: - Fetch Appliances

    func fetchAppliances() async {
        do {
            let result = try await apiGet("/consumerapp/user/devices")
            // Defensive: response may be array directly or wrapped in an envelope
            let items: [[String: Any]]
            if let arr = result as? [[String: Any]] {
                items = arr
            } else if let dict = result as? [String: Any],
                      let arr = (dict["devices"] ?? dict["appliances"] ?? dict["data"]) as? [[String: Any]] {
                items = arr
            } else {
                print("SubZero: unexpected device list shape")
                return
            }

            var newMeta: [String: DeviceMeta] = [:]

            for item in items {
                // Key metadata by the hex `id` — this equals the SignalR DeviceId.
                let hexId = String(describing: item["id"] ?? item["deviceId"] ?? item["applianceId"] ?? "")
                let name = item["applianceName"] as? String ?? item["name"] as? String ?? "Appliance"
                let model = item["model"] as? String ?? item["modelNumber"] as? String ?? ""
                let online = item["online"] as? Bool ?? item["connected"] as? Bool ?? true

                // Classify by name: "oven"/"range" → oven; otherwise fridge (a beverage center is a fridge).
                let nameLower = name.lowercased()
                let isOven = nameLower.contains("oven") || nameLower.contains("range")
                print("SubZero device '\(name)' (\(hexId)): \(isOven ? "oven" : "fridge")")

                newMeta[hexId] = DeviceMeta(name: name, model: model, online: online, isOven: isOven)
            }

            deviceMeta = newMeta
            // Live state comes only over SignalR; the device list is metadata only. Rebuild
            // from whatever SignalR props we already have (may be empty on first fetch).
            rebuildAppliances()
            saveCache()
        } catch {
            print("SubZero: fetch appliances failed — \(error)")
            errorMessage = "Failed to fetch appliances"
        }
    }

    // MARK: - Property Builders

    private func buildRefrigerator(appId: String, name: String, model: String, online: Bool, props: [String: Any]) -> SubZeroRefrigerator {
        // A full SignalR snapshot carries the real model in `appliance_model`.
        let resolvedModel = stringVal(props, "appliance_model").flatMap { $0.isEmpty ? nil : $0 } ?? model
        return SubZeroRefrigerator(
            applianceId: appId,
            applianceName: name,
            model: resolvedModel,
            online: online,
            // Sub-Zero fridges report SETPOINTS only over the cloud, not measured temps.
            fridgeTemp: nil,
            freezerTemp: nil,
            fridgeSetpoint: doubleVal(props, "ref_set_temp", "fridge_setpoint", "fridgeSetpoint"),
            freezerSetpoint: doubleVal(props, "frz_set_temp", "freezer_setpoint", "freezerSetpoint"),
            crisperSetpoint: doubleVal(props, "crisp_set_temp", "crisper_setpoint", "crisperSetpoint"),
            fridgeDoorOpen: boolVal(props, "ref_door_ajar", "fridge_door_open", "fridgeDoorOpen"),
            freezerDoorOpen: boolVal(props, "frz_door_ajar", "freezer_door_open", "freezerDoorOpen"),
            iceMakerOn: boolVal(props, "ice_maker_on", "iceMakerOn"),
            maxIceOn: boolVal(props, "max_ice_on", "maxIceOn"),
            mode: refrigeratorModeFromProps(props),
            nightMode: boolVal(props, "night_mode", "nightMode"),
            lightOn: {
                if let accent = doubleVal(props, "accent_light_level") { return accent > 0 }
                return boolVal(props, "light_on", "lightOn")
            }(),
            waterFilterPct: doubleVal(props, "water_filter_pct_remaining", "waterFilterPct"),
            airPurificationPct: doubleVal(props, "air_filter_pct_remaining", "air_purification_pct", "airPurificationPct"),
            humidityControl: stringVal(props, "humidity_control", "humidityControl"),
            lastUpdated: Date()
        )
    }

    private func buildOven(appId: String, name: String, model: String, online: Bool, props: [String: Any]) -> WolfOven {
        let resolvedModel = stringVal(props, "appliance_model").flatMap { $0.isEmpty ? nil : $0 } ?? model
        // Dual-cavity ovens expose cav_/cav2_ prefixes; we surface the primary
        // cavity here (cav2_* is captured in state but not yet modeled in WolfOven).
        return WolfOven(
            applianceId: appId,
            applianceName: name,
            model: resolvedModel,
            online: online,
            unitOn: boolVal(props, "cav_unit_on", "unit_on", "unitOn"),
            currentTemp: doubleVal(props, "cav_temp", "oven_temperature", "currentTemp"),
            targetTemp: doubleVal(props, "cav_set_temp", "target_temperature", "targetTemp"),
            cookMode: ovenCookMode(props),
            probeTemp: doubleVal(props, "cav_probe_temp", "probe_temperature", "probeTemp"),
            probeTargetTemp: doubleVal(props, "cav_probe_set_temp", "probe_target_temperature", "probeTargetTemp"),
            timerRemaining: ovenTimerRemaining(props),
            remoteReady: boolVal(props, "cav_remote_ready", "remote_ready", "remoteReady"),
            lightOn: boolVal(props, "cav_light_on", "light_on", "lightOn"),
            lastUpdated: Date()
        )
    }

    /// Derive fridge mode from the boolean state flags (no single mode field over the cloud).
    private func refrigeratorModeFromProps(_ props: [String: Any]) -> RefrigeratorMode {
        if boolVal(props, "sabbath_on") { return .sabbath }
        if boolVal(props, "short_vacation_on") || boolVal(props, "long_vacation_on") { return .vacation }
        if boolVal(props, "night_mode") { return .night }
        if let raw = props["mode"] ?? props["refrigerator_mode"] {
            return parseRefrigeratorMode(raw)
        }
        return .normal
    }

    /// `cav_cook_mode` is an int; 0 = off. We don't have the full int→mode table, so
    /// non-zero maps to `.unknown` unless a string cook mode is present.
    private func ovenCookMode(_ props: [String: Any]) -> OvenMode {
        if let raw = props["cav_cook_mode"] {
            if let i = intVal(["v": raw], "v") { return i == 0 ? .off : .unknown }
            if let s = raw as? String { return parseOvenMode(s) }
        }
        return parseOvenMode(props["cook_mode"] ?? props["cookMode"])
    }

    /// Seconds remaining on the oven's active kitchen timer, else nil.
    private func ovenTimerRemaining(_ props: [String: Any]) -> Int? {
        if boolVal(props, "kitchen_timer_active"),
           let end = props["kitchen_timer_end_time"] as? String,
           let endDate = Self.parseISO8601(end) {
            let secs = Int(endDate.timeIntervalSinceNow.rounded())
            return max(secs, 0)
        }
        return intVal(props, "timer_remaining", "timerRemaining")
    }

    private static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso8601Plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseISO8601(_ s: String) -> Date? {
        iso8601Fractional.date(from: s) ?? iso8601Plain.date(from: s)
    }

    // MARK: - Rebuild from live state

    /// Rebuild the @Observable appliance arrays from device metadata + SignalR property state.
    /// Runs on the main actor since it mutates observed properties.
    @MainActor
    private func rebuildAppliancesMain() {
        var fridges: [SubZeroRefrigerator] = []
        var ovensList: [WolfOven] = []

        for (id, meta) in deviceMeta {
            let props = deviceProperties[id] ?? [:]
            if meta.isOven {
                ovensList.append(buildOven(appId: id, name: meta.name, model: meta.model, online: meta.online, props: props))
            } else {
                fridges.append(buildRefrigerator(appId: id, name: meta.name, model: meta.model, online: meta.online, props: props))
            }
        }

        refrigerators = fridges.sorted { $0.applianceName < $1.applianceName }
        ovens = ovensList.sorted { $0.applianceName < $1.applianceName }
    }

    /// Non-isolated entry point that hops to the main actor to update observed state.
    private func rebuildAppliances() {
        Task { @MainActor in self.rebuildAppliancesMain() }
    }

    // MARK: - SignalR Real-Time Connection

    /// Negotiate + open the Azure SignalR WebSocket carrying live appliance state.
    func connectSignalR() {
        Task { await connectSignalRAsync() }
    }

    private func connectSignalRAsync() async {
        if let ws = webSocketTask, ws.state == .running { return }

        guard await refreshTokenIfNeeded(),
              let token = SubZeroKeychain.load(key: "accessToken") else {
            print("SubZero SignalR: no token, cannot negotiate")
            return
        }
        let uid = SubZeroKeychain.load(key: "userId") ?? ""

        // 1. Negotiate: POST /signal-r/negotiateUser (hyphenated) with the SignalR product key.
        var negRequest = URLRequest(url: URL(string: "\(Self.apiBase)/signal-r/negotiateUser")!)
        negRequest.httpMethod = "POST"
        negRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        negRequest.setValue(Self.signalRSubKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        negRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        negRequest.setValue(uid, forHTTPHeaderField: "userId")
        negRequest.httpBody = "{}".data(using: .utf8)

        let negURL: String
        let negAccessToken: String
        do {
            let (data, response) = try await URLSession.shared.data(for: negRequest)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                print("SubZero SignalR: negotiate failed HTTP \(status) — \(String(data: data, encoding: .utf8)?.prefix(150) ?? "")")
                return
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            guard let url = json["url"] as? String,
                  let at = json["accessToken"] as? String else {
                print("SubZero SignalR: negotiate response missing url/accessToken")
                return
            }
            negURL = url
            negAccessToken = at
        } catch {
            print("SubZero SignalR: negotiate error — \(error)")
            return
        }

        // 2. Open a WebSocket to url (https→wss) with the percent-encoded access_token appended.
        var wssString = negURL
        if wssString.hasPrefix("https") {
            wssString = "wss" + wssString.dropFirst("https".count)
        } else if wssString.hasPrefix("http") {
            wssString = "ws" + wssString.dropFirst("http".count)
        }
        let encodedToken = negAccessToken.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? negAccessToken
        wssString += "&access_token=\(encodedToken)"
        guard let wsURL = URL(string: wssString) else {
            print("SubZero SignalR: invalid ws url")
            return
        }

        wsGeneration += 1
        let generation = wsGeneration
        signalRHandshaken = false
        let task = URLSession.shared.webSocketTask(with: wsURL)
        webSocketTask = task
        task.resume()

        // 3. Send the SignalR JSON handshake, terminated by the record separator.
        let handshake = "{\"protocol\":\"json\",\"version\":1}" + Self.recordSeparator
        task.send(.string(handshake)) { [weak self] error in
            if let error {
                print("SubZero SignalR: handshake send failed — \(error)")
                self?.scheduleReconnect(generation: generation)
            }
        }

        // 4. Begin the receive loop.
        receiveNext(task: task, generation: generation)
    }

    private func receiveNext(task: URLSessionWebSocketTask, generation: Int) {
        task.receive { [weak self] result in
            guard let self else { return }
            guard generation == self.wsGeneration else { return } // stale socket
            switch result {
            case .failure(let error):
                print("SubZero SignalR: receive error — \(error.localizedDescription)")
                self.scheduleReconnect(generation: generation)
            case .success(let message):
                let text: String
                switch message {
                case .string(let s): text = s
                case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
                @unknown default: text = ""
                }
                self.handleWebSocketText(text, task: task)
                // Keep receiving.
                self.receiveNext(task: task, generation: generation)
            }
        }
    }

    /// A single WS text message may carry multiple 0x1e-separated JSON records.
    private func handleWebSocketText(_ text: String, task: URLSessionWebSocketTask) {
        for part in text.components(separatedBy: Self.recordSeparator) {
            if part.isEmpty { continue }
            guard let data = part.data(using: .utf8),
                  let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            if !signalRHandshaken {
                signalRHandshaken = true
                if let err = m["error"] {
                    print("SubZero SignalR: handshake error — \(err)")
                } else {
                    print("SubZero SignalR: connected to connectedappliances hub")
                    // Receive-only connection won't get an initial snapshot until someone
                    // else triggers one — pull a full snapshot for every device now.
                    Task { await self.refreshAllSnapshots() }
                }
                continue
            }

            let type = m["type"] as? Int
            if type == 6 {
                // Ping → reply with pong to keep the connection alive.
                let pong = "{\"type\":6}" + Self.recordSeparator
                task.send(.string(pong)) { _ in }
                continue
            }
            if type == 1,
               (m["target"] as? String) == "ConnectedApplianceMessage",
               let args = m["arguments"] as? [Any],
               let first = args.first {
                handleApplianceMessage(first)
            }
        }
    }

    /// Decode a ConnectedApplianceMessage. Triple-nested JSON:
    /// arg string → { DeviceId, Payload } → Payload string → { "api.async_channel" }
    /// → channel string → { type, pload }. type 1 = full snapshot, type 2 = delta.
    private func handleApplianceMessage(_ argStr: Any) {
        guard let str = argStr as? String,
              let envData = str.data(using: .utf8),
              let env = try? JSONSerialization.jsonObject(with: envData) as? [String: Any] else { return }

        let deviceId = String(describing: env["DeviceId"] ?? "")
        guard !deviceId.isEmpty,
              let payloadStr = env["Payload"] as? String,
              let payloadData = payloadStr.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else { return }

        guard let chanStr = payload["api.async_channel"] as? String,
              let chanData = chanStr.data(using: .utf8),
              let chan = try? JSONSerialization.jsonObject(with: chanData) as? [String: Any] else { return }

        let chanType = chan["type"] as? Int
        let pload = chan["pload"] as? [String: Any] ?? [:]

        let props: [String: Any]
        if chanType == 1 {
            props = pload // full snapshot
        } else if chanType == 2 {
            props = pload["props"] as? [String: Any] ?? [:] // delta
        } else {
            return
        }

        var existing = deviceProperties[deviceId] ?? [:]
        for (k, v) in props { existing[k] = v }
        deviceProperties[deviceId] = existing

        rebuildAppliances()
    }

    private func scheduleReconnect(generation: Int) {
        guard generation == wsGeneration else { return }
        guard isLinked, !wsReconnectPending else { return }
        wsReconnectPending = true
        webSocketTask = nil
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000) // 5s
            guard let self, self.isLinked else { return }
            self.wsReconnectPending = false
            await self.connectSignalRAsync()
        }
    }

    private func disconnectSignalR() {
        wsGeneration += 1 // invalidate any in-flight receive loop
        wsReconnectPending = false
        signalRHandshaken = false
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }

    // MARK: - Commands

    // Command protocol (reverse-engineered from the Owner's app v4.6.0 via blutter, live-validated):
    //   POST /consumerapp/device/{deviceId}/directmethod/executeAPICmd
    //   body { req_id: <uuid>, pload: { cmd: "get" } | { cmd: "set", params: {..} } | ... }
    // Response for cmd:get is the flat property snapshot (same shape as a SignalR type-1 pload).
    @discardableResult
    private func sendDirectMethod(deviceId: String, pload: [String: Any]) async throws -> [String: Any] {
        guard await refreshTokenIfNeeded(),
              let token = SubZeroKeychain.load(key: "accessToken") else {
            throw URLError(.userAuthenticationRequired)
        }
        var request = URLRequest(url: URL(string: "\(Self.apiBase)/consumerapp/device/\(deviceId)/directmethod/executeAPICmd")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.defaultSubKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("4.6.0", forHTTPHeaderField: "app_version")
        request.setValue("android", forHTTPHeaderField: "app_platform")
        if let uid = SubZeroKeychain.load(key: "userId") {
            request.setValue(uid, forHTTPHeaderField: "userId")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "req_id": UUID().uuidString.lowercased(),
            "pload": pload,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            print("SubZero directmethod \(deviceId): HTTP \(status) — \(String(data: data, encoding: .utf8) ?? "")")
            throw URLError(.badServerResponse)
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// On-demand full snapshot ({cmd:"get"}). Our SignalR link is receive-only and won't
    /// get an initial snapshot until someone else triggers one, so we pull one ourselves.
    func refreshSnapshot(applianceId: String) async {
        do {
            let props = try await sendDirectMethod(deviceId: applianceId, pload: ["cmd": "get"])
            guard !props.isEmpty else { return }
            var existing = deviceProperties[applianceId] ?? [:]
            for (k, v) in props { existing[k] = v }
            deviceProperties[applianceId] = existing
            rebuildAppliances()
        } catch {
            print("SubZero: refreshSnapshot failed — \(error)")
        }
    }

    /// Pull a fresh snapshot for every known device (used at connect to seed live state).
    func refreshAllSnapshots() async {
        let ids = Array(deviceMeta.keys)
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { await self.refreshSnapshot(applianceId: id) }
            }
        }
    }

    /// Write a property ({cmd:"set", params}), then re-read to reflect the change.
    private func setProperty(_ applianceId: String, _ name: String, _ value: Any) async {
        do {
            try await sendDirectMethod(deviceId: applianceId, pload: ["cmd": "set", "params": [name: value]])
            await refreshSnapshot(applianceId: applianceId)
        } catch {
            print("SubZero: set \(name) failed — \(error)")
        }
    }

    // Property names below are the device's own — confirmed live for the refrigerator;
    // oven names follow the cav_* scheme seen in SignalR ploads.
    func setFridgeTemp(applianceId: String, temp: Int) async { await setProperty(applianceId, "ref_set_temp", temp) }
    func setFreezerTemp(applianceId: String, temp: Int) async { await setProperty(applianceId, "frz_set_temp", temp) }
    func setCrisperTemp(applianceId: String, temp: Int) async { await setProperty(applianceId, "crisp_set_temp", temp) }
    func setNightMode(applianceId: String, on: Bool) async { await setProperty(applianceId, "night_mode", on ? 1 : 0) }
    func setIceMaker(applianceId: String, on: Bool) async { await setProperty(applianceId, "ice_maker_on", on) }
    func setMaxIce(applianceId: String, on: Bool) async { await setProperty(applianceId, "max_ice_on", on) }
    func setHumidityControl(applianceId: String, level: Int) async { await setProperty(applianceId, "humidity_control", level) }
    func toggleLight(applianceId: String, on: Bool) async { await setProperty(applianceId, "light_on", on) }
    func toggleOvenLight(applianceId: String, on: Bool) async { await setProperty(applianceId, "cav_light_on", on) }

    // Kitchen timer commands — confirmed by static decompile of the Owner's app v4.6.0
    // (blutter): KitchenTimerOverlayController.onActionButtonTap / handleCancelTimerButtonPress
    // send the property `kitchen_timer_duration` (an Int in MINUTES) via the executeAPICmd
    // set path. The picker is Hours+Minutes and the app writes hours*60+minutes. Setting the
    // duration to 0 cancels a running timer. (`kitchen_timer_end_time`/`kitchen_timer_active`
    // are only mutated locally in the app's demo mode — they are read-only device state.)
    func setKitchenTimer(applianceId: String, minutes: Int) async { await setProperty(applianceId, "kitchen_timer_duration", minutes) }
    func cancelKitchenTimer(applianceId: String) async { await setProperty(applianceId, "kitchen_timer_duration", 0) }

    // Property names below are NOT yet confirmed against a live device (transport is correct;
    // names are best-effort from the SignalR ploads). Verify before relying on them.
    func setMode(applianceId: String, mode: String) async { await setProperty(applianceId, "mode", mode) }
    func preheatOven(applianceId: String, temp: Int, mode: String) async {
        do {
            try await sendDirectMethod(deviceId: applianceId, pload: ["cmd": "set", "params": ["cav_set_temp": temp, "cav_cook_mode": mode, "cav_unit_on": true]])
            await refreshSnapshot(applianceId: applianceId)
        } catch {
            print("SubZero: preheatOven failed — \(error)")
        }
    }

    // MARK: - Polling

    func startPolling() {
        stopPolling()
        // Live state arrives over SignalR; the REST poll only refreshes the device list.
        connectSignalR()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { await self?.fetchAppliances() }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        disconnectSignalR()
    }

    func resume() {
        if isLinked {
            Task { await fetchAppliances() }
            startPolling()
        }
    }

    func pause() {
        stopPolling()
    }

    func unlink() {
        stopPolling()
        SubZeroKeychain.deleteAll()
        deviceMeta = [:]
        deviceProperties = [:]
        refrigerators = []
        ovens = []
        errorMessage = nil
        clearCache()
    }

    // MARK: - Cache

    private func saveCache() {
        let fridgeData: [[String: Any]] = refrigerators.compactMap { r -> [String: Any]? in
            guard let jsonData = try? JSONEncoder().encode(r),
                  let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { return nil }
            return dict
        }
        let ovenData: [[String: Any]] = ovens.compactMap { o -> [String: Any]? in
            guard let jsonData = try? JSONEncoder().encode(o),
                  let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { return nil }
            return dict
        }
        let data: [String: Any] = ["refrigerators": fridgeData, "ovens": ovenData]
        UserDefaults.standard.set(data, forKey: Self.cacheKey)
    }

    private func loadCache() {
        guard let data = UserDefaults.standard.dictionary(forKey: Self.cacheKey) else { return }
        if let fridgeArr = data["refrigerators"] as? [[String: Any]] {
            refrigerators = fridgeArr.compactMap { dict in
                guard let jsonData = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
                return try? JSONDecoder().decode(SubZeroRefrigerator.self, from: jsonData)
            }
        }
        if let ovenArr = data["ovens"] as? [[String: Any]] {
            ovens = ovenArr.compactMap { dict in
                guard let jsonData = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
                return try? JSONDecoder().decode(WolfOven.self, from: jsonData)
            }
        }
    }

    private func clearCache() {
        UserDefaults.standard.removeObject(forKey: Self.cacheKey)
    }

    // MARK: - PKCE Helpers

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Property Parsing Helpers

    private func doubleVal(_ dict: [String: Any], _ keys: String...) -> Double? {
        for key in keys {
            if let v = dict[key] as? Double { return v }
            if let v = dict[key] as? Int { return Double(v) }
            if let v = dict[key] as? String, let d = Double(v) { return d }
        }
        return nil
    }

    private func intVal(_ dict: [String: Any], _ keys: String...) -> Int? {
        for key in keys {
            if let v = dict[key] as? Int { return v }
            if let v = dict[key] as? Double { return Int(v) }
            if let v = dict[key] as? String, let i = Int(v) { return i }
        }
        return nil
    }

    private func boolVal(_ dict: [String: Any], _ keys: String...) -> Bool {
        for key in keys {
            if let v = dict[key] as? Bool { return v }
            if let v = dict[key] as? Int { return v != 0 }
            if let v = dict[key] as? String { return v == "true" || v == "1" }
        }
        return false
    }

    private func stringVal(_ dict: [String: Any], _ keys: String...) -> String? {
        for key in keys {
            if let v = dict[key] as? String { return v }
            if let v = dict[key] { return "\(v)" }
        }
        return nil
    }

    private func parseRefrigeratorMode(_ val: Any?) -> RefrigeratorMode {
        guard let str = val as? String else { return .unknown }
        let lower = str.lowercased()
        if lower.contains("vacation") { return .vacation }
        if lower.contains("sabbath") { return .sabbath }
        if lower.contains("night") { return .night }
        if lower.contains("normal") { return .normal }
        return .unknown
    }

    private func parseOvenMode(_ val: Any?) -> OvenMode {
        guard let str = val as? String else { return .unknown }
        let lower = str.lowercased().replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
        return OvenMode(rawValue: lower) ?? .unknown
    }
}
