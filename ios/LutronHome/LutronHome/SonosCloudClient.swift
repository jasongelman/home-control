import Foundation
import AuthenticationServices
import Network

actor SonosCloudClient {

    // MARK: - Token State

    private(set) var accessToken: String?
    private(set) var refreshToken: String?
    private(set) var clientId: String?
    private(set) var clientSecret: String?
    private(set) var householdId: String?
    private var tokenExpiresAt: Date?

    // Keychain keys
    private enum Keys {
        static let accessToken = "sonos-accessToken"
        static let refreshToken = "sonos-refreshToken"
        static let clientId = "sonos-clientId"
        static let clientSecret = "sonos-clientSecret"
    }

    // UserDefaults keys
    private enum DefaultsKeys {
        static let tokenExpiresAt = "sonos-tokenExpiresAt"
        static let householdId = "sonos-householdId"
    }

    var isLinked: Bool { accessToken != nil }

    // MARK: - Init

    init() {
        accessToken = KeychainHelper.loadString(for: Keys.accessToken)
        refreshToken = KeychainHelper.loadString(for: Keys.refreshToken)
        clientId = KeychainHelper.loadString(for: Keys.clientId)
        clientSecret = KeychainHelper.loadString(for: Keys.clientSecret)
        householdId = UserDefaults.standard.string(forKey: DefaultsKeys.householdId)
        if let interval = UserDefaults.standard.object(forKey: DefaultsKeys.tokenExpiresAt) as? Double {
            tokenExpiresAt = Date(timeIntervalSince1970: interval)
        }
    }

    // MARK: - Credential Management

    func setClientCredentials(clientId: String, clientSecret: String) {
        self.clientId = clientId
        self.clientSecret = clientSecret
        KeychainHelper.save(clientId, for: Keys.clientId)
        KeychainHelper.save(clientSecret, for: Keys.clientSecret)
    }

    func unlink() {
        accessToken = nil
        refreshToken = nil
        tokenExpiresAt = nil
        householdId = nil
        KeychainHelper.delete(for: Keys.accessToken)
        KeychainHelper.delete(for: Keys.refreshToken)
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.tokenExpiresAt)
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.householdId)
    }

    // MARK: - OAuth Flow

    /// Must be called from the main thread; ASWebAuthenticationSession requires it.
    /// The method is `nonisolated` so callers on @MainActor can invoke it without
    /// a redundant hop, but it still awaits actor-isolated helpers for token work.
    func startOAuth(from context: ASWebAuthenticationPresentationContextProviding) async throws {
        guard let cid = clientId, !cid.isEmpty else {
            throw SonosCloudError.missingCredentials
        }

        let oauthPort: UInt16 = 8923
        let redirectURI = "http://localhost:\(oauthPort)/oauth/sonos"
        let state = UUID().uuidString
        let scope = "playback-control-all"

        var authComponents = URLComponents(string: "https://api.sonos.com/login/v3/oauth")!
        authComponents.queryItems = [
            URLQueryItem(name: "client_id", value: cid),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state),
        ]
        let authURL = authComponents.url!
        print("SonosCloudClient: OAuth URL → \(authURL.absoluteString)")

        // Start local HTTP server to bridge Sonos redirect → custom URL scheme.
        // Sonos redirects to http://localhost:8923/oauth/sonos?code=xxx
        // Our server responds with 302 → lutronhome://oauth/sonos?code=xxx
        // ASWebAuthenticationSession intercepts the custom scheme.
        let oauthListener = try startOAuthListener(port: oauthPort)
        defer { oauthListener.cancel() }

        // ASWebAuthenticationSession with custom scheme
        let callbackURL: URL = try await sonosWebAuthSession(authURL: authURL, context: context)

        // Extract authorization code
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw SonosCloudError.noAuthCode
        }

        // Exchange code for tokens
        try await exchangeCodeForTokens(code: code, redirectURI: redirectURI)

        // Fetch household ID
        try await fetchHouseholdId()
    }

    /// Starts a tiny HTTP server on the given port that receives the OAuth redirect
    /// and responds with a 302 to the app's custom URL scheme so ASWebAuthenticationSession
    /// can intercept it.
    private func startOAuthListener(port: UInt16) throws -> NWListener {
        let params = NWParameters.tcp
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)

        listener.newConnectionHandler = { connection in
            connection.start(queue: DispatchQueue(label: "sonos-oauth-conn"))
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                guard let data, let request = String(data: data, encoding: .utf8),
                      let firstLine = request.components(separatedBy: "\r\n").first,
                      let pathQuery = firstLine.split(separator: " ").dropFirst().first else {
                    connection.cancel()
                    return
                }

                // Forward the query string to the custom scheme
                let pathStr = String(pathQuery)
                let query = pathStr.contains("?") ? String(pathStr[pathStr.index(after: pathStr.firstIndex(of: "?")!)...]) : ""
                let redirectURL = "lutronhome://oauth/sonos?\(query)"

                let responseBody = "<html><body>Authorization complete. Returning to app…</body></html>"
                let response = "HTTP/1.1 302 Found\r\nLocation: \(redirectURL)\r\nContent-Length: \(responseBody.utf8.count)\r\nContent-Type: text/html\r\n\r\n\(responseBody)"

                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }

        listener.start(queue: DispatchQueue(label: "sonos-oauth-listener"))
        return listener
    }

    private func exchangeCodeForTokens(code: String, redirectURI: String) async throws {
        guard let clientId, let clientSecret else {
            throw SonosCloudError.missingCredentials
        }

        let url = URL(string: "https://api.sonos.com/login/v3/oauth/access")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        // Basic auth header
        let credentials = "\(clientId):\(clientSecret)"
        let base64Credentials = Data(credentials.utf8).base64EncodedString()
        request.setValue("Basic \(base64Credentials)", forHTTPHeaderField: "Authorization")

        // Form-urlencoded: percent-encode values (especially redirect_uri which contains ://)
        var bodyComponents = URLComponents()
        bodyComponents.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
        ]
        let body = bodyComponents.percentEncodedQuery ?? ""
        request.httpBody = Data(body.utf8)

        let (data, _) = try await URLSession.shared.data(for: request)

        struct TokenResponse: Decodable {
            let access_token: String
            let refresh_token: String
            let expires_in: Int
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        saveTokens(access: tokenResponse.access_token, refresh: tokenResponse.refresh_token,
                   expiresIn: tokenResponse.expires_in)
    }

    func refreshAccessToken() async throws {
        guard let refreshToken, let clientId, let clientSecret else {
            throw SonosCloudError.missingCredentials
        }

        let url = URL(string: "https://api.sonos.com/login/v3/oauth/access")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let credentials = "\(clientId):\(clientSecret)"
        let base64Credentials = Data(credentials.utf8).base64EncodedString()
        request.setValue("Basic \(base64Credentials)", forHTTPHeaderField: "Authorization")

        let body = "grant_type=refresh_token&refresh_token=\(refreshToken)"
        request.httpBody = Data(body.utf8)

        let (data, _) = try await URLSession.shared.data(for: request)

        struct TokenResponse: Decodable {
            let access_token: String
            let refresh_token: String
            let expires_in: Int
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        saveTokens(access: tokenResponse.access_token, refresh: tokenResponse.refresh_token,
                   expiresIn: tokenResponse.expires_in)
    }

    private func saveTokens(access: String, refresh: String, expiresIn: Int) {
        accessToken = access
        refreshToken = refresh
        tokenExpiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        KeychainHelper.save(access, for: Keys.accessToken)
        KeychainHelper.save(refresh, for: Keys.refreshToken)
        UserDefaults.standard.set(tokenExpiresAt!.timeIntervalSince1970, forKey: DefaultsKeys.tokenExpiresAt)
    }

    // MARK: - Ensure Valid Token

    private func ensureValidToken() async throws {
        guard accessToken != nil else { throw SonosCloudError.notLinked }
        if let expiresAt = tokenExpiresAt, Date() > expiresAt.addingTimeInterval(-300) {
            try await refreshAccessToken()
        }
    }

    private func authorizedRequest(url: URL) async throws -> URLRequest {
        try await ensureValidToken()
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken!)", forHTTPHeaderField: "Authorization")
        return request
    }

    // MARK: - Households

    private func fetchHouseholdId() async throws {
        let url = URL(string: "https://api.ws.sonos.com/control/api/v1/households")!
        let request = try await authorizedRequest(url: url)
        let (data, _) = try await URLSession.shared.data(for: request)

        struct HouseholdsResponse: Decodable {
            struct Household: Decodable { let id: String }
            let households: [Household]
        }

        let response = try JSONDecoder().decode(HouseholdsResponse.self, from: data)
        guard let household = response.households.first else {
            throw SonosCloudError.noHousehold
        }
        householdId = household.id
        UserDefaults.standard.set(household.id, forKey: DefaultsKeys.householdId)
    }

    // MARK: - Favorites

    func getFavorites() async throws -> [SonosFavorite] {
        guard let householdId else { throw SonosCloudError.noHousehold }
        let url = URL(string: "https://api.ws.sonos.com/control/api/v1/households/\(householdId)/favorites")!
        let request = try await authorizedRequest(url: url)
        let (data, _) = try await URLSession.shared.data(for: request)

        struct FavoritesResponse: Decodable {
            struct Item: Decodable {
                let id: String
                let name: String
                let imageUrl: String?
                let service: FavService?
            }
            struct FavService: Decodable {
                let name: String?
            }
            let items: [Item]?
        }

        let response = try JSONDecoder().decode(FavoritesResponse.self, from: data)
        return (response.items ?? []).map { item in
            SonosFavorite(
                id: item.id,
                name: item.name,
                imageURL: item.imageUrl.flatMap { URL(string: $0) },
                type: item.service?.name ?? "unknown"
            )
        }
    }

    // MARK: - Playlists

    func getPlaylists() async throws -> [SonosFavorite] {
        guard let householdId else { throw SonosCloudError.noHousehold }
        let url = URL(string: "https://api.ws.sonos.com/control/api/v1/households/\(householdId)/playlists")!
        let request = try await authorizedRequest(url: url)
        let (data, _) = try await URLSession.shared.data(for: request)

        struct PlaylistsResponse: Decodable {
            struct Playlist: Decodable {
                let id: String
                let name: String
            }
            let playlists: [Playlist]?
        }

        let response = try JSONDecoder().decode(PlaylistsResponse.self, from: data)
        return (response.playlists ?? []).map { pl in
            SonosFavorite(id: pl.id, name: pl.name, imageURL: nil, type: "playlist")
        }
    }

    // MARK: - Play Favorite/Playlist

    func playFavorite(groupId: String, favoriteId: String) async throws {
        let url = URL(string: "https://api.ws.sonos.com/control/api/v1/groups/\(groupId)/favorites")!
        var request = try await authorizedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["favoriteId": favoriteId, "playOnCompletion": true] as [String: Any]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
            throw SonosCloudError.apiError(httpResponse.statusCode)
        }
    }

    func playPlaylist(groupId: String, playlistId: String) async throws {
        let url = URL(string: "https://api.ws.sonos.com/control/api/v1/groups/\(groupId)/playlists")!
        var request = try await authorizedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["playlistId": playlistId, "playOnCompletion": true] as [String: Any]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
            throw SonosCloudError.apiError(httpResponse.statusCode)
        }
    }
}

