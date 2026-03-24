import Foundation
import AuthenticationServices
import Observation

// MARK: - Models

struct MyUplinkTokens: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
}

struct HeatPumpStatus {
    var systemId: String = ""
    var deviceId: String = ""
    var systemName: String = ""

    // Temperatures
    var outdoorTemp: Double?          // °F
    var supplyLineTemp: Double?       // °F
    var returnLineTemp: Double?       // °F
    var brineInTemp: Double?          // °F (ground loop in)
    var brineOutTemp: Double?         // °F (ground loop out)
    var hotWaterTemp: Double?         // °F

    // Compressor
    var compressorFrequency: Double?  // Hz
    var operatingMode: String?        // Heating, Cooling, Hot Water, Off

    // Energy
    var currentPower: Double?         // kW

    // Smart home mode
    var smartHomeMode: String?        // "Away", "Home", "Default"

    var connected: Bool = false

    // Raw data points for display
    var dataPoints: [(name: String, value: String, unit: String, category: String)] = []
}

// MARK: - Manager

@Observable
class MyUplinkManager: @unchecked Sendable {
    var isLinked: Bool { tokens != nil }
    var heatPump = HeatPumpStatus()
    var isLoading = false
    var errorMessage: String?

    // Configuration — user fills these in from dev.myuplink.com
    var clientId: String {
        get { KeychainHelper.loadString(for: "mu_clientId") ?? "" }
        set { KeychainHelper.save(newValue, for: "mu_clientId") }
    }
    var clientSecret: String {
        get { KeychainHelper.loadString(for: "mu_clientSecret") ?? "" }
        set { KeychainHelper.save(newValue, for: "mu_clientSecret") }
    }

    private let baseURL = "https://api.myuplink.com"
    private let authURL = "https://api.myuplink.com/oauth/authorize"
    private let tokenURL = "https://api.myuplink.com/oauth/token"
    private let redirectScheme = "com.jasongelman.lutronhome"
    private let redirectURI = "com.jasongelman.lutronhome://oauth/myuplink"

