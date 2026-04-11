import Foundation
import Observation
import Security

// MARK: - Models
//
// iOS calls Resideo / Total Connect 2.0 directly — there is no server hop.
// Credentials live in the iOS Keychain, the topology (location names, zone
// names) is cached to Documents so it appears immediately on cold start, and
// only state bits get refreshed from rs.alarmnet.com on each poll. This
// matches the way the Lutron, MyQ, and SmartHQ integrations work in this app
// ("no server required").

enum AlarmPanelState: String {
    case disarmed
    case armedAway
    case armedHome
    case armedNight
    case alarming
    case arming
    case disarming
    case unknown

    var label: String {
        switch self {
        case .disarmed:   return "Disarmed"
        case .armedAway:  return "Armed Away"
        case .armedHome:  return "Armed Home"
        case .armedNight: return "Armed Night"
        case .alarming:   return "ALARMING"
        case .arming:     return "Arming…"
        case .disarming:  return "Disarming…"
        case .unknown:    return "Unknown"
        }
    }

    var icon: String {
        switch self {
        case .disarmed:               return "lock.open"
        case .armedAway:              return "lock.fill"
        case .armedHome:              return "house.lock.fill"
        case .armedNight:             return "moon.fill"
        case .alarming:               return "exclamationmark.triangle.fill"
        case .arming, .disarming:     return "lock.rotation"
        case .unknown:                return "questionmark.circle"
        }
    }

    var isTransitioning: Bool { self == .arming || self == .disarming }
    var isArmed: Bool { self == .armedAway || self == .armedHome || self == .armedNight }
}

struct AlarmPanel: Identifiable, Codable {
    var id: String { locationId }
    var locationId: String
    var securityDeviceId: String
    var name: String
    var state: AlarmPanelState
    var partitionIds: [Int]
    var lastUpdated: Date

    enum CodingKeys: String, CodingKey {
        case locationId, securityDeviceId, name, state, partitionIds, lastUpdated
    }

    init(locationId: String, securityDeviceId: String, name: String,
         state: AlarmPanelState, partitionIds: [Int], lastUpdated: Date) {
        self.locationId = locationId
        self.securityDeviceId = securityDeviceId
        self.name = name
        self.state = state
        self.partitionIds = partitionIds
        self.lastUpdated = lastUpdated
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        locationId       = try c.decode(String.self, forKey: .locationId)
        securityDeviceId = try c.decode(String.self, forKey: .securityDeviceId)
        name             = try c.decode(String.self, forKey: .name)
        let raw          = (try? c.decode(String.self, forKey: .state)) ?? "unknown"
        state            = AlarmPanelState(rawValue: raw) ?? .unknown
        partitionIds     = (try? c.decode([Int].self, forKey: .partitionIds)) ?? [1]
        let ts           = (try? c.decode(Double.self, forKey: .lastUpdated)) ?? 0
        lastUpdated      = Date(timeIntervalSince1970: ts)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(locationId, forKey: .locationId)
        try c.encode(securityDeviceId, forKey: .securityDeviceId)
        try c.encode(name, forKey: .name)
        try c.encode(state.rawValue, forKey: .state)
        try c.encode(partitionIds, forKey: .partitionIds)
        try c.encode(lastUpdated.timeIntervalSince1970, forKey: .lastUpdated)
    }
}

struct AlarmZone: Identifiable, Codable {
    var id: Int { zoneId }
    var zoneId: Int
    var name: String
    var faulted: Bool
    var bypassed: Bool
    var lowBattery: Bool
}

// MARK: - TC2 session (kept in-memory for the lifetime of an authenticated run)

private struct TCLocation {
    let locationId: String
    let securityDeviceId: String
    let name: String
    let partitionIds: [Int]
}

private struct TCSession {
    let token: String
    let appId: String
    let appVersion: String
    let locations: [TCLocation]
    let expiresAt: Date
}

// MARK: - Manager

