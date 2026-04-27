import Foundation
import Observation
import AuthenticationServices

@Observable
class SonosManager: @unchecked Sendable {
    // MARK: - Published State

    var players: [SonosPlayer] = []
    var favorites: [SonosFavorite] = []
    var localFavorites: [SonosFavorite] = []
    var playlists: [SonosFavorite] = []
    var isLoading = false
    var errorMessage: String?

    var isCloudLinked: Bool {
        _cloudLinked
    }
    var hasPlayers: Bool { !players.isEmpty }

    /// Group coordinators only (one pill per group, not per speaker)
    var coordinators: [SonosPlayer] {
        players.filter { $0.isCoordinator }
    }

    // MARK: - Private State

    private var _cloudLinked = false
    private let localClient = SonosLocalClient()
    private let cloudClient = SonosCloudClient()
    private var positionTimer: Timer?
    private var listenerPort: UInt16 = 0

    // Topology cache
    private var topologyCacheURL: URL? {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("sonos-topology.json")
    }

    // MARK: - Init

    init() {
        loadTopologyCache()
        Task { _cloudLinked = await cloudClient.isLinked }
    }

    // MARK: - Lifecycle

    func resume() {
        Task {
            // Start event listener
            do {
                listenerPort = try await localClient.startListener()
            } catch {
                print("SonosManager: failed to start event listener — \(error)")
            }

            // Set up event callbacks
            await setupEventCallbacks()

            // Discover speakers
            await discover()

            // Start position polling
            startPositionPolling()
        }
    }

    func suspendLocal() {
        positionTimer?.invalidate()
        positionTimer = nil
        Task {
            await localClient.stopListener()
        }
    }

    // MARK: - Discovery

    private func discover() async {
        let discovered = await localClient.discoverPlayers()
        guard !discovered.isEmpty else { return }

        // Fetch full state for each player
        var fullPlayers: [SonosPlayer] = []
        for var player in discovered {
            do {
                player.state = try await localClient.getTransportInfo(player: player)
                player.currentTrack = try await localClient.getPositionInfo(player: player)
                player.volume = try await localClient.getVolume(player: player)
                player.isMuted = try await localClient.getMute(player: player)
            } catch {
                print("SonosManager: failed to poll \(player.name) — \(error)")
            }
            fullPlayers.append(player)

            // Subscribe to events
            if listenerPort > 0 {
                await localClient.subscribeAll(player: player, callbackPort: listenerPort)
            }
        }

        // Parse zone group topology from any player to get group info
        if let firstPlayer = fullPlayers.first {
            do {
                let topoData = try await localClient.getZoneGroupState(player: firstPlayer)
                updateGroupTopology(data: topoData, players: &fullPlayers)
            } catch {
                print("SonosManager: failed to get topology — \(error)")
            }
        }

        await MainActor.run {
            self.players = fullPlayers
        }
        saveTopologyCache()

        // Start subscription renewal
        await localClient.startRenewalTimer()
    }

    private func updateGroupTopology(data: Data, players: inout [SonosPlayer]) {
        // Parse the ZoneGroupState XML to determine group membership
        guard let xmlStr = String(data: data, encoding: .utf8) else { return }
        let decoded = xmlStr
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")

        let groupPattern = "<ZoneGroup\\s+Coordinator=\"([^\"]+)\"[^>]*>(.*?)</ZoneGroup>"
        let memberPattern = "<ZoneGroupMember\\s+UUID=\"([^\"]+)\""

        guard let groupRegex = try? NSRegularExpression(pattern: groupPattern, options: .dotMatchesLineSeparators),
              let memberRegex = try? NSRegularExpression(pattern: memberPattern) else { return }

        let range = NSRange(decoded.startIndex..., in: decoded)
        let groupMatches = groupRegex.matches(in: decoded, range: range)

        for groupMatch in groupMatches {
            guard let coordRange = Range(groupMatch.range(at: 1), in: decoded),
                  let bodyRange = Range(groupMatch.range(at: 2), in: decoded) else { continue }

            let coordinatorUUID = String(decoded[coordRange])
            let groupBody = String(decoded[bodyRange])
            let bodyNSRange = NSRange(groupBody.startIndex..., in: groupBody)
            let memberMatches = memberRegex.matches(in: groupBody, range: bodyNSRange)

            var memberUUIDs: [String] = []
            for memberMatch in memberMatches {
                if let range = Range(memberMatch.range(at: 1), in: groupBody) {
                    memberUUIDs.append(String(groupBody[range]))
                }
            }

            let groupId = coordinatorUUID

            for i in players.indices {
                if memberUUIDs.contains(players[i].id) {
                    players[i].groupId = groupId
                    players[i].isCoordinator = (players[i].id == coordinatorUUID)
                    players[i].groupMembers = memberUUIDs.filter { $0 != players[i].id }
                }
            }
        }
    }

