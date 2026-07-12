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
    var groupPresets: [SonosGroupPreset] = []
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
        loadGroupPresets()
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
            await MainActor.run { startPositionPolling() }
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

        // Fetch full state for all players in parallel
        let client = localClient
        let port = listenerPort
        let fullPlayers: [SonosPlayer] = await withTaskGroup(of: SonosPlayer.self) { group in
            for player in discovered {
                group.addTask {
                    async let state = client.getTransportInfo(player: player)
                    async let track = client.getPositionInfo(player: player)
                    async let vol = client.getVolume(player: player)
                    async let mute = client.getMute(player: player)
                    var p = player
                    p.state = (try? await state) ?? .stopped
                    p.currentTrack = try? await track
                    p.volume = (try? await vol) ?? 0
                    p.isMuted = (try? await mute) ?? false
                    // Subscribe to events
                    if port > 0 {
                        await client.subscribeAll(player: p, callbackPort: port)
                    }
                    return p
                }
            }
            var results: [SonosPlayer] = []
            for await player in group { results.append(player) }
            return results
        }

        // Parse zone group topology from any player to get group info
        var enrichedPlayers = fullPlayers
        if let firstPlayer = enrichedPlayers.first {
            do {
                let topoData = try await localClient.getZoneGroupState(player: firstPlayer)
                updateGroupTopology(data: topoData, players: &enrichedPlayers)
            } catch {
                print("SonosManager: failed to get topology — \(error)")
            }
        }

        let finalPlayers = enrichedPlayers
        await MainActor.run {
            self.players = finalPlayers
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
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
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
                    // Fetch full track info (including album art) after transport change
                    let player = self.players[idx]
                    Task {
                        if let fullTrack = try? await self.localClient.getPositionInfo(player: player) {
                            await MainActor.run {
                                if let i = self.players.firstIndex(where: { $0.id == player.id }) {
                                    self.players[i].currentTrack = fullTrack
                                }
                            }
                        }
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

        await localClient.setOnTopologyChange { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                var updated = self.players
                self.updateGroupTopology(data: data, players: &updated)
                self.players = updated
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
        // Optimistic UI update — reflect state immediately, network call in background
        await MainActor.run {
            if let idx = players.firstIndex(where: { $0.id == player.id }) {
                players[idx].state = .playing
            }
        }
        try await localClient.play(player: player)
    }

    func pausePlayback(playerId: String) async throws {
        guard let player = coordinator(for: playerId) else { throw SonosError.noCoordinator }
        await MainActor.run {
            if let idx = players.firstIndex(where: { $0.id == player.id }) {
                players[idx].state = .paused
            }
        }
        try await localClient.pause(player: player)
    }

    func next(playerId: String) async throws {
        guard let player = coordinator(for: playerId) else { throw SonosError.noCoordinator }
        // Optimistic: clear current track so UI shows loading state
        await MainActor.run {
            if let idx = players.firstIndex(where: { $0.id == player.id }) {
                players[idx].currentTrack = nil
            }
        }
        try await localClient.next(player: player)
    }

    func previous(playerId: String) async throws {
        guard let player = coordinator(for: playerId) else { throw SonosError.noCoordinator }
        await MainActor.run {
            if let idx = players.firstIndex(where: { $0.id == player.id }) {
                players[idx].currentTrack = nil
            }
        }
        try await localClient.previous(player: player)
    }

    func seek(playerId: String, position: TimeInterval) async throws {
        guard let player = coordinator(for: playerId) else { throw SonosError.noCoordinator }
        // Optimistic: update position immediately
        await MainActor.run {
            if let idx = players.firstIndex(where: { $0.id == player.id }) {
                players[idx].currentTrack?.position = position
            }
        }
        try await localClient.seek(player: player, position: position)
    }

    // MARK: - Volume Controls

    func setVolume(playerId: String, level: Int) async throws {
        guard let player = players.first(where: { $0.id == playerId }) else { return }
        // Optimistic UI update
        await MainActor.run {
            if let idx = players.firstIndex(where: { $0.id == playerId }) {
                players[idx].volume = level
            }
        }
        try await localClient.setVolume(player: player, level: level)
    }

    func setMute(playerId: String, muted: Bool) async throws {
        guard let player = players.first(where: { $0.id == playerId }) else { return }
        await MainActor.run {
            if let idx = players.firstIndex(where: { $0.id == playerId }) {
                players[idx].isMuted = muted
            }
        }
        try await localClient.setMute(player: player, muted: muted)
    }

    // MARK: - Content Browsing

    /// Spotify service descriptor extracted from Sonos favorites metadata (e.g. "SA_RINCON3079_X_#Svc3079-517804c8-Token")
    var spotifyServiceDesc: String?
    /// Spotify serial number from Sonos system (the `sn=` parameter)
    var spotifySN: Int = 3

    func loadLocalFavorites() async throws {
        guard let player = players.first else { return }
        let (items, rawData) = try await localClient.browseFavoritesWithRaw(player: player)
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

        // Extract Spotify service descriptor from any Spotify favorite
        extractSpotifyDescriptor(from: rawData)
    }

    private func extractSpotifyDescriptor(from data: Data) {
        guard let xml = String(data: data, encoding: .utf8) else { return }
        let decoded = xml
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")

        // Find a Spotify favorite by looking for sid=12 in the URI
        if let snMatch = try? NSRegularExpression(pattern: "sid=12[^>]*sn=(\\d+)")
            .firstMatch(in: decoded, range: NSRange(decoded.startIndex..., in: decoded)),
           let snRange = Range(snMatch.range(at: 1), in: decoded) {
            spotifySN = Int(decoded[snRange]) ?? 3
        }

        // Extract the SA_RINCON descriptor from metadata
        if let descMatch = try? NSRegularExpression(pattern: "(SA_RINCON\\d+_X_#Svc\\d+-[^<]+)")
            .firstMatch(in: decoded, range: NSRange(decoded.startIndex..., in: decoded)),
           let descRange = Range(descMatch.range(at: 1), in: decoded) {
            // Only grab it if it's near a Spotify reference
            let desc = String(decoded[descRange])
            // Check it's not the Sonos Radio one (77575)
            if !desc.contains("77575") {
                spotifyServiceDesc = desc
            }
        }

        // More targeted: find desc near spotify URIs
        if spotifyServiceDesc == nil {
            let pattern = "spotify.*?<desc[^>]*>(SA_RINCON\\d+_X_#Svc[^<]+)</desc>"
            if let match = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators)
                .firstMatch(in: decoded, range: NSRange(decoded.startIndex..., in: decoded)),
               let range = Range(match.range(at: 1), in: decoded) {
                spotifyServiceDesc = String(decoded[range])
            }
        }
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

    /// Groups members under coordinator, plays content, then refreshes topology.
    func groupAndPlay(coordinatorId: String, memberIds: [String], play: (String) async throws -> Void) async throws {
        guard let coordinator = players.first(where: { $0.id == coordinatorId }) else {
            print("SonosManager: groupAndPlay — coordinator \(coordinatorId) not found")
            return
        }

        // First, ungroup any members that are coordinators of their own groups
        // (they need to leave their current group before joining the new one)
        for memberId in memberIds {
            guard let member = players.first(where: { $0.id == memberId }) else {
                print("SonosManager: groupAndPlay — member \(memberId) not found, skipping")
                continue
            }
            if member.isCoordinator && member.groupId != coordinator.id {
                print("SonosManager: ungrouping coordinator \(member.name) before re-grouping")
                try? await localClient.ungroupPlayer(player: member)
            }
        }

        // Brief pause after ungrouping
        if memberIds.contains(where: { id in
            players.first(where: { $0.id == id })?.isCoordinator == true
        }) {
            try? await Task.sleep(for: .milliseconds(300))
        }

        // Now group all members under the target coordinator
        for memberId in memberIds {
            guard let member = players.first(where: { $0.id == memberId }) else { continue }
            do {
                print("SonosManager: grouping \(member.name) under \(coordinator.name)")
                try await localClient.groupPlayer(member: member, withCoordinator: coordinator)
            } catch {
                print("SonosManager: failed to group \(member.name) — \(error)")
            }
        }

        // Brief pause for Sonos to process group changes
        try? await Task.sleep(for: .milliseconds(500))
        // Play on the coordinator
        try await play(coordinatorId)
        // Refresh topology in background
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            await self?.discover()
        }
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

    // MARK: - Group Display

    /// Combined display name for a group, e.g. "Family Room + Kitchen"
    func groupDisplayName(for coordinator: SonosPlayer) -> String {
        let memberNames = players
            .filter { $0.groupId == coordinator.id && $0.id != coordinator.id }
            .map(\.name)
        let allNames = [coordinator.name] + memberNames
        return allNames.joined(separator: " + ")
    }

    /// All players in a coordinator's group (including the coordinator)
    func groupMembers(for coordinator: SonosPlayer) -> [SonosPlayer] {
        let members = players.filter { $0.groupId == coordinator.id && $0.id != coordinator.id }
        return [coordinator] + members
    }

    // MARK: - Group Presets

    private static let presetsKey = "sonos-group-presets"

    func loadGroupPresets() {
        guard let data = UserDefaults.standard.data(forKey: Self.presetsKey),
              let presets = try? JSONDecoder().decode([SonosGroupPreset].self, from: data) else { return }
        groupPresets = presets
    }

    private func saveGroupPresets() {
        if let data = try? JSONEncoder().encode(groupPresets) {
            UserDefaults.standard.set(data, forKey: Self.presetsKey)
        }
    }

    func addGroupPreset(name: String, playerIds: [String]) {
        let preset = SonosGroupPreset(id: UUID().uuidString, name: name, playerIds: playerIds)
        groupPresets.append(preset)
        saveGroupPresets()
    }

    func deleteGroupPreset(id: String) {
        groupPresets.removeAll { $0.id == id }
        saveGroupPresets()
    }

    /// Resolve a preset's player IDs to names for display, filtering to currently-known players.
    func presetDisplayNames(for preset: SonosGroupPreset) -> [String] {
        preset.playerIds.compactMap { pid in
            players.first(where: { $0.id == pid })?.name
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
    func setOnTopologyChange(_ handler: @escaping (Data) -> Void) {
        onTopologyChange = handler
    }
}