@Observable
class TotalConnectManager: @unchecked Sendable {
    /// Cached panels (names + last known state). Survives relaunch via the
    /// Documents-directory topology cache; refreshed each time the poller
    /// runs against TC2.
    var panels: [AlarmPanel] = []

    /// Zones keyed by locationId. Same caching/refresh story as `panels`.
    var zones: [String: [AlarmZone]] = [:]

    var isLoading = false
    var errorMessage: String?

    /// True iff we have credentials stored AND either an active session or
    /// cached topology — i.e. the UI should show the panel list, not the
    /// credentials form.
    var isLinked: Bool { hasStoredCredentials && (!panels.isEmpty || session != nil) }

    private var session: TCSession?
    private var pollTimer: Timer?
    private let pollInterval: TimeInterval = 30
    private let sessionTTL: TimeInterval = 25 * 60   // tokens expire ~30 min

    // TC2 endpoints
    private let appConfigURL = "https://totalconnect2.com/application.config.json"
    private let tokenURL     = "https://rs.alarmnet.com/TC2API.Auth/token"
    private let apiBase      = "https://rs.alarmnet.com/TC2API.TCResource/"

    // Keychain keys for credentials
    private let kcUsername = "tc_username"
    private let kcPassword = "tc_password"
    private let kcUserCode = "tc_usercode"

    init() {
        loadCachedTopology()
    }

    // MARK: - Credentials (Keychain)

    private var hasStoredCredentials: Bool {
        guard let user = KeychainHelper.loadString(for: kcUsername),
              let pass = KeychainHelper.loadString(for: kcPassword),
              !user.isEmpty, !pass.isEmpty else { return false }
        return true
    }

    private func loadStoredCredentials() -> (username: String, password: String, userCode: String)? {
        guard let user = KeychainHelper.loadString(for: kcUsername),
              let pass = KeychainHelper.loadString(for: kcPassword),
              !user.isEmpty, !pass.isEmpty else { return nil }
        let pin = KeychainHelper.loadString(for: kcUserCode) ?? ""
        return (user, pass, pin)
    }

    private func storeCredentials(username: String, password: String, userCode: String) {
        KeychainHelper.save(username, for: kcUsername)
        KeychainHelper.save(password, for: kcPassword)
        KeychainHelper.save(userCode, for: kcUserCode)
    }

    private func clearCredentials() {
        KeychainHelper.delete(for: kcUsername)
        KeychainHelper.delete(for: kcPassword)
        KeychainHelper.delete(for: kcUserCode)
    }

    // MARK: - Public API

    /// Called from `LutronHomeApp` on scenePhase=active. If we have stored
    /// credentials, (re)authenticate and refresh state. Also kicks off the
    /// 30 s polling timer.
    func resume() {
        guard hasStoredCredentials else { return }
        Task { await loginAndFetch() }
        startPolling()
    }

    /// One-shot sign-in: takes the user-entered credentials, stores them in
    /// Keychain, then authenticates and fetches state. SettingsView calls
    /// this once when the user taps "Sign In", and zeros its local @State
    /// strings immediately afterwards so they don't outlive the call in
    /// memory.
    func signIn(username: String, password: String, userCode: String) async {
        await MainActor.run {
            isLoading = true
            errorMessage = nil
        }
        defer { Task { @MainActor in isLoading = false } }

        guard !username.isEmpty, !password.isEmpty else {
            await MainActor.run { errorMessage = "Enter your Total Connect username and password" }
            return
        }

        storeCredentials(username: username, password: password, userCode: userCode)
        await loginAndFetch()
        if session != nil { startPolling() }
    }

    func unlink() {
        stopPolling()
        session = nil
        clearCredentials()
        deleteCachedTopology()
        Task { @MainActor in
            panels = []
            zones = [:]
            errorMessage = nil
        }
    }

    func armAway(_ panel: AlarmPanel)  async { await armOrDisarm(panel: panel, action: .armAway) }
    func armHome(_ panel: AlarmPanel)  async { await armOrDisarm(panel: panel, action: .armHome) }
    func armNight(_ panel: AlarmPanel) async { await armOrDisarm(panel: panel, action: .armNight) }
    func disarm(_ panel: AlarmPanel)   async { await armOrDisarm(panel: panel, action: .disarm) }

