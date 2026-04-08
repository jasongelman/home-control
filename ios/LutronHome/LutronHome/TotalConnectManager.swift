import Foundation
import Observation
import Security

// MARK: - Models

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

struct AlarmPanel: Identifiable {
    var id: String { locationId }
    var locationId: String
    var securityDeviceId: String
    var name: String
    var state: AlarmPanelState
    var partitionIds: [Int]
    var lastUpdated: Date
}

struct AlarmZone: Identifiable {
    var id: Int { zoneId }
    var zoneId: Int
    var name: String
    var faulted: Bool
    var bypassed: Bool
    var lowBattery: Bool
}

// MARK: - TC2 Session

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
    var isLinked: Bool { !username.isEmpty && !password.isEmpty }
    var panels: [AlarmPanel] = []
    var zones: [String: [AlarmZone]] = [:]  // keyed by locationId
    var isLoading = false
    var errorMessage: String?

    var username: String {
        get { KeychainHelper.loadString(for: "tc_username") ?? "" }
        set { KeychainHelper.save(newValue, for: "tc_username") }
    }
    var password: String {
        get { KeychainHelper.loadString(for: "tc_password") ?? "" }
        set { KeychainHelper.save(newValue, for: "tc_password") }
    }
    var userCode: String {
        get { KeychainHelper.loadString(for: "tc_usercode") ?? "" }
        set { KeychainHelper.save(newValue, for: "tc_usercode") }
    }

    private let appConfigURL  = "https://totalconnect2.com/application.config.json"
    private let tokenURL      = "https://rs.alarmnet.com/TC2API.Auth/token"
    private let apiBase       = "https://rs.alarmnet.com/TC2API.TCResource/"

    private var session: TCSession?
    private var pollTimer: Timer?

    init() {}

    // MARK: - Auth

    func login() async {
        guard !username.isEmpty, !password.isEmpty else {
            errorMessage = "Enter your Total Connect username and password"
            return
        }
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil

        do {
            let sess = try await authenticate(username: username, password: password)
            session = sess
            await fetchStatus()
            startPolling()
        } catch {
            errorMessage = "Login failed: \(error.localizedDescription)"
            print("TC2: login error — \(error)")
        }
    }

    func unlink() {
        session = nil
        stopPolling()
        panels = []
        zones = [:]
        KeychainHelper.delete(for: "tc_username")
        KeychainHelper.delete(for: "tc_password")
        KeychainHelper.delete(for: "tc_usercode")
        errorMessage = nil
    }

    // MARK: - Status

    func fetchStatus() async {
        guard let sess = session else { return }

        do {
            for loc in sess.locations {
                let (armingState, fetchedZones) = try await getPanelStatus(session: sess, locationId: loc.locationId)
                let state = mapArmingState(armingState)

                await MainActor.run {
                    if let idx = panels.firstIndex(where: { $0.locationId == loc.locationId }) {
                        panels[idx].state = state
                        panels[idx].lastUpdated = Date()
                    } else {
                        panels.append(AlarmPanel(
                            locationId:       loc.locationId,
                            securityDeviceId: loc.securityDeviceId,
                            name:             loc.name,
                            state:            state,
                            partitionIds:     loc.partitionIds,
                            lastUpdated:      Date()
                        ))
                    }
                    zones[loc.locationId] = fetchedZones
                }
            }
        } catch {
            print("TC2: fetchStatus error — \(error)")
            if "\(error)".contains("expired") || "\(error)".contains("401") {
                session = nil
            }
        }
    }

    // MARK: - Control

    func armAway(_ panel: AlarmPanel) async { await arm(panel, armType: 0) }
    func armHome(_ panel: AlarmPanel)  async { await arm(panel, armType: 1) }
    func armNight(_ panel: AlarmPanel) async { await arm(panel, armType: 4) }

    func disarm(_ panel: AlarmPanel) async {
        guard let sess = session else { return }
        updateOptimisticState(locationId: panel.locationId, state: .disarming)
        do {
            try await sendDisarm(session: sess, locationId: panel.locationId,
                                 securityDeviceId: panel.securityDeviceId,
                                 userCode: userCode,
                                 partitionIds: panel.partitionIds)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await fetchStatus()
        } catch {
            errorMessage = "Disarm failed: \(error.localizedDescription)"
            print("TC2: disarm error — \(error)")
            await fetchStatus()
        }
    }

    private func arm(_ panel: AlarmPanel, armType: Int) async {
        guard let sess = session else { return }
        updateOptimisticState(locationId: panel.locationId, state: .arming)
        do {
            try await sendArm(session: sess, locationId: panel.locationId,
                              securityDeviceId: panel.securityDeviceId,
                              armType: armType,
                              userCode: userCode,
                              partitionIds: panel.partitionIds)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await fetchStatus()
        } catch {
            errorMessage = "Arm failed: \(error.localizedDescription)"
            print("TC2: arm error — \(error)")
            await fetchStatus()
        }
    }

    private func updateOptimisticState(locationId: String, state: AlarmPanelState) {
        if let idx = panels.firstIndex(where: { $0.locationId == locationId }) {
            panels[idx].state = state
        }
    }

    // MARK: - Polling

    func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { await self?.fetchStatus() }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func resume() {
        guard isLinked, session == nil else {
            if isLinked { Task { await fetchStatus() } }
            return
        }
        Task { await login() }
    }

    // MARK: - TC2 REST API

    private func authenticate(username: String, password: String) async throws -> TCSession {
        // Step 1: fetch app config (RSA key + clientId)
        guard let configUrl = URL(string: appConfigURL) else { throw URLError(.badURL) }
        let (configData, _) = try await URLSession.shared.data(from: configUrl)
        let configArray = try JSONSerialization.jsonObject(with: configData) as? [[String: Any]] ?? []
        let appEntry = configArray.first(where: { ($0["BrandName"] as? String) == "totalconnect" })
                       ?? configArray.first ?? [:]
        let appConfig  = (appEntry["AppConfig"] as? [[String: Any]])?.first ?? [:]
        let rsaKey     = appConfig["tc2APIKey"] as? String ?? ""
        let clientId   = appConfig["tc2ClientId"] as? String ?? ""
        let appId      = appEntry["AppID"] as? String ?? ""
        let appVersion = appEntry["appVersion"] as? String ?? "5.0.0"

        guard !rsaKey.isEmpty, !clientId.isEmpty else {
            throw NSError(domain: "TC2", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "Missing RSA key or clientId in app config"])
        }

        // Step 2: RSA-encrypt credentials
        let encUser = try rsaEncrypt(plaintext: username, pemKey: rsaKey)
        let encPass = try rsaEncrypt(plaintext: password, pemKey: rsaKey)

        // Step 3: OAuth2 password grant
        guard let tokenUrl = URL(string: tokenURL) else { throw URLError(.badURL) }
        var tokenReq = URLRequest(url: tokenUrl)
        tokenReq.httpMethod = "POST"
        tokenReq.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "grant_type=password&client_id=\(clientId)&username=\(encUser.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? encUser)&password=\(encPass.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? encPass)"
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

        // Step 4: session details
        let sessionUrlStr = "\(apiBase)api/v3/authentication/sessiondetails?appId=\(appId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? appId)&appVersion=\(appVersion.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? appVersion)"
        guard let sessionUrl = URL(string: sessionUrlStr) else { throw URLError(.badURL) }
        var sessionReq = URLRequest(url: sessionUrl)
        sessionReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (sessionData, sessionResp) = try await URLSession.shared.data(for: sessionReq)
        guard let shttp = sessionResp as? HTTPURLResponse, shttp.statusCode == 200 else {
            throw NSError(domain: "TC2", code: 0, userInfo: [NSLocalizedDescriptionKey: "Session details failed"])
        }
        let sessionJson = try JSONSerialization.jsonObject(with: sessionData) as? [String: Any] ?? [:]
        let rawLocations = ((sessionJson["SessionDetailsResult"] as? [String: Any])?["Locations"] as? [[String: Any]]) ?? []

        let locations = rawLocations.compactMap { loc -> TCLocation? in
            guard let locationId = loc["LocationID"].map(String.init(describing:)), !locationId.isEmpty,
                  let devices = loc["SecurityDevices"] as? [[String: Any]],
                  let firstDevice = devices.first,
                  let deviceId = firstDevice["DeviceID"].map(String.init(describing:)), !deviceId.isEmpty
            else { return nil }
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
                         expiresAt: Date().addingTimeInterval(25 * 60))
    }

    private func getPanelStatus(session: TCSession, locationId: String) async throws -> (Int, [AlarmZone]) {
        let urlStr = "\(apiBase)api/v3/locations/\(locationId)/partitions/fullStatus"
        guard let url = URL(string: urlStr) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 401 { throw NSError(domain: "TC2", code: 401, userInfo: [NSLocalizedDescriptionKey: "Session expired"]) }
        guard http.statusCode == 200 else { throw NSError(domain: "TC2", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Status failed"]) }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let panelStatus = json["PanelStatus"] as? [String: Any] ?? [:]
        let partitions  = panelStatus["Partitions"] as? [[String: Any]] ?? []
        let armingState = partitions.first?["ArmingState"] as? Int ?? 0

        let rawZones = panelStatus["Zones"] as? [[String: Any]] ?? []
        let zones = rawZones.map { z -> AlarmZone in
            let status = z["ZoneStatus"] as? Int ?? 0
            return AlarmZone(
                zoneId:     z["ZoneID"] as? Int ?? 0,
                name:       z["ZoneDescription"] as? String ?? "Zone \(z["ZoneID"] ?? "?")",
                faulted:    (status & 0x02) != 0,
                bypassed:   (status & 0x01) != 0,
                lowBattery: (status & 0x08) != 0
            )
        }

        return (armingState, zones)
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
            "armType":   armType,
            "userCode":  Int(userCode) ?? 0,
            "partitions": partitionIds
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
            "userCode":  Int(userCode) ?? 0,
            "partitions": partitionIds
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "TC2", code: (resp as? HTTPURLResponse)?.statusCode ?? 0,
                          userInfo: [NSLocalizedDescriptionKey: "Disarm failed: \(msg)"])
        }
    }

    // MARK: - Helpers

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

    /// RSA PKCS1 v1.5 encrypt plaintext with a PEM-formatted RSA public key.
    private func rsaEncrypt(plaintext: String, pemKey: String) throws -> String {
        // Strip PEM headers and decode base64
        let stripped = pemKey
            .replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----BEGIN RSA PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END RSA PUBLIC KEY-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()

        guard let keyData = Data(base64Encoded: stripped) else {
            throw NSError(domain: "TC2", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid RSA key base64"])
        }

        // Import key
        let keyDict: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
        ]
        var error: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(keyData as CFData, keyDict as CFDictionary, &error) else {
            throw error!.takeRetainedValue() as Error
        }

        guard let plaintextData = plaintext.data(using: .utf8) else {
            throw NSError(domain: "TC2", code: 0, userInfo: [NSLocalizedDescriptionKey: "UTF-8 encoding failed"])
        }

        guard let encrypted = SecKeyCreateEncryptedData(secKey, .rsaEncryptionPKCS1, plaintextData as CFData, &error) else {
            throw error!.takeRetainedValue() as Error
        }

        return (encrypted as Data).base64EncodedString()
    }
}