// MARK: - OAuth Session Helper (MainActor)

@MainActor
private func sonosWebAuthSession(
    authURL: URL,
    context: ASWebAuthenticationPresentationContextProviding
) async throws -> URL {
    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
        let session = ASWebAuthenticationSession(
            url: authURL,
            callbackURLScheme: "lutronhome"
        ) { url, error in
            if let error {
                continuation.resume(throwing: error)
            } else if let url {
                continuation.resume(returning: url)
            } else {
                continuation.resume(throwing: SonosCloudError.oauthCancelled)
            }
        }
        session.presentationContextProvider = context
        session.prefersEphemeralWebBrowserSession = false
        session.start()
    }
}

// MARK: - Errors

enum SonosCloudError: Error, LocalizedError {
    case missingCredentials
    case oauthCancelled
    case noAuthCode
    case notLinked
    case noHousehold
    case apiError(Int)

    var errorDescription: String? {
        switch self {
        case .missingCredentials: return "Sonos client ID and secret are required"
        case .oauthCancelled: return "Sonos authorization was cancelled"
        case .noAuthCode: return "No authorization code received from Sonos"
        case .notLinked: return "Sonos cloud account not linked"
        case .noHousehold: return "No Sonos household found"
        case .apiError(let code): return "Sonos API error (HTTP \(code))"
        }
    }
}