    // MARK: - Polling

    func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { await self?.fetchStatus() }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Login + status fetch

    private func loginAndFetch() async {
        guard let creds = loadStoredCredentials() else { return }
        do {
            let sess = try await authenticate(username: creds.username, password: creds.password)
            session = sess

            // Seed/update panels from session locations using cached state
            // where available so the UI flips to "named, but unknown" before
            // the first fullStatus comes back.
            await MainActor.run {
                let cachedByLoc = Dictionary(uniqueKeysWithValues: panels.map { ($0.locationId, $0) })
                panels = sess.locations.map { loc in
                    let prev = cachedByLoc[loc.locationId]
                    return AlarmPanel(
                        locationId:       loc.locationId,
                        securityDeviceId: loc.securityDeviceId,
                        name:             loc.name,
                        state:            prev?.state ?? .unknown,
                        partitionIds:     loc.partitionIds,
                        lastUpdated:      Date()
                    )
                }
            }

            await fetchStatus()
        } catch {
            await MainActor.run { errorMessage = "Login failed: \(error.localizedDescription)" }
            print("TC2: login error — \(error)")
        }
    }

    private func ensureSession() async -> TCSession? {
        if let sess = session, sess.expiresAt > Date() { return sess }
        guard let creds = loadStoredCredentials() else { return nil }
        do {
            let sess = try await authenticate(username: creds.username, password: creds.password)
            session = sess
            return sess
        } catch {
            await MainActor.run { errorMessage = "Re-auth failed: \(error.localizedDescription)" }
            print("TC2: re-auth error — \(error)")
            return nil
        }
    }

    private func fetchStatus() async {
        guard let sess = await ensureSession() else { return }

        var newPanels: [AlarmPanel] = []
        var newZones: [String: [AlarmZone]] = [:]
        for loc in sess.locations {
            do {
                let (rawState, fetchedZones) = try await getPanelStatus(session: sess, locationId: loc.locationId)
                newPanels.append(AlarmPanel(
                    locationId:       loc.locationId,
                    securityDeviceId: loc.securityDeviceId,
                    name:             loc.name,
                    state:            mapArmingState(rawState),
                    partitionIds:     loc.partitionIds,
                    lastUpdated:      Date()
                ))
                newZones[loc.locationId] = fetchedZones
            } catch {
                print("TC2: fetchStatus error for \(loc.name) — \(error)")
                if "\(error)".contains("expired") || "\(error)".contains("401") {
                    session = nil
                }
            }
        }

        guard !newPanels.isEmpty else { return }

        await MainActor.run {
            panels = newPanels
            zones  = newZones
            errorMessage = nil
        }
        saveCachedTopology()
    }

    // MARK: - Arm / Disarm

    private enum AlarmAction { case armAway, armHome, armNight, disarm }

    private func armOrDisarm(panel: AlarmPanel, action: AlarmAction) async {
        guard let sess = await ensureSession() else {
            await MainActor.run { errorMessage = "Not signed in" }
            return
        }
        guard let creds = loadStoredCredentials() else { return }

        await MainActor.run {
            if let idx = panels.firstIndex(where: { $0.locationId == panel.locationId }) {
                panels[idx].state = (action == .disarm) ? .disarming : .arming
            }
        }

        do {
            switch action {
            case .disarm:
                try await sendDisarm(session: sess,
                                     locationId: panel.locationId,
                                     securityDeviceId: panel.securityDeviceId,
                                     userCode: creds.userCode,
                                     partitionIds: panel.partitionIds)
            case .armAway, .armHome, .armNight:
                let armType: Int = (action == .armAway) ? 0 : (action == .armHome ? 1 : 4)
                try await sendArm(session: sess,
                                  locationId: panel.locationId,
                                  securityDeviceId: panel.securityDeviceId,
                                  armType: armType,
                                  userCode: creds.userCode,
                                  partitionIds: panel.partitionIds)
            }
        } catch {
            await MainActor.run { errorMessage = "Action failed: \(error.localizedDescription)" }
            print("TC2: arm/disarm error — \(error)")
            await fetchStatus()
            return
        }

        try? await Task.sleep(nanoseconds: 3_000_000_000)
        await fetchStatus()
    }