    private var tokens: MyUplinkTokens? {
        didSet { saveTokens() }
    }
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
            URLQueryItem(name: "scope", value: "READSYSTEM WRITESYSTEM offline_access"),
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
                print("myUplink: token exchange failed — \(String(data: data, encoding: .utf8) ?? "")")
                return
            }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let accessToken = json["access_token"] as? String ?? ""
            let refreshToken = json["refresh_token"] as? String ?? ""
            let expiresIn = json["expires_in"] as? Int ?? 3600

            tokens = MyUplinkTokens(
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn - 60))
            )
            errorMessage = nil
            print("myUplink: OAuth complete, token expires in \(expiresIn)s")

            await fetchSystems()
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
                print("myUplink: token refresh failed")
                tokens = nil
                return false
            }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            tokens = MyUplinkTokens(
                accessToken: json["access_token"] as? String ?? "",
                refreshToken: json["refresh_token"] as? String ?? currentTokens.refreshToken,
                expiresAt: Date().addingTimeInterval(TimeInterval((json["expires_in"] as? Int ?? 3600) - 60))
            )
            return true
        } catch {
            print("myUplink: token refresh error — \(error)")
            return false
        }
    }

    func unlink() {
        tokens = nil
        pollTimer?.invalidate()
        pollTimer = nil
        heatPump = HeatPumpStatus()
        KeychainHelper.delete(for: "mu_tokens")
    }

    // MARK: - API Requests

    private func apiRequest(_ path: String, method: String = "GET") async throws -> Any {
        guard await refreshTokenIfNeeded(), let tok = tokens else {
            throw URLError(.userAuthenticationRequired)
        }

        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        request.httpMethod = method
        request.setValue("Bearer \(tok.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw URLError(.badServerResponse, userInfo: ["statusCode": code])
        }

        return try JSONSerialization.jsonObject(with: data)
    }

    // MARK: - System Discovery

    func fetchSystems() async {
        do {
            let json = try await apiRequest("/v2/systems/me")
            guard let result = json as? [String: Any],
                  let systems = result["systems"] as? [[String: Any]],
                  let system = systems.first else {
                print("myUplink: no systems found")
                return
            }

            heatPump.systemId = system["systemId"] as? String ?? ""
            heatPump.systemName = system["name"] as? String ?? "Heat Pump"

            // Find first device in system
            if let devices = system["devices"] as? [[String: Any]], let device = devices.first {
                heatPump.deviceId = device["id"] as? String ?? ""
                print("myUplink: found device '\(heatPump.systemName)' (id: \(heatPump.deviceId))")
                await fetchDataPoints()
            }
        } catch {
            errorMessage = "Failed to fetch systems"
            print("myUplink: fetchSystems error — \(error)")
        }
    }

    // MARK: - Data Points

    func fetchDataPoints() async {
        guard !heatPump.deviceId.isEmpty else { return }

        do {
            let json = try await apiRequest("/v2/devices/\(heatPump.deviceId)/points")
            guard let points = json as? [[String: Any]] else { return }

            var dataPoints: [(name: String, value: String, unit: String, category: String)] = []

            for point in points {
                let parameterName = point["parameterName"] as? String ?? ""
                let category = point["category"] as? String ?? ""
                let value = point["value"] as? Double
                let strValue = point["strVal"] as? String ?? ""
                let unit = point["parameterUnit"] as? String ?? ""
                let parameterId = point["parameterId"] as? Int ?? 0

                let displayValue: String
                if !strValue.isEmpty {
                    displayValue = strValue
                } else if let v = value {
                    displayValue = unit == "°C" ? String(format: "%.1f", celsiusToFahrenheit(v)) : String(format: "%.1f", v)
                } else {
                    displayValue = "—"
                }

                let displayUnit = unit == "°C" ? "°F" : unit

                dataPoints.append((name: parameterName, value: displayValue, unit: displayUnit, category: category))

                // Map known parameters
                if let v = value {
                    switch parameterId {
                    case 40004: heatPump.outdoorTemp = celsiusToFahrenheit(v)
                    case 40008: heatPump.supplyLineTemp = celsiusToFahrenheit(v)
                    case 40012: heatPump.returnLineTemp = celsiusToFahrenheit(v)
                    default: break
                    }

                    // Try to detect by name
                    let lower = parameterName.lowercased()
                    if lower.contains("brine in") || lower.contains("brine pump inlet") {
                        heatPump.brineInTemp = celsiusToFahrenheit(v)
                    } else if lower.contains("brine out") || lower.contains("brine pump outlet") {
                        heatPump.brineOutTemp = celsiusToFahrenheit(v)
                    } else if lower.contains("hot water") && lower.contains("top") {
                        heatPump.hotWaterTemp = celsiusToFahrenheit(v)
                    } else if lower.contains("compressor frequency") || lower.contains("current compr") {
                        heatPump.compressorFrequency = v
                    } else if lower.contains("current power") || lower.contains("electric power") {
                        heatPump.currentPower = v
                    }
                }

                // Operating mode
                let lower = parameterName.lowercased()
                if lower.contains("priority") || lower.contains("operating mode") {
                    if !strValue.isEmpty {
                        heatPump.operatingMode = strValue
                    }
                }
            }

            heatPump.dataPoints = dataPoints
            heatPump.connected = true
            errorMessage = nil
            print("myUplink: fetched \(dataPoints.count) data points")
        } catch {
            print("myUplink: fetchDataPoints error — \(error)")
        }
    }

    // MARK: - Smart Home Mode

    func setSmartHomeMode(_ mode: String) async {
        guard !heatPump.systemId.isEmpty, let tok = tokens else { return }

        var request = URLRequest(url: URL(string: "\(baseURL)/v2/systems/\(heatPump.systemId)/smart-home-mode")!)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(tok.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = ["smartHomeMode": mode]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) {
                heatPump.smartHomeMode = mode
                print("myUplink: smart home mode set to \(mode)")
            }
        } catch {
            print("myUplink: setSmartHomeMode error — \(error)")
        }
    }

    // MARK: - Polling

    func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { await self?.fetchDataPoints() }
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
            if heatPump.deviceId.isEmpty {
                await fetchSystems()
            } else {
                await fetchDataPoints()
            }
            startPolling()
        }
    }

    // MARK: - Helpers

    private func celsiusToFahrenheit(_ c: Double) -> Double {
        (c * 9.0 / 5.0) + 32.0
    }

    // MARK: - Token Persistence

    private func saveTokens() {
        guard let tokens else {
            KeychainHelper.delete(for: "mu_tokens")
            return
        }
        KeychainHelper.save(tokens, for: "mu_tokens")
    }

    private func loadTokens() {
        // Migrate from UserDefaults if present
        if let data = UserDefaults.standard.data(forKey: "mu_tokens"),
           let saved = try? JSONDecoder().decode(MyUplinkTokens.self, from: data) {
            tokens = saved
            UserDefaults.standard.removeObject(forKey: "mu_tokens")
            return
        }
        tokens = KeychainHelper.load(MyUplinkTokens.self, for: "mu_tokens")
    }
}
