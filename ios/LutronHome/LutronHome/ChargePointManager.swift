import Foundation
import Observation
import Security

// MARK: - Models

enum ChargingStatus: String, Codable {
    case idle, pluggedIn, charging, complete, error, unknown

    var label: String {
        switch self {
        case .idle:      return "Idle"
        case .pluggedIn: return "Plugged In"
        case .charging:  return "Charging"
        case .complete:  return "Complete"
        case .error:     return "Error"
        case .unknown:   return "Unknown"
        }
    }

    var icon: String {
        switch self {
        case .idle:      return "ev.charger"
        case .pluggedIn: return "powerplug.fill"
        case .charging:  return "bolt.fill"
        case .complete:  return "checkmark.circle.fill"
        case .error:     return "exclamationmark.triangle.fill"
        case .unknown:   return "questionmark.circle"
        }
    }

    var isActive: Bool { self == .charging }
}

struct ChargePointCharger: Identifiable, Codable {
    var id: String { "\(accountIndex)-\(chargerId)" }
    let chargerId: String
    let accountIndex: Int
    let nickname: String
    let status: ChargingStatus
    let isPluggedIn: Bool
    let powerKw: Double?
    let energyKwh: Double?
    let amperage: Int
    let maxAmperage: Int
    let lastUpdated: Date
}

struct ChargePointSession: Identifiable, Codable {
    var id: String { sessionId }
    let sessionId: String
    let chargerId: String
    let startTime: Date
    let endTime: Date?
    let energyKwh: Double
    let cost: Double?
    let milesAdded: Double?
}

// MARK: - No-Redirect Delegate

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Stop redirect — we need the Set-Cookie from the 302
        completionHandler(nil)
    }
}

// MARK: - Keychain helpers

private enum ChargePointKeychain {
    private static let service = "com.jasongelman.LutronHome.chargepoint"

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
}

// MARK: - API Session

private struct ChargePointAPISession {
    let token: String
    let tokenType: String // "coulomb_sess" or "auth-session"
    let userId: Int
    let endpoints: ChargePointEndpoints
    let expiry: Date
}

private struct ChargePointEndpoints {
    let ssoEndpoint: String
    let hcmEndpoint: String
    let accountsEndpoint: String
    let driverBffEndpoint: String
    let portalDomainEndpoint: String
    let mapcacheEndpoint: String
    let region: String
}

// MARK: - Manager

@Observable
class ChargePointManager: @unchecked Sendable {
    var chargers: [ChargePointCharger] = []
    var isLoading = false
    var errorMessage: String?

    var isLinked: Bool {
        (0..<2).contains { i in
            ChargePointKeychain.load(key: "email_\(i)") != nil &&
            ChargePointKeychain.load(key: "password_\(i)") != nil
        }
    }

    private var accountSessions: [Int: ChargePointAPISession] = [:]
    private var pollTimer: Timer?
    private static let discoveryURL = "https://discovery.chargepoint.com/discovery/v3/globalconfig"
    // Mimic the ChargePoint iOS app so DataDome doesn't block us
    private static let userAgent = "ChargePoint/6.0.0 CFNetwork/1568.200.51 Darwin/24.1.0"
    private static let cacheKey = "chargepoint_chargers_cache"

    /// Shared cookie storage so DataDome cookies carry across all sessions.
    @ObservationIgnored
    private let cookieStorage = HTTPCookieStorage.shared

