import Foundation
import Observation

// MARK: - Models

enum MyQDoorState: String {
    case open
    case closed
    case opening
    case closing
    case stopped
    case transition
    case unknown

    var label: String {
        switch self {
        case .open:       return "Open"
        case .closed:     return "Closed"
        case .opening:    return "Opening"
        case .closing:    return "Closing"
        case .stopped:    return "Stopped"
        case .transition: return "Moving"
        case .unknown:    return "Unknown"
        }
    }

    var icon: String {
        switch self {
        case .open:             return "door.garage.open"
        case .closed:           return "door.garage.closed"
        case .opening, .transition: return "door.garage.open"
        case .closing:          return "door.garage.closed"
        case .stopped:          return "exclamationmark.triangle.fill"
        case .unknown:          return "questionmark.circle"
        }
    }

    var isMoving: Bool {
        self == .opening || self == .closing || self == .transition
    }
}

struct MyQDoor: Identifiable {
    var id: String { serialNumber }
    var serialNumber: String
    var name: String
    var state: MyQDoorState
    var online: Bool
}

struct MyQTokens: Codable {
    let accessToken: String
    let refreshToken: String
    let accountId: String
    let expiresAt: Date
}

// MARK: - Manager

@Observable
class MyQManager: @unchecked Sendable {
    var isLinked: Bool { tokens != nil }
    var doors: [MyQDoor] = []
    var isLoading = false
    var errorMessage: String?

    var email: String {
        get { KeychainHelper.loadString(for: "myq_email") ?? "" }
        set { KeychainHelper.save(newValue, for: "myq_email") }
    }
    var password: String {
        get { KeychainHelper.loadString(for: "myq_password") ?? "" }
        set { KeychainHelper.save(newValue, for: "myq_password") }
    }

    // Chamberlain moved auth to an OAuth2 identity server (partner-identity)
    private let tokenURL    = "https://partner-identity.myq-cloud.com/connect/token"
    private let accountsURL = "https://account.myq-cloud.com/api/v6/accounts"
    private let devicesBase = "https://devices.myq-cloud.com/api/v5.2"
    private let actionsBase = "https://account.myq-cloud.com/api/v6"
    // Client credentials from community reverse engineering of the iOS MyQ app
    private let clientId     = "IOS_CGO"
    private let clientSecret = "VUKdMGBPRCAnfZGIWY8SJWvnbWJNyJmjklAlDyPDYS8="
    private let userAgent    = "myQ/23050.06 CFNetwork/1399 Darwin/22.1.0"

    private var tokens: MyQTokens? {
        didSet { saveTokens() }
    }
    private var pollTimer: Timer?

    init() {
        loadTokens()
    }

    // MARK: - Authentication

    func login() async {
        guard !email.isEmpty, !password.isEmpty else {
            errorMessage = "Enter your MyQ email and password"
            return
        }

        isLoading = true
        defer { isLoading = false }
        errorMessage = nil

        // Step 1: OAuth2 password grant → access + refresh tokens
        guard let url = URL(string: tokenURL) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let encodedEmail = email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? email
        let encodedPass  = password.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? password
        req.httpBody = [
            "grant_type=password",
            "client_id=\(clientId)",
            "client_secret=\(clientSecret)",
            "username=\(encodedEmail)",
            "password=\(encodedPass)",
            "scope=MyQ_Residential%20offline_access"
        ].joined(separator: "&").data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                errorMessage = "Invalid response from MyQ"
                return
            }

