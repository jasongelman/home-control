import Foundation
import Observation
import AuthenticationServices
import CryptoKit

// MARK: - Spotify Search Result Models

struct SpotifySearchResults: Codable {
    var tracks: SpotifyPagingObject<SpotifyTrackItem>?
    var albums: SpotifyPagingObject<SpotifyAlbumItem>?
    var playlists: SpotifyPagingObject<SpotifyPlaylistItem>?
}

struct SpotifyPagingObject<T: Codable>: Codable {
    let items: [T]
    let total: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        total = try container.decode(Int.self, forKey: .total)
        // Spotify can return null entries in items arrays (e.g. deleted playlists)
        let rawItems = try container.decode([T?].self, forKey: .items)
        items = rawItems.compactMap { $0 }
    }

    private enum CodingKeys: String, CodingKey {
        case items, total
    }
}

struct SpotifyTrackItem: Codable, Identifiable {
    let id: String
    let name: String
    let uri: String
    let duration_ms: Int
    let artists: [SpotifyArtistRef]
    let album: SpotifyAlbumRef
}

struct SpotifyAlbumItem: Codable, Identifiable {
    let id: String
    let name: String
    let uri: String
    let artists: [SpotifyArtistRef]
    let images: [SpotifyImage]
    let total_tracks: Int?
}

struct SpotifyPlaylistItem: Codable, Identifiable {
    let id: String
    let name: String
    let uri: String
    let images: [SpotifyImage]?
    let owner: SpotifyOwner?
    let tracks: SpotifyPlaylistTrackRef?
}

struct SpotifyArtistRef: Codable {
    let name: String
}

struct SpotifyAlbumRef: Codable {
    let name: String
    let images: [SpotifyImage]
}

struct SpotifyImage: Codable {
    let url: String
    let height: Int?
    let width: Int?
}

struct SpotifyOwner: Codable {
    let display_name: String?
}

struct SpotifyPlaylistTrackRef: Codable {
    let total: Int?
}

// MARK: - SpotifyManager

@Observable
class SpotifyManager: @unchecked Sendable {

    // MARK: - State

    var isLinked: Bool { accessToken != nil }
    var searchResults = SpotifySearchResults()
    var isSearching = false
    var errorMessage: String?
    var userPlaylists: [SpotifyPlaylistItem] = []

    private static let playlistsCacheKey = "spotify_playlists_cache"

    init() {
        // Load cached playlists
        if let data = UserDefaults.standard.data(forKey: Self.playlistsCacheKey),
           let cached = try? JSONDecoder().decode([SpotifyPlaylistItem].self, from: data) {
            userPlaylists = cached
        }
    }

    // MARK: - Private