    /// Session for login only — blocks redirects to capture Set-Cookie from 302.
    @ObservationIgnored
    private lazy var loginSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = cookieStorage
        config.httpCookieAcceptPolicy = .always
        return URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }()

    /// Session for all non-login API calls — follows redirects normally.
    @ObservationIgnored
    private lazy var apiSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = cookieStorage
        config.httpCookieAcceptPolicy = .always
        return URLSession(configuration: config)
    }()

    init() {
        // Load cached charger state for instant startup
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let cached = try? JSONDecoder().decode([ChargePointCharger].self, from: data) {
            chargers = cached
        }
    }

    // MARK: - Account Management

    func signIn(accountIndex: Int, email: String, password: String, nickname: String) {
        ChargePointKeychain.save(key: "email_\(accountIndex)", value: email)
        ChargePointKeychain.save(key: "password_\(accountIndex)", value: password)
        UserDefaults.standard.set(nickname, forKey: "chargepoint_nickname_\(accountIndex)")
        accountSessions.removeValue(forKey: accountIndex)
        resume()
    }

    func signOut(accountIndex: Int) {
        ChargePointKeychain.delete(key: "email_\(accountIndex)")
        ChargePointKeychain.delete(key: "password_\(accountIndex)")
        UserDefaults.standard.removeObject(forKey: "chargepoint_nickname_\(accountIndex)")
        accountSessions.removeValue(forKey: accountIndex)
        chargers = chargers.filter { $0.accountIndex != accountIndex }
        saveCache()
    }

    func getNickname(for accountIndex: Int) -> String {
        UserDefaults.standard.string(forKey: "chargepoint_nickname_\(accountIndex)") ?? "Charger \(accountIndex + 1)"
    }

    func getEmail(for accountIndex: Int) -> String {
        ChargePointKeychain.load(key: "email_\(accountIndex)") ?? ""
    }

    func hasCredentials(for accountIndex: Int) -> Bool {
        ChargePointKeychain.load(key: "email_\(accountIndex)") != nil &&
        ChargePointKeychain.load(key: "password_\(accountIndex)") != nil
    }

    // MARK: - Lifecycle

    func resume() {
        guard isLinked else { return }
        pollTimer?.invalidate()
        Task { await poll() }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in
            Task { await self?.poll() }
        }
    }

    func suspend() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Controls

    func setAmperage(accountIndex: Int, chargerId: String, amps: Int) async {
        guard let session = try? await getSession(for: accountIndex) else { return }

        let url = URL(string: "\(session.endpoints.hcmEndpoint)api/v1/configuration/chargers/\(chargerId)/charge-amperage-limit")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.allHTTPHeaderFields = authHeaders(session)
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["chargeAmperageLimit": amps])

        do {
            let (_, response) = try await apiSession.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode < 300 else { return }
            // Optimistic update — disambiguate by both accountIndex and chargerId
            if let idx = chargers.firstIndex(where: { $0.accountIndex == accountIndex && $0.chargerId == chargerId }) {
                let old = chargers[idx]
                chargers[idx] = ChargePointCharger(
                    chargerId: old.chargerId, accountIndex: old.accountIndex, nickname: old.nickname,
                    status: old.status, isPluggedIn: old.isPluggedIn, powerKw: old.powerKw,
                    energyKwh: old.energyKwh, amperage: amps, maxAmperage: old.maxAmperage,
                    lastUpdated: Date()
                )
            }
        } catch {
            print("ChargePoint: set amperage failed — \(error)")
        }
    }

    /// Start or stop charging. The exact endpoint isn't documented; we try the
    /// most plausible patterns in order and stop at the first 2xx. Once we
    /// know which one works, the loser branches can be deleted.
    func setChargingState(accountIndex: Int, chargerId: String, start: Bool) async {
        guard let session = try? await getSession(for: accountIndex) else { return }
        let hcm = session.endpoints.hcmEndpoint
        let action = start ? "start" : "stop"

        struct Attempt {
            let method: String
            let url: String
            let body: [String: Any]
        }
        let attempts: [Attempt] = [
            // Pattern A: command-style sibling of charge-amperage-limit
            Attempt(method: "PUT", url: "\(hcm)api/v1/configuration/chargers/\(chargerId)/\(action)-charging", body: [:]),
            Attempt(method: "PUT", url: "\(hcm)api/v1/configuration/chargers/\(chargerId)/\(action)", body: [:]),
            // Pattern B: state setter
            Attempt(method: "PUT", url: "\(hcm)api/v1/configuration/chargers/\(chargerId)/charging-state",
                    body: ["state": start ? "CHARGING" : "NOT_CHARGING"]),
            Attempt(method: "PUT", url: "\(hcm)api/v1/configuration/chargers/\(chargerId)/state",
                    body: ["state": start ? "CHARGING" : "NOT_CHARGING"]),
            // Pattern C: command verb in body
            Attempt(method: "POST", url: "\(hcm)api/v1/configuration/chargers/\(chargerId)/command",
                    body: ["command": start ? "START" : "STOP"]),
            // Pattern D: session resource
            Attempt(method: start ? "POST" : "DELETE",
                    url: "\(hcm)api/v1/configuration/chargers/\(chargerId)/session",
                    body: [:]),
        ]

        for a in attempts {
            guard let url = URL(string: a.url) else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = a.method
            req.allHTTPHeaderFields = authHeaders(session)
            if !a.body.isEmpty {
                req.httpBody = try? JSONSerialization.data(withJSONObject: a.body)
            }
            do {
                let (data, response) = try await apiSession.data(for: req)
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                let bodyPreview = String(data: data.prefix(200), encoding: .utf8) ?? ""
                if (200..<300).contains(code) {
                    print("ChargePoint: \(action) charge OK via \(a.method) \(a.url) — \(bodyPreview)")
                    Task { await poll() }
                    return
                } else {
                    print("ChargePoint: \(action) charge \(code) via \(a.method) \(a.url) — \(bodyPreview)")
                }
            } catch {
                print("ChargePoint: \(action) charge error \(a.method) \(a.url) — \(error.localizedDescription)")
            }
        }
        print("ChargePoint: \(action) charge — no endpoint pattern succeeded")
    }

    func fetchHistory(accountIndex: Int, chargerId: String) async -> [ChargePointSession] {
        guard let session = try? await getSession(for: accountIndex) else { return [] }

        let url = URL(string: "\(session.endpoints.driverBffEndpoint)driver-bff/v1/user/\(session.userId)/charging-activities")!
        var request = URLRequest(url: url)
        request.allHTTPHeaderFields = authHeaders(session)

        do {
            let (data, response) = try await apiSession.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let activities = json["charging_activities"] as? [[String: Any]] else { return [] }

            return activities.compactMap { a in
                guard let sessionId = a["session_id"] else { return nil }
                let startMs = a["start_time"] as? Double ?? 0
                let endMs = a["end_time"] as? Double
                return ChargePointSession(
                    sessionId: "\(sessionId)",
                    chargerId: "\(a["device_id"] ?? "")",
                    startTime: Date(timeIntervalSince1970: startMs / 1000),
                    endTime: endMs.map { Date(timeIntervalSince1970: $0 / 1000) },
                    energyKwh: a["energy_kwh"] as? Double ?? 0,
                    cost: a["total_amount"] as? Double,
                    milesAdded: a["miles_added"] as? Double
                )
            }
        } catch {
            print("ChargePoint: fetch history failed — \(error)")
            return []
        }
    }

    // MARK: - Polling

    @ObservationIgnored
    private var probedLiveEndpoints = false

    private func poll() async {
        var allChargers: [ChargePointCharger] = []

        for i in 0..<2 {
            guard hasCredentials(for: i) else { continue }

            do {
                let session = try await getSession(for: i)
                let nickname = getNickname(for: i)
                let fetched = try await fetchChargers(session: session, accountIndex: i, nickname: nickname)
                allChargers.append(contentsOf: fetched)

                // One-shot probe to find the live-charging endpoint.
                if !probedLiveEndpoints, let chargerId = fetched.first?.chargerId {
                    probedLiveEndpoints = true
                    await probeLiveStatusEndpoints(session: session, chargerId: chargerId)
                }
            } catch {
                accountSessions.removeValue(forKey: i)
                print("ChargePoint: account \(i) poll error — \(error.localizedDescription)")
            }
        }

        if !allChargers.isEmpty || chargers.isEmpty {
            chargers = allChargers
            saveCache()
        }
        errorMessage = allChargers.isEmpty && isLinked ? "Failed to connect" : nil
    }

    // MARK: - Live-Status Endpoint Probe (one-shot diagnostic)

    private func probeLiveStatusEndpoints(session: ChargePointAPISession, chargerId: String) async {
        // Round 3: every previous body shape returned the same wrapped error,
        // suggesting either (a) body isn't being read, or (b) error_code 5000
        // means "no active session." Try wrapped body, query params, and the
        // mapcache endpoint (python-chargepoint's pattern).
        let bff = session.endpoints.driverBffEndpoint
        let mc = session.endpoints.mapcacheEndpoint
        let uid = session.userId
        let activeURL = "\(bff)driver-bff/v1/sessions/active"

        struct Attempt {
            let label: String
            let method: String
            let url: String
            let body: Any?
            let extraHeaders: [String: String]
        }

        let attempts: [Attempt] = [
            // Wrapped body matching response shape
            Attempt(label: "wrapped-empty", method: "POST", url: activeURL,
                    body: ["charging_status": [:]], extraHeaders: [:]),
            Attempt(label: "wrapped-user", method: "POST", url: activeURL,
                    body: ["charging_status": ["user_id": uid]], extraHeaders: [:]),
            Attempt(label: "wrapped-device", method: "POST", url: activeURL,
                    body: ["charging_status": ["device_id": chargerId]], extraHeaders: [:]),
            Attempt(label: "wrapped-both", method: "POST", url: activeURL,
                    body: ["charging_status": ["user_id": uid, "device_id": chargerId]], extraHeaders: [:]),
            Attempt(label: "wrapped-deviceIds", method: "POST", url: activeURL,
                    body: ["charging_status": ["device_ids": [chargerId]]], extraHeaders: [:]),
            // Query params
            Attempt(label: "qp-userId", method: "POST", url: "\(activeURL)?userId=\(uid)",
                    body: [:] as [String: Any], extraHeaders: [:]),
            Attempt(label: "qp-deviceId", method: "POST", url: "\(activeURL)?deviceId=\(chargerId)",
                    body: [:] as [String: Any], extraHeaders: [:]),
            Attempt(label: "qp-both", method: "POST", url: "\(activeURL)?userId=\(uid)&deviceId=\(chargerId)",
                    body: [:] as [String: Any], extraHeaders: [:]),
            // Mobile-app fingerprint header (some endpoints gate on this)
            Attempt(label: "with-app-ver", method: "POST", url: activeURL,
                    body: ["charging_status": ["user_id": uid]],
                    extraHeaders: ["cp-app-version": "6.0.0", "cp-platform": "ios"]),
            // Mapcache POST — python-chargepoint pattern
            Attempt(label: "mapcache-user-status", method: "POST", url: "\(mc)v3",
                    body: ["user_status": ["user_id": uid]], extraHeaders: [:]),
            Attempt(label: "mapcache-user-status-deviceId", method: "POST", url: "\(mc)v3",
                    body: ["user_status": ["user_id": uid, "device_id": chargerId]], extraHeaders: [:]),
        ]

        for a in attempts {
            guard let u = URL(string: a.url) else { continue }
            var req = URLRequest(url: u)
            req.httpMethod = a.method
            var headers = authHeaders(session)
            for (k, v) in a.extraHeaders { headers[k] = v }
            req.allHTTPHeaderFields = headers
            if let body = a.body {
                req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            }
            do {
                let (data, response) = try await apiSession.data(for: req)
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                let preview = String(data: data.prefix(500), encoding: .utf8) ?? "<non-utf8>"
                print("ChargePoint: PROBE [\(a.label)] \(code) \(a.method) \(a.url) — \(preview)")
            } catch {
                print("ChargePoint: PROBE [\(a.label)] error \(a.method) \(a.url) — \(error.localizedDescription)")
            }
        }
        print("ChargePoint: PROBE round 3 done")
    }

    private func dumpDiscoveryResponse(session: ChargePointAPISession) async {
        // Re-fetch discovery so we can see the raw response and identify any
        // endpoint bases we don't already use.
        guard let email = ChargePointKeychain.load(key: "email_0") else { return }
        let url = URL(string: Self.discoveryURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["username": email])
        do {
            let (data, _) = try await apiSession.data(for: request)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let endpoints = (json["endPoints"] ?? json["endpoints"]) as? [String: [String: Any]] {
                let keyList = endpoints.keys.sorted()
                print("ChargePoint: DISCOVERY endpoint keys = \(keyList)")
                for k in keyList {
                    let v = endpoints[k]?["value"] as? String ?? "?"
                    print("ChargePoint: DISCOVERY \(k) = \(v)")
                }
            }
        } catch {
            print("ChargePoint: DISCOVERY dump failed — \(error.localizedDescription)")
        }
    }

    // MARK: - API

    private func getSession(for accountIndex: Int) async throws -> ChargePointAPISession {
        if let cached = accountSessions[accountIndex], Date() < cached.expiry {
            return cached
        }

        guard let email = ChargePointKeychain.load(key: "email_\(accountIndex)"),
              let password = ChargePointKeychain.load(key: "password_\(accountIndex)") else {
            throw URLError(.userAuthenticationRequired)
        }

        // Discovery
        print("ChargePoint: [account \(accountIndex)] starting discovery...")
        let endpoints = try await discoverEndpoints(username: email)
        print("ChargePoint: [account \(accountIndex)] discovery OK — sso=\(endpoints.ssoEndpoint)")

        // Login
        print("ChargePoint: [account \(accountIndex)] logging in...")
        let loginURL = URL(string: "\(endpoints.ssoEndpoint)v1/user/login")!
        var loginReq = URLRequest(url: loginURL)
        loginReq.httpMethod = "POST"
        loginReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        loginReq.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        loginReq.setValue("application/json", forHTTPHeaderField: "Accept")
        loginReq.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        loginReq.httpBody = try JSONSerialization.data(withJSONObject: ["username": email, "password": password])

        // Use loginSession — SSO login returns a 302 with Set-Cookie; following the redirect
        // lands on an HTML page that URLSession can't parse as JSON (error -1017).
        let (_, loginResponse) = try await loginSession.data(for: loginReq)
        guard let httpLogin = loginResponse as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        // Extract session token from Set-Cookie header.
        // ChargePoint uses either "coulomb_sess" (legacy) or "auth-session" (current JWT).
        let allHeaders = httpLogin.allHeaderFields
        var setCookieValues: [String] = []
        if let single = allHeaders["Set-Cookie"] as? String {
            setCookieValues.append(single)
        }
        if let multi = allHeaders["set-cookie"] as? String {
            setCookieValues.append(multi)
        }

        // Also check the cookie jar (URLSession may have parsed Set-Cookie automatically)
        let jarCookies = HTTPCookieStorage.shared.cookies(for: loginURL) ?? []
        let setCookieStr = setCookieValues.joined(separator: ", ")

        // Try coulomb_sess first, then auth-session
        var token: String?
        var tokenType = "coulomb_sess"

        if let match = setCookieStr.range(of: "coulomb_sess=([^;]+)", options: .regularExpression) {
            token = String(setCookieStr[match]).replacingOccurrences(of: "coulomb_sess=", with: "")
        } else if let c = jarCookies.first(where: { $0.name == "coulomb_sess" }) {
            token = c.value
        } else if let match = setCookieStr.range(of: "auth-session=([^;]+)", options: .regularExpression) {
            token = String(setCookieStr[match]).replacingOccurrences(of: "auth-session=", with: "")
            tokenType = "auth-session"
        } else if let c = jarCookies.first(where: { $0.name == "auth-session" }) {
            token = c.value
            tokenType = "auth-session"
        }

        guard let sessionToken = token else {
            let cookieNames = jarCookies.map(\.name).joined(separator: ", ")
            print("ChargePoint: login returned \(httpLogin.statusCode) but no session cookie found. Set-Cookie: \(setCookieStr.prefix(200)). Jar cookies: \(cookieNames)")
            throw URLError(.userAuthenticationRequired)
        }

        print("ChargePoint: [account \(accountIndex)] login OK — got \(tokenType) (\(sessionToken.prefix(16))...)")
        return try await completeLogin(token: sessionToken, tokenType: tokenType, endpoints: endpoints, accountIndex: accountIndex)
    }

    private func completeLogin(token: String, tokenType: String, endpoints: ChargePointEndpoints, accountIndex: Int) async throws -> ChargePointAPISession {
        // Step 1: If we got an auth-session JWT, exchange it for coulomb_sess.
        // The HCM endpoints only accept coulomb_sess cookie auth.
        var activeToken = token
        var activeTokenType = tokenType

        if tokenType == "auth-session" {
            if let exchanged = try? await exchangeToken(authToken: token, endpoints: endpoints) {
                print("ChargePoint: token exchange succeeded — got coulomb_sess")
                activeToken = exchanged
                activeTokenType = "coulomb_sess"
                // Manually set the cookie so the cookie jar sends it with all .chargepoint.com requests
                if let cookie = HTTPCookie(properties: [
                    .name: "coulomb_sess",
                    .value: exchanged,
                    .domain: ".chargepoint.com",
                    .path: "/",
                    .expires: Date().addingTimeInterval(10 * 365 * 24 * 3600),
                ]) {
                    cookieStorage.setCookie(cookie)
                }
            } else {
                print("ChargePoint: token exchange failed, will try auth-session Bearer for profile")
            }
        }

        // Step 2: Get userId from profile endpoint
        let accountURL = URL(string: "\(endpoints.accountsEndpoint)v1/driver/profile/user")!
        var profileReq = URLRequest(url: accountURL)
        profileReq.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        profileReq.setValue(endpoints.region, forHTTPHeaderField: "cp-region")

        if activeTokenType == "coulomb_sess" {
            // Classic cookie-based auth
            profileReq.setValue("coulomb_sess=\(activeToken)", forHTTPHeaderField: "Cookie")
            profileReq.setValue("CP_SESSION_TOKEN", forHTTPHeaderField: "cp-session-type")
            profileReq.setValue(activeToken, forHTTPHeaderField: "cp-session-token")
        } else {
            // JWT Bearer auth (fallback if exchange failed)
            profileReq.setValue("Bearer \(activeToken)", forHTTPHeaderField: "Authorization")
        }

        let (profileData, profileResp) = try await apiSession.data(for: profileReq)
        guard let profileHTTP = profileResp as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        print("ChargePoint: profile HTTP \(profileHTTP.statusCode)")

        // If coulomb_sess failed, retry with Bearer
        var finalData = profileData
        if profileHTTP.statusCode != 200 && activeTokenType == "coulomb_sess" {
            print("ChargePoint: profile failed with coulomb_sess, retrying with Bearer")
            var bearerReq = URLRequest(url: accountURL)
            bearerReq.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            bearerReq.setValue(endpoints.region, forHTTPHeaderField: "cp-region")
            bearerReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data2, resp2) = try await apiSession.data(for: bearerReq)
            guard let http2 = resp2 as? HTTPURLResponse, http2.statusCode == 200 else {
                let body = String(data: data2.prefix(300), encoding: .utf8) ?? ""
                print("ChargePoint: profile Bearer fallback also failed — \(body)")
                throw URLError(.userAuthenticationRequired)
            }
            finalData = data2
            print("ChargePoint: profile Bearer fallback OK")
        } else if profileHTTP.statusCode != 200 {
            let body = String(data: profileData.prefix(300), encoding: .utf8) ?? ""
            print("ChargePoint: profile failed — \(body)")
            throw URLError(.userAuthenticationRequired)
        }

        guard let json = try JSONSerialization.jsonObject(with: finalData) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }

        let userId: Int
        if let user = json["user"] as? [String: Any] {
            userId = user["userId"] as? Int ?? user["user_id"] as? Int ?? 0
        } else {
            userId = json["userId"] as? Int ?? json["user_id"] as? Int ?? 0
        }
        guard userId != 0 else {
            print("ChargePoint: no userId in profile. Keys: \((json["user"] as? [String: Any])?.keys.sorted() ?? json.keys.sorted())")
            throw URLError(.userAuthenticationRequired)
        }

        // Refresh token from cookie jar if server sent a new one
        let refreshCookies = cookieStorage.cookies(for: accountURL) ?? []
        if let refreshed = refreshCookies.first(where: { $0.name == "coulomb_sess" }) {
            activeToken = refreshed.value
            activeTokenType = "coulomb_sess"
        }

        let session = ChargePointAPISession(
            token: activeToken,
            tokenType: activeTokenType,
            userId: userId,
            endpoints: endpoints,
            expiry: Date().addingTimeInterval(20 * 60)
        )
        accountSessions[accountIndex] = session
        print("ChargePoint: [account \(accountIndex)] authenticated — userId=\(userId), tokenType=\(activeTokenType)")
        return session
    }

    private func exchangeToken(authToken: String, endpoints: ChargePointEndpoints) async throws -> String {
        // Exchange auth-session JWT for coulomb_sess via portal endpoint
        // (same flow as python-chargepoint's login_with_sso_session)
        let portalBase = endpoints.portalDomainEndpoint.hasSuffix("/")
            ? endpoints.portalDomainEndpoint
            : endpoints.portalDomainEndpoint + "/"
        let exchangeURL = URL(string: "\(portalBase)index.php/nghelper/getSession")!
        var req = URLRequest(url: exchangeURL)
        req.httpMethod = "GET"
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("auth-session=\(authToken)", forHTTPHeaderField: "Cookie")

        print("ChargePoint: exchanging auth-session → coulomb_sess via \(exchangeURL)")
        let (data, response) = try await apiSession.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        print("ChargePoint: token exchange HTTP \(http.statusCode)")

        // Check cookie jar for coulomb_sess
        if let cookies = cookieStorage.cookies(for: exchangeURL),
           let coulomb = cookies.first(where: { $0.name == "coulomb_sess" }) {
            return coulomb.value
        }

        // Check Set-Cookie in response headers
        let allHeaders = http.allHeaderFields
        var setCookieStr = ""
        if let sc = allHeaders["Set-Cookie"] as? String { setCookieStr += sc }
        if let sc = allHeaders["set-cookie"] as? String { setCookieStr += "; " + sc }

        if let match = setCookieStr.range(of: "coulomb_sess=([^;]+)", options: .regularExpression) {
            return String(setCookieStr[match]).replacingOccurrences(of: "coulomb_sess=", with: "")
        }

        let body = String(data: data.prefix(300), encoding: .utf8) ?? ""
        print("ChargePoint: token exchange did not yield coulomb_sess. Body: \(body)")
        throw URLError(.userAuthenticationRequired)
    }

    private func discoverEndpoints(username: String) async throws -> ChargePointEndpoints {
        let url = URL(string: Self.discoveryURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["username": username])

        let (data, discoveryResponse) = try await apiSession.data(for: request)
        if let httpDisc = discoveryResponse as? HTTPURLResponse, httpDisc.statusCode != 200 {
            print("ChargePoint: discovery returned HTTP \(httpDisc.statusCode)")
            if let body = String(data: data, encoding: .utf8) {
                print("ChargePoint: discovery body = \(body.prefix(500))")
            }
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let endpoints = (json["endPoints"] ?? json["endpoints"]) as? [String: [String: Any]] else {
            print("ChargePoint: discovery response could not be parsed. Raw: \(String(data: data.prefix(500), encoding: .utf8) ?? "<non-utf8>")")
            throw URLError(.cannotParseResponse)
        }

        // Discovery endpoints sometimes come back without a trailing slash.
        // All URL construction below uses naive concatenation, so normalize here.
        func getValue(_ key: String) -> String {
            let v = (endpoints[key]?["value"] as? String) ?? ""
            if v.isEmpty || v.hasSuffix("/") { return v }
            return v + "/"
        }

        return ChargePointEndpoints(
            ssoEndpoint: getValue("sso_endpoint"),
            hcmEndpoint: getValue("hcpo_hcm_endpoint"),
            accountsEndpoint: getValue("accounts_endpoint"),
            driverBffEndpoint: getValue("internal_api_gateway_endpoint"),
            portalDomainEndpoint: getValue("portal_domain_endpoint"),
            mapcacheEndpoint: getValue("mapcache_endpoint"),
            region: json["region"] as? String ?? "NA"
        )
    }

    private func fetchChargers(session: ChargePointAPISession, accountIndex: Int, nickname: String) async throws -> [ChargePointCharger] {
        let url = URL(string: "\(session.endpoints.hcmEndpoint)api/v1/configuration/users/\(session.userId)/chargers")!
        var request = URLRequest(url: url)
        request.allHTTPHeaderFields = authHeaders(session)

        print("ChargePoint: fetching charger list from \(url)")
        let (data, response) = try await apiSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        print("ChargePoint: charger list HTTP \(http.statusCode)")
        guard http.statusCode == 200 else {
            if let body = String(data: data, encoding: .utf8) {
                print("ChargePoint: charger list body = \(body.prefix(500))")
            }
            throw URLError(.badServerResponse)
        }

        // Response could be a raw array, or wrapped in "data" or "chargers" key
        let items: [[String: Any]]
        if let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            items = arr
        } else if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = (obj["data"] ?? obj["chargers"]) as? [[String: Any]] {
            items = arr
        } else {
            let raw = String(data: data.prefix(500), encoding: .utf8) ?? "<non-utf8>"
            print("ChargePoint: charger list unexpected format: \(raw)")
            throw URLError(.cannotParseResponse)
        }

        var results: [ChargePointCharger] = []
        for item in items {
            guard let chargerId = item["id"] else { continue }
            let id = "\(chargerId)"
            if let charger = try? await fetchChargerStatus(session: session, chargerId: id, accountIndex: accountIndex, nickname: nickname) {
                results.append(charger)
            }
        }
        return results
    }

    private func fetchChargerStatus(session: ChargePointAPISession, chargerId: String, accountIndex: Int, nickname: String) async throws -> ChargePointCharger {
        let url = URL(string: "\(session.endpoints.hcmEndpoint)api/v1/configuration/users/\(session.userId)/chargers/\(chargerId)/status")!
        var request = URLRequest(url: url)
        request.allHTTPHeaderFields = authHeaders(session)

        let (data, response) = try await apiSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            print("ChargePoint: charger status HTTP \(http.statusCode) for \(chargerId) — \(body.prefix(300))")
            throw URLError(.badServerResponse)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let raw = String(data: data.prefix(300), encoding: .utf8) ?? "<non-utf8>"
            print("ChargePoint: charger status unexpected format for \(chargerId): \(raw)")
            throw URLError(.cannotParseResponse)
        }

        // ChargePoint flipped this endpoint from snake_case to camelCase. Read
        // the new keys first, fall back to the old ones so a future reversal
        // doesn't break us again.
        let rawStatus = (json["chargingStatus"] as? String)
            ?? (json["charging_status"] as? String)
            ?? ""
        let isPlugged = (json["isPluggedIn"] as? Bool)
            ?? (json["is_plugged_in"] as? Bool)
            ?? false

        // Amperage settings moved into a nested object. As of May 2026 the
        // keys are `chargeLimit` (current setting) and `possibleChargeLimit`
        // (array of allowed values). Older variants kept as fallback.
        let ampSettings = json["chargeAmperageSettings"] as? [String: Any]
        let possibleAmps = (ampSettings?["possibleChargeLimit"] as? [Int])
            ?? (ampSettings?["possibleAmperageLimits"] as? [Int])
            ?? (json["possible_amperage_limits"] as? [Int])
            ?? []
        let maxAmp = possibleAmps.max() ?? 40
        let amperage = (ampSettings?["chargeLimit"] as? Int)
            ?? (ampSettings?["amperageLimit"] as? Int)
            ?? (ampSettings?["chargeAmperageLimit"] as? Int)
            ?? (json["amperage_limit"] as? Int)
            ?? 0

        // power_kw / energy_kwh are not returned by this configuration endpoint
        // in the new API shape — live session telemetry needs a different call.
        let powerKw = json["power_kw"] as? Double ?? json["powerKw"] as? Double
        let energyKwh = json["energy_kwh"] as? Double ?? json["energyKwh"] as? Double

        // Diagnostic: remove once charging status + amperage are confirmed working.
        print("ChargePoint: charger \(chargerId) rawStatus=\"\(rawStatus)\" plugged=\(isPlugged) amps=\(amperage)/\(maxAmp) ampSettings=\(ampSettings ?? [:])")

        return ChargePointCharger(
            chargerId: chargerId,
            accountIndex: accountIndex,
            nickname: nickname,
            status: parseStatus(rawStatus),
            isPluggedIn: isPlugged,
            powerKw: powerKw,
            energyKwh: energyKwh,
            amperage: amperage,
            maxAmperage: maxAmp,
            lastUpdated: Date()
        )
    }

    private func parseStatus(_ raw: String) -> ChargingStatus {
        // Exact match on known values first — substring matching wrongly maps
        // "NOT_CHARGING" to .charging because it contains "charging".
        switch raw.uppercased() {
        case "CHARGING", "IN_USE":
            return .charging
        case "NOT_CHARGING", "PAUSED", "SCHEDULED", "WAITING_FOR_VEHICLE":
            return .pluggedIn
        case "FULLY_CHARGED", "COMPLETE", "DONE":
            return .complete
        case "AVAILABLE", "IDLE", "":
            return .idle
        default:
            break
        }
        // Substring fallback for unknown variants we haven't seen yet.
        let lower = raw.lowercased()
        if lower.contains("error") || lower.contains("fault") { return .error }
        if lower.contains("fully") || lower.contains("complete") { return .complete }
        if lower.contains("plugged") || lower.contains("connected") { return .pluggedIn }
        if lower.contains("charging") { return .charging }
        if lower.contains("available") || lower.contains("idle") { return .idle }
        return .unknown
    }

    private func authHeaders(_ session: ChargePointAPISession) -> [String: String] {
        var headers: [String: String] = [
            "User-Agent": Self.userAgent,
            "Content-Type": "application/json",
            "cp-region": session.endpoints.region,
        ]
        if session.tokenType == "auth-session" {
            // New JWT-based auth: use Authorization: Bearer
            headers["Authorization"] = "Bearer \(session.token)"
        } else {
            // Legacy coulomb_sess: cookie-based
            headers["Cookie"] = "coulomb_sess=\(session.token)"
            headers["cp-session-type"] = "CP_SESSION_TOKEN"
            headers["cp-session-token"] = session.token
        }
        return headers
    }

    private func saveCache() {
        if let data = try? JSONEncoder().encode(chargers) {
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        }
    }
}