            guard http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                errorMessage = http.statusCode == 400 ? "Invalid email or password"
                    : http.statusCode == 403 ? "MyQ has blocked third-party access"
                    : "Login failed (HTTP \(http.statusCode))"
                print("MyQ: token request failed \(http.statusCode) — \(body)")
                return
            }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let accessToken  = json["access_token"]  as? String ?? ""
            let refreshToken = json["refresh_token"] as? String ?? ""
            let expiresIn    = json["expires_in"]    as? Int ?? 3600
            guard !accessToken.isEmpty else {
                errorMessage = "Login succeeded but received no token"
                print("MyQ: token response keys: \(json.keys.joined(separator: ", "))")
                return
            }

            // Step 2: Fetch account ID
            guard let accountId = await fetchAccountId(accessToken: accessToken) else {
                errorMessage = "Could not retrieve MyQ account info"
                return
            }

            tokens = MyQTokens(
                accessToken: accessToken,
                refreshToken: refreshToken,
                accountId: accountId,
                expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn - 60))
            )
            print("MyQ: login successful, accountId=\(accountId)")
            await fetchDevices()
            startPolling()

        } catch {
            errorMessage = "Login error: \(error.localizedDescription)"
            print("MyQ: login error — \(error)")
        }
    }

    private func fetchAccountId(accessToken: String) async -> String? {
        guard let url = URL(string: accountsURL) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                print("MyQ: fetchAccountId HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return nil
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            // Response shape: {"accounts": [{"id": "...", ...}]}
            if let accounts = json["accounts"] as? [[String: Any]], let first = accounts.first {
                return first["id"] as? String
            }
            // Fallback: bare array
            if let accounts = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let first = accounts.first {
                return first["id"] as? String
            }
            print("MyQ: fetchAccountId unexpected shape — keys: \(json.keys.joined(separator: ", "))")
            return nil
        } catch {
            print("MyQ: fetchAccountId error — \(error)")
            return nil
        }
    }

    private func refreshTokenIfNeeded() async -> Bool {
        guard let tok = tokens else { return false }
        guard Date() >= tok.expiresAt else { return true }

        guard let url = URL(string: tokenURL) else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.httpBody = [
            "grant_type=refresh_token",
            "client_id=\(clientId)",
            "client_secret=\(clientSecret)",
            "refresh_token=\(tok.refreshToken)"
        ].joined(separator: "&").data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                tokens = nil
                return false
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let newAccess  = json["access_token"]  as? String ?? ""
            let newRefresh = json["refresh_token"] as? String ?? tok.refreshToken
            let expiresIn  = json["expires_in"]    as? Int ?? 3600
            guard !newAccess.isEmpty else { tokens = nil; return false }
            tokens = MyQTokens(
                accessToken: newAccess,
                refreshToken: newRefresh,
                accountId: tok.accountId,
                expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn - 60))
            )
            return true
        } catch {
            print("MyQ: token refresh error — \(error)")
            return false
        }
    }

    func unlink() {
        tokens = nil
        pollTimer?.invalidate()
        pollTimer = nil
        doors = []
        KeychainHelper.delete(for: "myq_tokens")
        errorMessage = nil
    }

    // MARK: - Devices

    func fetchDevices() async {
        guard await refreshTokenIfNeeded(), let tok = tokens else { return }

        let path = "\(devicesBase)/Accounts/\(tok.accountId)/Devices"
        guard let url = URL(string: path) else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(tok.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return }

            if http.statusCode == 200 {
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                let items = json["items"] as? [[String: Any]] ?? []
                parseDevices(items)
            } else if http.statusCode == 401 {
                tokens = nil
                errorMessage = "Session expired. Please sign in again."
                print("MyQ: 401 fetching devices")
            } else {
                print("MyQ: fetchDevices HTTP \(http.statusCode)")
            }
        } catch {
            print("MyQ: fetchDevices error — \(error)")
        }
    }

    private func parseDevices(_ items: [[String: Any]]) {
        var found: [MyQDoor] = []
        for item in items {
            let deviceFamily = item["device_family"] as? String ?? ""
            let deviceType   = item["device_type"]   as? String ?? ""
            let serial       = item["serial_number"] as? String ?? ""
            let name         = item["name"]           as? String ?? "Garage Door"
            let online       = (item["state"] as? [String: Any])?["online"]     as? Bool   ?? false
            let stateStr     = (item["state"] as? [String: Any])?["door_state"] as? String ?? "unknown"

            let isGarage = deviceFamily.contains("garagedoor") || deviceFamily.contains("garage_door")
                || deviceFamily.contains("vehicle_gate") || deviceType.contains("GarageDoorOpener")
                || deviceType.contains("VGDO")
            guard isGarage, !serial.isEmpty else { continue }

            found.append(MyQDoor(serialNumber: serial, name: name,
                                 state: MyQDoorState(rawValue: stateStr) ?? .unknown,
                                 online: online))
        }
        doors = found
        print("MyQ: found \(found.count) garage door(s) among \(items.count) total devices")
    }

    // MARK: - Control

    func openDoor(_ door: MyQDoor) async {
        await sendAction("open", for: door)
    }

    func closeDoor(_ door: MyQDoor) async {
        await sendAction("close", for: door)
    }

    private func sendAction(_ action: String, for door: MyQDoor) async {
        guard await refreshTokenIfNeeded(), let tok = tokens else { return }

        let path = "\(actionsBase)/Accounts/\(tok.accountId)/Devices/\(door.serialNumber)/actions"
        guard let url = URL(string: path) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("Bearer \(tok.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["action_type": action])

        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("MyQ: \(action) '\(door.name)' — HTTP \(status)")
            if let idx = doors.firstIndex(where: { $0.id == door.id }) {
                doors[idx].state = action == "open" ? .opening : .closing
            }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await fetchDevices()
        } catch {
            print("MyQ: action '\(action)' error — \(error)")
        }
    }

    // MARK: - Polling

    func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { await self?.fetchDevices() }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func resume() {
        guard isLinked else { return }
        Task {
            await fetchDevices()
            startPolling()
        }
    }

    // MARK: - Persistence

    private func saveTokens() {
        guard let tokens else {
            KeychainHelper.delete(for: "myq_tokens")
            return
        }
        KeychainHelper.save(tokens, for: "myq_tokens")
    }

    private func loadTokens() {
        tokens = KeychainHelper.load(MyQTokens.self, for: "myq_tokens")
    }
}