    // MARK: - TC2 REST API
    //
    // Mirrors server/src/totalconnect/TotalConnectClient.ts. Any change to
    // the on-the-wire shape needs to be made in both places — see CLAUDE.md
    // for the rationale and the duplication trade-off (Position 2: iOS works
    // standalone, the cost is two implementations).

    private func authenticate(username: String, password: String) async throws -> TCSession {
        // Step 1: fetch app config (RSA key + clientId + AppID)
        guard let configUrl = URL(string: appConfigURL) else { throw URLError(.badURL) }
        let (configData, _) = try await URLSession.shared.data(from: configUrl)
        let configJson = try JSONSerialization.jsonObject(with: configData) as? [String: Any] ?? [:]

        // Top-level AppConfig holds the RSA key + client id; brandInfo holds
        // per-brand AppID. The earlier (broken) version of this code parsed
        // the response as an array of brand entries — that shape doesn't exist.
        let appConfigArr = configJson["AppConfig"] as? [[String: Any]] ?? []
        let appConfig    = appConfigArr.first ?? [:]
        let rsaSpkiB64   = appConfig["tc2APIKey"]    as? String ?? ""
        let clientId     = appConfig["tc2ClientId"]  as? String ?? ""

        let brandInfo = configJson["brandInfo"] as? [[String: Any]] ?? []
        let brandEntry = brandInfo.first(where: { ($0["BrandName"] as? String) == "totalconnect" })
                        ?? brandInfo.first ?? [:]
        let appId: String = {
            if let n = brandEntry["AppID"] as? NSNumber { return n.stringValue }
            if let s = brandEntry["AppID"] as? String   { return s }
            return ""
        }()
        let appVersion = (configJson["version"] as? String)
                       ?? (configJson["RevisionNumber"] as? String)
                       ?? "5.0.0"

        guard !rsaSpkiB64.isEmpty, !clientId.isEmpty else {
            throw NSError(domain: "TC2", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "Missing RSA key or clientId in app config"])
        }

        // Step 2: RSA-PKCS1v15 encrypt credentials.
        // tc2APIKey is base64 SPKI; Apple's SecKeyCreateWithData with
        // kSecAttrKeyTypeRSA wants raw PKCS#1 RSAPublicKey, so we strip the
        // SPKI wrapper before importing.
        let encUser = try rsaEncrypt(plaintext: username, spkiBase64: rsaSpkiB64)
        let encPass = try rsaEncrypt(plaintext: password, spkiBase64: rsaSpkiB64)

        // Step 3: OAuth2 password grant.
        //
        // The encrypted credentials are base64, which contains `+`, `/`, and
        // `=`. In application/x-www-form-urlencoded these MUST be percent-
        // encoded — `+` in particular is interpreted as a space by the form
        // parser, which corrupts the ciphertext and the server returns
        // "Authentication Failed". Swift's `.urlQueryAllowed` set treats `+`
        // as allowed (it's legal in a URL query) so we can't use it here;
        // we need form-body encoding rules, not URL-query rules. Use an
        // unreserved-only set (RFC 3986 section 2.3).
        guard let tokenUrl = URL(string: tokenURL) else { throw URLError(.badURL) }
        var tokenReq = URLRequest(url: tokenUrl)
        tokenReq.httpMethod = "POST"
        tokenReq.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encUserQ = encUser.addingPercentEncoding(withAllowedCharacters: unreserved) ?? encUser
        let encPassQ = encPass.addingPercentEncoding(withAllowedCharacters: unreserved) ?? encPass
        let body = "grant_type=password&client_id=\(clientId)&username=\(encUserQ)&password=\(encPassQ)"
        tokenReq.httpBody = body.data(using: .utf8)