    private var clientId: String {
        get { UserDefaults.standard.string(forKey: "spotify_client_id") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "spotify_client_id") }
    }
    private var accessToken: String? {
        get { KeychainHelper.loadString(for: "spotify_access_token") }
        set {
            if let v = newValue { KeychainHelper.save(v, for: "spotify_access_token") }
            else { KeychainHelper.delete(for: "spotify_access_token") }
        }
    }
    private var refreshToken: String? {
        get { KeychainHelper.loadString(for: "spotify_refresh_token") }
        set {
            if let v = newValue { KeychainHelper.save(v, for: "spotify_refresh_token") }
            else { KeychainHelper.delete(for: "spotify_refresh_token") }
        }
    }
    private var tokenExpiry: Date {
        get { Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: "spotify_token_expiry")) }
        set { UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: "spotify_token_expiry") }
    }

    private let redirectURI = "lutronhome://oauth/spotify"
    private let tokenURL = "https://accounts.spotify.com/api/token"
    private let authorizeURL = "https://accounts.spotify.com/authorize"
    private let apiBase = "https://api.spotify.com/v1"

    // MARK: - OAuth PKCE

    func setClientId(_ id: String) {
        clientId = id
    }

    func startOAuth(from context: ASWebAuthenticationPresentationContextProviding) async throws {
        let cid = clientId
        guard !cid.isEmpty else {
            throw SpotifyError.missingClientId
        }

        // Generate PKCE challenge
        let verifier = generateCodeVerifier()
        let challenge = generateCodeChallenge(from: verifier)

        var components = URLComponents(string: authorizeURL)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: cid),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: "user-read-private user-read-recently-played user-top-read user-library-read playlist-read-private playlist-read-collaborative"),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "show_dialog", value: "true"),
        ]

        guard let authURL = components.url else { throw SpotifyError.badURL }

        let callbackURL = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            nonisolated(unsafe) let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: "lutronhome") { url, error in
                if let error { cont.resume(throwing: error); return }
                guard let url else { cont.resume(throwing: SpotifyError.noCallback); return }
                cont.resume(returning: url)
            }
            session.presentationContextProvider = context
            session.prefersEphemeralWebBrowserSession = false
            DispatchQueue.main.async { session.start() }
        }

        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else {
            throw SpotifyError.noAuthCode
        }

        try await exchangeCodeForTokens(code: code, verifier: verifier)
    }

    private func exchangeCodeForTokens(code: String, verifier: String) async throws {
        var request = URLRequest(url: URL(string: tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientId,
            "code_verifier": verifier,
        ].map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        try parseTokenResponse(data)
    }

    private func refreshAccessToken() async throws {
        guard let rt = refreshToken else { throw SpotifyError.noRefreshToken }

        var request = URLRequest(url: URL(string: tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "grant_type": "refresh_token",
            "refresh_token": rt,
            "client_id": clientId,
        ].map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        try parseTokenResponse(data)
    }

    private func parseTokenResponse(_ data: Data) throws {
        struct TokenResponse: Codable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Int
        }
        let resp = try JSONDecoder().decode(TokenResponse.self, from: data)
        accessToken = resp.access_token
        if let rt = resp.refresh_token { refreshToken = rt }
        tokenExpiry = Date().addingTimeInterval(TimeInterval(resp.expires_in - 60))
    }

    func unlink() {
        accessToken = nil
        refreshToken = nil
        searchResults = SpotifySearchResults()
    }

    // MARK: - Search

    func search(query: String) async throws {
        guard !query.isEmpty else {
            await MainActor.run { searchResults = SpotifySearchResults() }
            return
        }

        await MainActor.run { isSearching = true }
        defer { Task { @MainActor in isSearching = false } }

        let token = try await validToken()
        var components = URLComponents(string: "\(apiBase)/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "type", value: "track,album,playlist"),
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "market", value: "US"),
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SpotifyError.searchFailed
        }
        if http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? ""
            print("Spotify search failed (\(http.statusCode)): \(body)")
            if http.statusCode == 401 {
                // Token expired, clear and retry once
                accessToken = nil
                let newToken = try await validToken()
                var retryReq = request
                retryReq.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
                let (retryData, retryResp) = try await URLSession.shared.data(for: retryReq)
                guard let retryHttp = retryResp as? HTTPURLResponse, retryHttp.statusCode == 200 else {
                    throw SpotifyError.searchFailed
                }
                let results = try JSONDecoder().decode(SpotifySearchResults.self, from: retryData)
                await MainActor.run { searchResults = results }
                return
            }
            throw SpotifyError.searchFailed
        }

        let results = try JSONDecoder().decode(SpotifySearchResults.self, from: data)
        await MainActor.run { searchResults = results }
    }

    // MARK: - Recently Played & Top Tracks

    var recentTracks: [SpotifyTrackItem] = []

    func loadRecentlyPlayed() async throws {
        let token = try await validToken()
        var request = URLRequest(url: URL(string: "\(apiBase)/me/player/recently-played?limit=20")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            print("Spotify recently-played failed: \(String(data: data, encoding: .utf8) ?? "")")
            return
        }

        struct RecentlyPlayedResponse: Codable {
            struct PlayHistoryItem: Codable {
                let track: SpotifyTrackItem
            }
            let items: [PlayHistoryItem]
        }

        let resp = try JSONDecoder().decode(RecentlyPlayedResponse.self, from: data)
        // Deduplicate by track ID, keep first occurrence (most recent)
        var seen = Set<String>()
        let unique = resp.items.compactMap { item -> SpotifyTrackItem? in
            guard !seen.contains(item.track.id) else { return nil }
            seen.insert(item.track.id)
            return item.track
        }
        await MainActor.run { recentTracks = unique }
    }

    func loadUserPlaylists() async throws {
        let token = try await validToken()
        var request = URLRequest(url: URL(string: "\(apiBase)/me/playlists?limit=50")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            print("Spotify playlists failed: \(String(data: data, encoding: .utf8) ?? "")")
            return
        }

        do {
            let paging = try JSONDecoder().decode(SpotifyPagingObject<SpotifyPlaylistItem>.self, from: data)
            await MainActor.run { userPlaylists = paging.items }
            // Cache to disk
            if let cacheData = try? JSONEncoder().encode(paging.items) {
                UserDefaults.standard.set(cacheData, forKey: Self.playlistsCacheKey)
            }
        } catch {
            print("Spotify playlists decode error: \(error)")
            throw error
        }
    }

    // MARK: - Token Management

    private func validToken() async throws -> String {
        if let token = accessToken, tokenExpiry > Date() {
            return token
        }
        try await refreshAccessToken()
        guard let token = accessToken else { throw SpotifyError.noAccessToken }
        return token
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
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Sonos Playback Helpers

extension SpotifyManager {

    /// Build a Sonos-compatible URI from a Spotify URI.
    /// Requires the Spotify account descriptor from the Sonos system (extracted from favorites metadata).
    static func sonosURI(spotifyURI: String, sid: Int = 12, sn: Int = 3) -> String {
        let encoded = spotifyURI
            .replacingOccurrences(of: ":", with: "%3A")

        let type = spotifyURI.split(separator: ":").dropFirst().first ?? ""
        switch type {
        case "track":
            return "x-sonos-spotify:\(encoded)?sid=\(sid)&flags=8224&sn=\(sn)"
        case "playlist", "album", "artist":
            let prefix: String
            switch type {
            case "playlist": prefix = "1006206c"
            case "album": prefix = "0004206c"
            case "artist": prefix = "000c206c"
            default: prefix = "1006206c"
            }
            return "x-rincon-cpcontainer:\(prefix)\(encoded)?sid=\(sid)&flags=8300&sn=\(sn)"
        default:
            return "x-sonos-spotify:\(encoded)?sid=\(sid)&flags=8224&sn=\(sn)"
        }
    }

    /// Build DIDL-Lite metadata for a Spotify item on Sonos.
    static func sonosMetadata(spotifyURI: String, title: String, serviceDesc: String) -> String {
        let encoded = spotifyURI.replacingOccurrences(of: ":", with: "%3A")
        let type = spotifyURI.split(separator: ":").dropFirst().first ?? ""

        let prefix: String
        let upnpClass: String
        switch type {
        case "track":
            prefix = "00032020"
            upnpClass = "object.item.audioItem.musicTrack"
        case "playlist":
            prefix = "1006206c"
            upnpClass = "object.container.playlistContainer"
        case "album":
            prefix = "0004206c"
            upnpClass = "object.container.album.musicAlbum"
        case "artist":
            prefix = "000c206c"
            upnpClass = "object.container.person.musicArtist"
        default:
            prefix = "00032020"
            upnpClass = "object.item.audioItem.musicTrack"
        }

        let escapedTitle = title
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")

        return """
            <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" \
            xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" \
            xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" \
            xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">\
            <item id="\(prefix)\(encoded)" parentID="\(prefix)\(encoded)" restricted="true">\
            <dc:title>\(escapedTitle)</dc:title>\
            <upnp:class>\(upnpClass)</upnp:class>\
            <desc id="cdudn" nameSpace="urn:schemas-rinconnetworks-com:metadata-1-0/">\(serviceDesc)</desc>\
            </item></DIDL-Lite>
            """
    }
}

// MARK: - Errors

enum SpotifyError: LocalizedError {
    case missingClientId
    case badURL
    case noCallback
    case noAuthCode
    case noRefreshToken
    case noAccessToken
    case searchFailed

    var errorDescription: String? {
        switch self {
        case .missingClientId: "Set Spotify Client ID in Settings first"
        case .badURL: "Invalid authorization URL"
        case .noCallback: "No callback received"
        case .noAuthCode: "No authorization code in callback"
        case .noRefreshToken: "No refresh token — re-link Spotify"
        case .noAccessToken: "Not authenticated with Spotify"
        case .searchFailed: "Search request failed"
        }
    }
}