    // MARK: - Event Callbacks

    private func setupEventCallbacks() async {
        await localClient.setOnTransportEvent { [weak self] baseURL, state, track in
            Task { @MainActor in
                guard let self else { return }
                if let idx = self.players.firstIndex(where: { $0.baseURL == baseURL }) {
                    self.players[idx].state = state
                    if let track {
                        self.players[idx].currentTrack = track
                    }
                }
            }
        }

        await localClient.setOnVolumeEvent { [weak self] baseURL, volume, muted in
            Task { @MainActor in
                guard let self else { return }
                if let idx = self.players.firstIndex(where: { $0.baseURL == baseURL }) {
                    self.players[idx].volume = volume
                    self.players[idx].isMuted = muted
                }
            }
        }
    }

    // MARK: - Position Polling

    private func startPositionPolling() {
        positionTimer?.invalidate()
        positionTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { await self?.pollPositions() }
        }
    }

    private func pollPositions() async {
        for player in players where player.state == .playing && player.isCoordinator {
            do {
                if let track = try await localClient.getPositionInfo(player: player) {
                    await MainActor.run {
                        if let idx = self.players.firstIndex(where: { $0.id == player.id }) {
                            self.players[idx].currentTrack = track
                        }
                    }
                }
            } catch {
                // Ignore polling errors
            }
        }
    }

    // MARK: - Transport Controls

    func play(playerId: String) async throws {
        guard let player = coordinator(for: playerId) else { throw SonosError.noCoordinator }
        try await localClient.play(player: player)
        await MainActor.run {
            if let idx = players.firstIndex(where: { $0.id == player.id }) {
                players[idx].state = .playing
            }
        }
    }

    func pausePlayback(playerId: String) async throws {
        guard let player = coordinator(for: playerId) else { throw SonosError.noCoordinator }
        try await localClient.pause(player: player)
        await MainActor.run {
            if let idx = players.firstIndex(where: { $0.id == player.id }) {
                players[idx].state = .paused
            }
        }
    }

    func next(playerId: String) async throws {
        guard let player = coordinator(for: playerId) else { throw SonosError.noCoordinator }
        try await localClient.next(player: player)
    }

    func previous(playerId: String) async throws {
        guard let player = coordinator(for: playerId) else { throw SonosError.noCoordinator }
        try await localClient.previous(player: player)
    }

    func seek(playerId: String, position: TimeInterval) async throws {
        guard let player = coordinator(for: playerId) else { throw SonosError.noCoordinator }
        try await localClient.seek(player: player, position: position)
    }

    // MARK: - Volume Controls

    func setVolume(playerId: String, level: Int) async throws {
        guard let player = players.first(where: { $0.id == playerId }) else { return }
        try await localClient.setVolume(player: player, level: level)
        await MainActor.run {
            if let idx = players.firstIndex(where: { $0.id == playerId }) {
                players[idx].volume = level
            }
        }
    }

    func setMute(playerId: String, muted: Bool) async throws {
        guard let player = players.first(where: { $0.id == playerId }) else { return }
        try await localClient.setMute(player: player, muted: muted)
        await MainActor.run {
            if let idx = players.firstIndex(where: { $0.id == playerId }) {
                players[idx].isMuted = muted
            }
        }
    }

    // MARK: - Content Browsing

    func loadLocalFavorites() async throws {
        guard let player = players.first else { return }
        let items = try await localClient.browseFavorites(player: player)
        let favs: [SonosFavorite] = items.compactMap { item in
            guard !item.title.isEmpty else { return nil }
            let artURL: URL? = {
                if item.albumArtURI.isEmpty { return nil }
                if item.albumArtURI.hasPrefix("http") { return URL(string: item.albumArtURI) }
                return URL(string: "\(player.baseURL)\(item.albumArtURI)")
            }()
            return SonosFavorite(
                id: item.id, name: item.title, imageURL: artURL,
                type: item.isContainer ? "container" : "track",
                uri: item.uri.isEmpty ? nil : item.uri,
                metadata: item.metadata.isEmpty ? nil : item.metadata
            )
        }
        await MainActor.run { localFavorites = favs }
    }

    func playMedia(playerId: String, uri: String, metadata: String = "") async throws {
        guard let player = coordinator(for: playerId) else { throw SonosError.noCoordinator }
        try await localClient.setAVTransportURI(player: player, uri: uri, metadata: metadata)
        try await localClient.play(player: player)
        await MainActor.run {
            if let idx = players.firstIndex(where: { $0.id == player.id }) {
                players[idx].state = .playing
            }
        }
    }

    func playTVInput(playerId: String) async throws {
        guard let player = coordinator(for: playerId) else { throw SonosError.noCoordinator }
        // HDMI ARC input for Sonos soundbars (Beam, Arc, Playbar, Ray)
        try await localClient.setAVTransportURI(player: player, uri: "x-sonos-htacontrol:HTSATCh7")
        try await localClient.play(player: player)
        await MainActor.run {
            if let idx = players.firstIndex(where: { $0.id == player.id }) {
                players[idx].state = .playing
            }
        }
    }

    /// Speakers that have TV/HDMI input capability (soundbars)
    var tvCapableSpeakers: [SonosPlayer] {
        let soundbarModels = ["Beam", "Arc", "Playbar", "Playbase", "Ray", "S14", "S13", "S11", "S18"]
        return players.filter { p in
            soundbarModels.contains(where: { p.modelName.contains($0) || p.modelNumber.contains($0) })
        }
    }

    // MARK: - Queue

    func getQueue(playerId: String) async throws -> [SonosTrack] {
        guard let player = coordinator(for: playerId) else { throw SonosError.noCoordinator }
        return try await localClient.getQueue(player: player)
    }

    func removeFromQueue(playerId: String, index: Int) async throws {
        guard let player = coordinator(for: playerId) else { throw SonosError.noCoordinator }
        try await localClient.removeFromQueue(player: player, index: index)
    }

    func clearQueue(playerId: String) async throws {
        guard let player = coordinator(for: playerId) else { throw SonosError.noCoordinator }
        try await localClient.clearQueue(player: player)
    }

    // MARK: - Grouping

    func groupPlayers(coordinatorId: String, memberIds: [String]) async throws {
        guard let coordinator = players.first(where: { $0.id == coordinatorId }) else { return }
        for memberId in memberIds {
            guard let member = players.first(where: { $0.id == memberId }) else { continue }
            try await localClient.groupPlayer(member: member, withCoordinator: coordinator)
        }
        // Refresh topology
        try? await Task.sleep(for: .seconds(1))
        await discover()
    }

    func ungroupPlayer(playerId: String) async throws {
        guard let player = players.first(where: { $0.id == playerId }) else { return }
        try await localClient.ungroupPlayer(player: player)
        try? await Task.sleep(for: .seconds(1))
        await discover()
    }

    // MARK: - Cloud Features

    func setClientCredentials(clientId: String, clientSecret: String) {
        Task {
            await cloudClient.setClientCredentials(clientId: clientId, clientSecret: clientSecret)
        }
    }

    func startOAuth(from context: ASWebAuthenticationPresentationContextProviding) {
        Task { @MainActor in
            do {
                try await cloudClient.startOAuth(from: context)
                _cloudLinked = true
                try await loadFavorites()
                try await loadPlaylists()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func loadFavorites() async throws {
        let favs = try await cloudClient.getFavorites()
        await MainActor.run { favorites = favs }
    }

    func loadPlaylists() async throws {
        let pls = try await cloudClient.getPlaylists()
        await MainActor.run { playlists = pls }
    }

    func playFavorite(groupId: String, favoriteId: String) async throws {
        try await cloudClient.playFavorite(groupId: groupId, favoriteId: favoriteId)
    }

    func playPlaylist(groupId: String, playlistId: String) async throws {
        try await cloudClient.playPlaylist(groupId: groupId, playlistId: playlistId)
    }

    func unlinkCloud() {
        Task {
            await cloudClient.unlink()
            await MainActor.run {
                _cloudLinked = false
                favorites = []
                playlists = []
            }
        }
    }

    // MARK: - Helpers

    private func coordinator(for playerId: String) -> SonosPlayer? {
        guard let player = players.first(where: { $0.id == playerId }) else { return nil }
        if player.isCoordinator { return player }
        return players.first(where: { $0.id == player.groupId })
    }

    /// Find the player for a given room name (for RoomDetailView integration)
    func player(forRoom roomName: String) -> SonosPlayer? {
        players.first(where: { $0.name.lowercased() == roomName.lowercased() })
    }

    // MARK: - Topology Cache

    private func loadTopologyCache() {
        guard let url = topologyCacheURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(SonosTopologyCache.self, from: data) else {
            return
        }
        players = cache.players
    }

    private func saveTopologyCache() {
        guard let url = topologyCacheURL else { return }
        let cache = SonosTopologyCache(players: players, lastUpdated: Date())
        do {
            let data = try JSONEncoder().encode(cache)
            try data.write(to: url, options: .atomic)
        } catch {
            print("SonosManager: failed to write topology cache — \(error.localizedDescription)")
        }
    }
}

// MARK: - Actor callback setters (bridging actor isolation)

extension SonosLocalClient {
    func setOnTransportEvent(_ handler: @escaping (String, PlaybackState, SonosTrack?) -> Void) {
        onTransportEvent = handler
    }
    func setOnVolumeEvent(_ handler: @escaping (String, Int, Bool) -> Void) {
        onVolumeEvent = handler
    }
}