        let (tokenData, tokenResp) = try await URLSession.shared.data(for: tokenReq)
        guard let http = tokenResp as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: tokenData, encoding: .utf8) ?? ""
            throw NSError(domain: "TC2", code: (tokenResp as? HTTPURLResponse)?.statusCode ?? 0,
                          userInfo: [NSLocalizedDescriptionKey: "Token request failed: \(msg)"])
        }
        let tokenJson = try JSONSerialization.jsonObject(with: tokenData) as? [String: Any] ?? [:]
        guard let token = tokenJson["access_token"] as? String, !token.isEmpty else {
            throw NSError(domain: "TC2", code: 0, userInfo: [NSLocalizedDescriptionKey: "No access_token in response"])
        }

        // Step 4: session details (URL query — `.urlQueryAllowed` is fine here)
        let appIdQ      = appId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? appId
        let appVersionQ = appVersion.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? appVersion
        let sessionUrlStr = "\(apiBase)api/v3/authentication/sessiondetails?appId=\(appIdQ)&appVersion=\(appVersionQ)"
        guard let sessionUrl = URL(string: sessionUrlStr) else { throw URLError(.badURL) }
        var sessionReq = URLRequest(url: sessionUrl)
        sessionReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (sessionData, sessionResp) = try await URLSession.shared.data(for: sessionReq)
        guard let shttp = sessionResp as? HTTPURLResponse, shttp.statusCode == 200 else {
            throw NSError(domain: "TC2", code: 0, userInfo: [NSLocalizedDescriptionKey: "Session details failed"])
        }
        let sessionJson = try JSONSerialization.jsonObject(with: sessionData) as? [String: Any] ?? [:]
        let rawLocations = ((sessionJson["SessionDetailsResult"] as? [String: Any])?["Locations"] as? [[String: Any]]) ?? []

        let locations: [TCLocation] = rawLocations.compactMap { loc in
            // Stringify locationId (TC2 returns it as a number)
            let locationId: String
            if let n = loc["LocationID"] as? NSNumber { locationId = n.stringValue }
            else if let s = loc["LocationID"] as? String { locationId = s }
            else { return nil }
            guard !locationId.isEmpty else { return nil }

            // Prefer the top-level SecurityDeviceID; fall back to the
            // security-class entry in DeviceList. Earlier (broken) version
            // looked for SecurityDevices[].DeviceID, which doesn't exist.
            var deviceId = ""
            if let n = loc["SecurityDeviceID"] as? NSNumber { deviceId = n.stringValue }
            else if let s = loc["SecurityDeviceID"] as? String { deviceId = s }
            if deviceId.isEmpty {
                if let devList = loc["DeviceList"] as? [[String: Any]] {
                    let secDev = devList.first(where: { ($0["DeviceClassID"] as? Int) == 1 })
                                ?? devList.first
                    if let n = secDev?["DeviceID"] as? NSNumber { deviceId = n.stringValue }
                    else if let s = secDev?["DeviceID"] as? String { deviceId = s }
                }
            }
            guard !deviceId.isEmpty else { return nil }

            let name = loc["LocationName"] as? String ?? "Home"
            let partitionIds = loc["PartitionIDs"] as? [Int] ?? [1]
            return TCLocation(locationId: locationId, securityDeviceId: deviceId,
                              name: name, partitionIds: partitionIds)
        }

        guard !locations.isEmpty else {
            throw NSError(domain: "TC2", code: 0, userInfo: [NSLocalizedDescriptionKey: "No alarm locations found"])
        }

        return TCSession(token: token, appId: appId, appVersion: appVersion,
                         locations: locations,
                         expiresAt: Date().addingTimeInterval(sessionTTL))
    }

    private func getPanelStatus(session: TCSession, locationId: String) async throws -> (Int, [AlarmZone]) {
        let urlStr = "\(apiBase)api/v3/locations/\(locationId)/partitions/fullStatus"
        guard let url = URL(string: urlStr) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 401 {
            throw NSError(domain: "TC2", code: 401, userInfo: [NSLocalizedDescriptionKey: "Session expired"])
        }
        guard http.statusCode == 200 else {
            throw NSError(domain: "TC2", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Status failed"])
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let panelStatus = json["PanelStatus"] as? [String: Any] ?? [:]
        let partitions  = panelStatus["Partitions"] as? [[String: Any]] ?? []
        let armingState = partitions.first?["ArmingState"] as? Int ?? 0

        let rawZones = panelStatus["Zones"] as? [[String: Any]] ?? []
        let fetchedZones = rawZones.map { z -> AlarmZone in
            let status = z["ZoneStatus"] as? Int ?? 0
            return AlarmZone(
                zoneId:     z["ZoneID"] as? Int ?? 0,
                name:       z["ZoneDescription"] as? String ?? "Zone \(z["ZoneID"] ?? "?")",
                faulted:    (status & 0x02) != 0,
                bypassed:   (status & 0x01) != 0,
                lowBattery: (status & 0x08) != 0
            )
        }

        return (armingState, fetchedZones)
    }

    private func sendArm(session: TCSession, locationId: String, securityDeviceId: String,
                         armType: Int, userCode: String, partitionIds: [Int]) async throws {
        let urlStr = "\(apiBase)api/v3/locations/\(locationId)/devices/\(securityDeviceId)/partitions/arm"
        guard let url = URL(string: urlStr) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "armType":    armType,
            "userCode":   Int(userCode) ?? 0,
            "partitions": partitionIds,
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "TC2", code: (resp as? HTTPURLResponse)?.statusCode ?? 0,
                          userInfo: [NSLocalizedDescriptionKey: "Arm failed: \(msg)"])
        }
    }

    private func sendDisarm(session: TCSession, locationId: String, securityDeviceId: String,
                            userCode: String, partitionIds: [Int]) async throws {
        let urlStr = "\(apiBase)api/v3/locations/\(locationId)/devices/\(securityDeviceId)/partitions/disArm"
        guard let url = URL(string: urlStr) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "userCode":   Int(userCode) ?? 0,
            "partitions": partitionIds,
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "TC2", code: (resp as? HTTPURLResponse)?.statusCode ?? 0,
                          userInfo: [NSLocalizedDescriptionKey: "Disarm failed: \(msg)"])
        }
    }

    // MARK: - State mapping

    private func mapArmingState(_ raw: Int) -> AlarmPanelState {
        switch raw {
        case 10200, 10211, 10214: return .disarmed
        case 10201, 10202, 10205, 10206: return .armedAway
        case 10203, 10204, 10209, 10210: return .armedHome
        case 10218, 10219, 10220, 10221: return .armedNight
        case 10207, 10208, 10212, 10213, 10215, 10216, 10217: return .alarming
        case 10307: return .arming
        case 10308: return .disarming
        default:    return .unknown
        }
    }

    // MARK: - RSA encrypt (with SPKI -> PKCS#1 unwrap)

    /// Encrypts `plaintext` with the Resideo RSA public key under PKCS#1 v1.5
    /// padding, returning a base64 string suitable for the OAuth password grant.
    ///
    /// `tc2APIKey` from application.config.json is base64 SPKI
    /// (`SubjectPublicKeyInfo`). Apple's Security framework, when invoked
    /// with `kSecAttrKeyTypeRSA` + `kSecAttrKeyClassPublic`, expects the raw
    /// PKCS#1 `RSAPublicKey` body — not SPKI. We strip the SPKI wrapper
    /// before importing.
    private func rsaEncrypt(plaintext: String, spkiBase64: String) throws -> String {
        let stripped = spkiBase64
            .replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        guard let spkiData = Data(base64Encoded: stripped) else {
            throw NSError(domain: "TC2", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid RSA key base64"])
        }

        guard let pkcs1 = stripSPKI(spkiData) else {
            throw NSError(domain: "TC2", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "Could not parse SPKI public key"])
        }

        let attrs: [CFString: Any] = [
            kSecAttrKeyType:  kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attrs as CFDictionary, &error) else {
            throw error!.takeRetainedValue() as Error
        }

        guard let plaintextData = plaintext.data(using: .utf8) else {
            throw NSError(domain: "TC2", code: 0, userInfo: [NSLocalizedDescriptionKey: "UTF-8 encoding failed"])
        }

        guard let encrypted = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, plaintextData as CFData, &error) else {
            throw error!.takeRetainedValue() as Error
        }
        return (encrypted as Data).base64EncodedString()
    }

    /// Walks an `SubjectPublicKeyInfo` ASN.1 structure and returns the inner
    /// PKCS#1 `RSAPublicKey` bytes. Returns nil if the input doesn't look
    /// like a well-formed RSA SPKI. Robust to RSA key sizes (does not assume
    /// a fixed 24-byte prefix).
    private func stripSPKI(_ spki: Data) -> Data? {
        let bytes = [UInt8](spki)
        var idx = 0

        func readLength(_ start: Int) -> (length: Int, lenBytes: Int)? {
            guard start < bytes.count else { return nil }
            let first = bytes[start]
            if first & 0x80 == 0 { return (Int(first), 1) }
            let n = Int(first & 0x7F)
            guard n > 0, start + n < bytes.count else { return nil }
            var len = 0
            for i in 0..<n {
                len = (len << 8) | Int(bytes[start + 1 + i])
            }
            return (len, 1 + n)
        }

        // Outer SEQUENCE
        guard idx < bytes.count, bytes[idx] == 0x30 else { return nil }
        idx += 1
        guard let outer = readLength(idx) else { return nil }
        idx += outer.lenBytes

        // AlgorithmIdentifier SEQUENCE — read length, skip body
        guard idx < bytes.count, bytes[idx] == 0x30 else { return nil }
        idx += 1
        guard let alg = readLength(idx) else { return nil }
        idx += alg.lenBytes
        idx += alg.length

        // BIT STRING containing the PKCS#1 RSAPublicKey
        guard idx < bytes.count, bytes[idx] == 0x03 else { return nil }
        idx += 1
        guard let bit = readLength(idx) else { return nil }
        idx += bit.lenBytes

        // First byte of the BIT STRING contents is the "unused bits" count;
        // for a public key it must be 0.
        guard idx < bytes.count, bytes[idx] == 0x00 else { return nil }
        idx += 1

        let pkcs1Len = bit.length - 1
        guard pkcs1Len > 0, idx + pkcs1Len <= bytes.count else { return nil }
        return Data(bytes[idx..<idx + pkcs1Len])
    }

    // MARK: - Topology cache (Documents/alarm-topology.json)
    //
    // Per-app, not in the repo, survives relaunches, wiped on app uninstall
    // and on `unlink()`. Stores only names and IDs — no credentials, no
    // session tokens, no PINs.

    private struct CachedTopology: Codable {
        var panels: [AlarmPanel]
        var zones: [String: [AlarmZone]]
    }

    private var topologyCacheURL: URL? {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("alarm-topology.json")
    }

    private func loadCachedTopology() {
        guard let url = topologyCacheURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(CachedTopology.self, from: data) else {
            return
        }
        // Force state to .unknown until we hear from TC2 — cached arming
        // state would be misleading after the app has been backgrounded for
        // hours.
        panels = cache.panels.map { p in
            var copy = p
            copy.state = .unknown
            return copy
        }
        zones = cache.zones
    }

    private func saveCachedTopology() {
        guard let url = topologyCacheURL else { return }
        let cache = CachedTopology(panels: panels, zones: zones)
        do {
            let data = try JSONEncoder().encode(cache)
            try data.write(to: url, options: .atomic)
        } catch {
            print("TC2: failed to write topology cache — \(error.localizedDescription)")
        }
    }

    private func deleteCachedTopology() {
        guard let url = topologyCacheURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
