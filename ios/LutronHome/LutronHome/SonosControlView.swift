import SwiftUI

/// Describes a pending playback action waiting for speaker selection.
struct PendingPlayback: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String?
    let imageURL: URL?
    /// The action to execute when the user confirms. Receives the target coordinator ID
    /// (after grouping has been handled by PlayToSheet).
    let play: (String) async throws -> Void
}

/// Full-screen Sonos control hub — speakers, groups, volume, now-playing, favorites.
struct SonosControlView: View {
    @Environment(SonosManager.self) var sonos
    @Environment(SpotifyManager.self) var spotify
    @Environment(\.dismiss) private var dismiss
    @State private var favoriteFilter = ""
    @State private var spotifyQuery = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var localVolumes: [String: Double] = [:]
    @State private var volumeDebounce: [String: Task<Void, Never>] = [:]
    @State private var detailPlayer: SonosPlayer?
    @State private var pendingPlayback: PendingPlayback?

    private let gridColumns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                nowPlayingSection
                sourcesSection
                if spotify.isLinked {
                    spotifySearchSection
                    if !spotify.recentTracks.isEmpty && spotifyQuery.isEmpty {
                        recentlyPlayedSection
                    }
                    if !spotify.userPlaylists.isEmpty && spotifyQuery.isEmpty {
                        spotifyPlaylistsSection
                    }
                }
                favoritesSection
                if sonos.isCloudLinked {
                    playlistsSection
                }
            }
            .padding()
        }
        .scrollDismissesKeyboard(.immediately)
        .onTapGesture { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
        .navigationTitle("Sonos")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
                    .foregroundStyle(EditorialTheme.accent)
            }
        }
        .sheet(item: $detailPlayer) { player in
            SonosDetailView(player: player)
        }
        .sheet(item: $pendingPlayback) { pending in
            PlayToSheet(pending: pending)
        }
        .onAppear {
            let sonos = sonos
            let spotify = spotify
            Task {
                async let cloud: Void = {
                    if sonos.isCloudLinked {
                        try? await sonos.loadFavorites()
                        try? await sonos.loadPlaylists()
                    }
                }()
                async let local: Void = {
                    if sonos.favorites.isEmpty {
                        try? await sonos.loadLocalFavorites()
                    }
                }()
                async let spot: Void = {
                    if spotify.isLinked {
                        try? await spotify.loadRecentlyPlayed()
                        do {
                            try await spotify.loadUserPlaylists()
                            print("Spotify: loaded \(spotify.userPlaylists.count) playlists")
                        } catch {
                            print("Spotify: loadUserPlaylists error — \(error)")
                        }
                    }
                }()
                _ = await (cloud, local, spot)
            }
        }
    }

    // MARK: - Now Playing (Single-Column Group Rows)

    private var nowPlayingSection: some View {
        VStack(spacing: 6) {
            ForEach(sonos.coordinators) { coordinator in
                let p = sonos.players.first(where: { $0.id == coordinator.id }) ?? coordinator
                let members = sonos.groupMembers(for: p)
                let isPlaying = p.state == .playing || p.currentTrack != nil

                VStack(spacing: 0) {
                    // Main row — tap to open detail
                    Button { detailPlayer = p } label: {
                        HStack(spacing: 10) {
                            // Album art
                            if let track = p.currentTrack, let artURL = track.albumArtURL {
                                AsyncImage(url: artURL) { phase in
                                    switch phase {
                                    case .success(let image):
                                        image.resizable().scaledToFill()
                                    default:
                                        Rectangle().fill(EditorialTheme.cardBackground)
                                    }
                                }
                                .frame(width: 48, height: 48)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            } else {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(EditorialTheme.cardBackground)
                                    .frame(width: 48, height: 48)
                                    .overlay(
                                        Image(systemName: "speaker.fill")
                                            .font(.system(size: 16))
                                            .foregroundStyle(EditorialTheme.tertiaryText)
                                    )
                            }

                            VStack(alignment: .leading, spacing: 3) {
                                Text(sonos.groupDisplayName(for: p).uppercased())
                                    .font(.system(size: 9, weight: .medium))
                                    .tracking(0.8)
                                    .foregroundStyle(EditorialTheme.secondaryText)

                                if let track = p.currentTrack {
                                    Text(track.title)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(EditorialTheme.primaryText)
                                        .lineLimit(1)
                                    if !track.artist.isEmpty {
                                        Text(track.artist)
                                            .font(.system(size: 11))
                                            .foregroundStyle(EditorialTheme.secondaryText)
                                            .lineLimit(1)
                                    }
                                } else {
                                    Text("Not playing")
                                        .font(.system(size: 13))
                                        .foregroundStyle(EditorialTheme.tertiaryText)
                                }
                            }

                            Spacer(minLength: 4)

                            // Transport controls
                            if p.currentTrack != nil {
                                HStack(spacing: 14) {
                                    transportButton("backward.fill", size: 11) {
                                        try? await sonos.previous(playerId: p.id)
                                    }
                                    transportButton(p.state == .playing ? "pause.fill" : "play.fill", size: 14) {
                                        if p.state == .playing {
                                            try? await sonos.pausePlayback(playerId: p.id)
                                        } else {
                                            try? await sonos.play(playerId: p.id)
                                        }
                                    }
                                    transportButton("forward.fill", size: 11) {
                                        try? await sonos.next(playerId: p.id)
                                    }
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)

                    // Inline volume sliders for each speaker in the group
                    if isPlaying {
                        VStack(spacing: 6) {
                            ForEach(members, id: \.id) { speaker in
                                HStack(spacing: 4) {
                                    Button {
                                        Task { try? await sonos.setMute(playerId: speaker.id, muted: !speaker.isMuted) }
                                    } label: {
                                        Image(systemName: speaker.isMuted ? "speaker.slash.fill" : "speaker.wave.1.fill")
                                            .font(.system(size: 9))
                                            .foregroundStyle(speaker.isMuted ? EditorialTheme.secondaryText : EditorialTheme.accent)
                                            .frame(width: 14)
                                    }
                                    .buttonStyle(.plain)

                                    if members.count > 1 {
                                        Text(speaker.name)
                                            .font(.system(size: 8, weight: .medium))
                                            .foregroundStyle(EditorialTheme.tertiaryText)
                                            .lineLimit(1)
                                            .frame(width: 50, alignment: .leading)
                                    }

                                    Slider(
                                        value: Binding(
                                            get: { localVolumes[speaker.id] ?? Double(speaker.volume) },
                                            set: { newVal in
                                                localVolumes[speaker.id] = newVal
                                                volumeDebounce[speaker.id]?.cancel()
                                                volumeDebounce[speaker.id] = Task {
                                                    try? await Task.sleep(for: .milliseconds(150))
                                                    guard !Task.isCancelled else { return }
                                                    try? await sonos.setVolume(playerId: speaker.id, level: Int(newVal))
                                                }
                                            }
                                        ),
                                        in: 0...100
                                    )
                                    .tint(EditorialTheme.accent)
                                    .controlSize(.mini)

                                    Text("\(Int(localVolumes[speaker.id] ?? Double(speaker.volume)))")
                                        .font(.system(size: 8, weight: .medium).monospacedDigit())
                                        .foregroundStyle(EditorialTheme.secondaryText)
                                        .frame(width: 18, alignment: .trailing)
                                }
                            }
                        }
                        .padding(.top, 10)
                    }
                }
                .padding(10)
                .background(EditorialTheme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: EditorialTheme.cardRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: EditorialTheme.cardRadius)
                        .stroke(EditorialTheme.cardBorder, lineWidth: 0.5)
                )
                .opacity(isPlaying ? 1 : 0.5)
            }
        }
    }

    private func transportButton(_ icon: String, size: CGFloat = 14, action: @escaping () async throws -> Void) -> some View {
        Button {
            Task { try? await action() }
        } label: {
            Image(systemName: icon)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(EditorialTheme.primaryText)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sources (TV Audio)

    @ViewBuilder
    private var sourcesSection: some View {
        if !sonos.tvCapableSpeakers.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("SOURCES")
                LazyVGrid(columns: gridColumns, spacing: 10) {
                    Button {
                        if let tvSpeaker = sonos.tvCapableSpeakers.first {
                            pendingPlayback = PendingPlayback(title: "TV Audio", subtitle: tvSpeaker.name, imageURL: nil) { coordId in
                                try await sonos.playTVInput(playerId: coordId)
                            }
                        }
                    } label: {
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(EditorialTheme.secondaryText.opacity(0.5), lineWidth: 1)
                                .aspectRatio(1, contentMode: .fit)
                                .overlay(
                                    VStack(spacing: 6) {
                                        Image(systemName: "tv")
                                            .font(.system(size: 22))
                                            .foregroundStyle(EditorialTheme.accent)
                                        Text("TV Audio")
                                            .font(.system(size: 9, weight: .medium))
                                            .foregroundStyle(EditorialTheme.primaryText)
                                    }
                                )
                            Text(" ")
                                .font(.system(size: 9))
                            Text(" ")
                                .font(.system(size: 8))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Spotify Search

    private var spotifySearchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("SPOTIFY")

            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(EditorialTheme.secondaryText)
                TextField("Search tracks, albums, playlists…", text: $spotifyQuery)
                    .font(.system(size: 13))
                    .foregroundStyle(EditorialTheme.primaryText)
                    .onSubmit { performSpotifySearch() }
                    .onChange(of: spotifyQuery) {
                        searchTask?.cancel()
                        searchTask = Task {
                            try? await Task.sleep(for: .milliseconds(300))
                            guard !Task.isCancelled else { return }
                            performSpotifySearch()
                        }
                    }
                if !spotifyQuery.isEmpty {
                    Button {
                        spotifyQuery = ""
                        Task { @MainActor in spotify.searchResults = SpotifySearchResults() }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(EditorialTheme.secondaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(EditorialTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if spotify.isSearching {
                HStack { Spacer(); ProgressView().scaleEffect(0.7); Spacer() }
                    .padding(.vertical, 8)
            } else if spotifyQuery.isEmpty {
                // Empty state — nothing to show
            } else {
                // Merge all results into a single 3-column grid
                let allItems = spotifyResultItems()
                if !allItems.isEmpty {
                    LazyVGrid(columns: gridColumns, spacing: 10) {
                        ForEach(allItems, id: \.uri) { item in
                            Button { stageSpotifyItem(uri: item.uri, title: item.title, subtitle: item.subtitle, imageURL: item.imageURL) } label: {
                                artCard(imageURL: item.imageURL, title: item.title, subtitle: item.subtitle)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .editorialCard(padding: 10)
    }

    private func performSpotifySearch() {
        let query = spotifyQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        Task {
            do {
                try await spotify.search(query: query)
                let items = spotifyResultItems()
                print("Spotify search '\(query)': \(items.count) results")
            } catch {
                print("Spotify search error: \(error)")
            }
        }
    }

    private func stageSpotifyItem(uri: String, title: String, subtitle: String? = nil, imageURL: URL? = nil) {
        let desc = sonos.spotifyServiceDesc ?? "SA_RINCON3079_X_#Svc3079-0-Token"
        let sonosURI = SpotifyManager.sonosURI(spotifyURI: uri, sn: sonos.spotifySN)
        let metadata = SpotifyManager.sonosMetadata(spotifyURI: uri, title: title, serviceDesc: desc)
        pendingPlayback = PendingPlayback(title: title, subtitle: subtitle, imageURL: imageURL) { coordId in
            try await sonos.playMedia(playerId: coordId, uri: sonosURI, metadata: metadata)
        }
    }

    // MARK: - Recently Played (3-Column Grid)

    private var recentlyPlayedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("RECENTLY PLAYED")
            LazyVGrid(columns: gridColumns, spacing: 10) {
                ForEach(spotify.recentTracks.prefix(9)) { track in
                    Button {
                        stageSpotifyItem(
                            uri: track.uri, title: track.name,
                            subtitle: track.artists.map(\.name).joined(separator: ", "),
                            imageURL: track.album.images.first.flatMap { URL(string: $0.url) }
                        )
                    } label: {
                        artCard(
                            imageURL: track.album.images.first.flatMap { URL(string: $0.url) },
                            title: track.name,
                            subtitle: track.artists.map(\.name).joined(separator: ", ")
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .editorialCard(padding: 10)
    }

    // MARK: - Spotify Playlists (3-Column Grid)

    private var spotifyPlaylistsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("MY PLAYLISTS")
            LazyVGrid(columns: gridColumns, spacing: 10) {
                ForEach(spotify.userPlaylists) { playlist in
                    Button {
                        stageSpotifyItem(
                            uri: playlist.uri, title: playlist.name,
                            subtitle: playlist.owner?.display_name,
                            imageURL: playlist.images?.first.flatMap { URL(string: $0.url) }
                        )
                    } label: {
                        artCard(
                            imageURL: playlist.images?.first.flatMap { URL(string: $0.url) },
                            title: playlist.name,
                            subtitle: playlist.owner?.display_name
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .editorialCard(padding: 10)
    }

    // MARK: - Favorites (3-Column Grid)

    private var filteredFavorites: [SonosFavorite] {
        let all = sonos.favorites.isEmpty ? sonos.localFavorites : sonos.favorites
        guard !favoriteFilter.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(favoriteFilter) }
    }

    @ViewBuilder
    private var favoritesSection: some View {
        let favs = filteredFavorites
        if !favs.isEmpty || !favoriteFilter.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("FAVORITES")

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(EditorialTheme.secondaryText)
                    TextField("Filter favorites…", text: $favoriteFilter)
                        .font(.system(size: 11))
                        .foregroundStyle(EditorialTheme.primaryText)
                    if !favoriteFilter.isEmpty {
                        Button { favoriteFilter = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(EditorialTheme.secondaryText)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(6)
                .background(EditorialTheme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                if favs.isEmpty {
                    Text("No matches")
                        .font(.system(size: 10))
                        .foregroundStyle(EditorialTheme.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                } else {
                    LazyVGrid(columns: gridColumns, spacing: 10) {
                        ForEach(favs) { fav in
                            Button { stageFavorite(fav) } label: {
                                artCard(imageURL: fav.imageURL, title: fav.name, subtitle: nil)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func stageFavorite(_ fav: SonosFavorite) {
        let isCloud = sonos.isCloudLinked
        pendingPlayback = PendingPlayback(title: fav.name, subtitle: nil, imageURL: fav.imageURL) { coordId in
            if isCloud {
                try await sonos.playFavorite(groupId: coordId, favoriteId: fav.id)
            } else if let uri = fav.uri {
                try await sonos.playMedia(playerId: coordId, uri: uri, metadata: fav.metadata ?? "")
            }
        }
    }

    // MARK: - Playlists

    @ViewBuilder
    private var playlistsSection: some View {
        if !sonos.playlists.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("PLAYLISTS")
                ForEach(sonos.playlists) { pl in
                    Button {
                        pendingPlayback = PendingPlayback(title: pl.name, subtitle: nil, imageURL: pl.imageURL) { coordId in
                            try await sonos.playPlaylist(groupId: coordId, playlistId: pl.id)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "music.note.list")
                                .font(.system(size: 10))
                                .foregroundStyle(EditorialTheme.accent)
                                .frame(width: 14)
                            Text(pl.name)
                                .font(.system(size: 11))
                                .foregroundStyle(EditorialTheme.primaryText)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "play.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(EditorialTheme.secondaryText)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .editorialCard(padding: 10)
        }
    }

    // MARK: - Shared Art Card

    private func artCard(imageURL: URL?, title: String, subtitle: String?) -> some View {
        VStack(spacing: 4) {
            if let imageURL {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay(
                        AsyncImage(url: imageURL) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Rectangle().fill(EditorialTheme.cardBackground)
                        }
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Rectangle()
                    .fill(EditorialTheme.cardBackground)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 18))
                            .foregroundStyle(EditorialTheme.secondaryText)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(EditorialTheme.primaryText)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 8))
                    .foregroundStyle(EditorialTheme.secondaryText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(EditorialTheme.secondaryText)
    }

    /// Flattened search results for the grid
    private func spotifyResultItems() -> [(uri: String, title: String, subtitle: String, imageURL: URL?)] {
        var items: [(uri: String, title: String, subtitle: String, imageURL: URL?)] = []
        if let tracks = spotify.searchResults.tracks {
            for t in tracks.items {
                items.append((t.uri, t.name, t.artists.map(\.name).joined(separator: ", "),
                              t.album.images.first.flatMap { URL(string: $0.url) }))
            }
        }
        if let albums = spotify.searchResults.albums {
            for a in albums.items {
                items.append((a.uri, a.name, a.artists.map(\.name).joined(separator: ", "),
                              a.images.first.flatMap { URL(string: $0.url) }))
            }
        }
        if let playlists = spotify.searchResults.playlists {
            for p in playlists.items {
                items.append((p.uri, p.name, p.owner?.display_name ?? "",
                              p.images?.first.flatMap { URL(string: $0.url) }))
            }
        }
        return items
    }
}

// MARK: - Play To Sheet

/// Confirmation sheet: shows what's about to play, lets the user pick speakers (multi-select), then Play.
private struct PlayToSheet: View {
    let pending: PendingPlayback
    @Environment(SonosManager.self) var sonos
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIds: Set<String> = []
    @State private var isPlaying = false
    @State private var showSavePreset = false
    @State private var presetName = ""

    private var isEverywhere: Bool {
        !sonos.players.isEmpty && sonos.players.allSatisfy { selectedIds.contains($0.id) }
    }

    private var sortedPlayers: [SonosPlayer] {
        sonos.players.sorted { $0.name < $1.name }
    }

    /// Whether the current selection exactly matches a preset
    private func isPresetSelected(_ preset: SonosGroupPreset) -> Bool {
        let presetSet = Set(preset.playerIds)
        return selectedIds == presetSet
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    contentPreview
                    speakerList

                    // Save as preset (when 2+ speakers selected and doesn't match existing preset)
                    if selectedIds.count >= 2 && !sonos.groupPresets.contains(where: { isPresetSelected($0) }) && !isEverywhere {
                        Button { showSavePreset = true } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus.circle")
                                    .font(.system(size: 13))
                                Text("Save as Group")
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .foregroundStyle(.orange)
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        isPlaying = true
                        let ids = selectedIds
                        print("PlayToSheet: PLAY tapped — selected \(ids.count) speakers: \(ids)")
                        Task {
                            do {
                                try await playOnSelected(ids: ids)
                            } catch {
                                print("PlayToSheet: playback failed — \(error)")
                            }
                            dismiss()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 14))
                            Text("Play")
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(selectedIds.isEmpty ? Color.gray : .orange, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .disabled(isPlaying || selectedIds.isEmpty)
                    .opacity(isPlaying ? 0.5 : 1)
                }
                .padding(24)
            }
            .navigationTitle("Play To")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.orange)
                }
            }
            .onAppear {
                if let first = sonos.coordinators.first {
                    let members = sonos.groupMembers(for: first)
                    selectedIds = Set(members.map(\.id))
                }
            }
            .alert("Save Group", isPresented: $showSavePreset) {
                TextField("Group name", text: $presetName)
                Button("Save") {
                    let name = presetName.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty {
                        sonos.addGroupPreset(name: name, playerIds: Array(selectedIds))
                    }
                    presetName = ""
                }
                Button("Cancel", role: .cancel) { presetName = "" }
            } message: {
                Text("Name this speaker group so you can quickly select it next time.")
            }
        }
    }

    private func playOnSelected(ids: Set<String>) async throws {
        guard !ids.isEmpty else { return }
        let coordinatorId = sonos.coordinators.first(where: { ids.contains($0.id) })?.id
            ?? ids.first!
        let memberIds = ids.filter { $0 != coordinatorId }
        let coordName = sonos.players.first(where: { $0.id == coordinatorId })?.name ?? "unknown"
        let memberNames = memberIds.compactMap { id in sonos.players.first(where: { $0.id == id })?.name }
        print("PlayToSheet: coordinator=\(coordName) (\(coordinatorId)), members=\(memberNames) (\(memberIds))")
        if memberIds.isEmpty {
            try await pending.play(coordinatorId)
        } else {
            try await sonos.groupAndPlay(coordinatorId: coordinatorId, memberIds: Array(memberIds), play: pending.play)
        }
    }

    // MARK: - Content Preview

    private var contentPreview: some View {
        VStack(spacing: 12) {
            if let imageURL = pending.imageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(.tertiarySystemBackground))
                            .overlay(
                                Image(systemName: "music.note")
                                    .font(.system(size: 32))
                                    .foregroundStyle(.secondary)
                            )
                    }
                }
                .frame(width: 160, height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.tertiarySystemBackground))
                    .frame(width: 160, height: 160)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                    )
            }

            Text(pending.title)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)

            if let subtitle = pending.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Speaker List

    private var speakerList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("SPEAKERS")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)

            // Everywhere
            speakerRow(
                icon: "house.fill",
                name: "Everywhere",
                subtitle: "\(sonos.players.count) speakers",
                isSelected: isEverywhere
            ) {
                if isEverywhere {
                    selectedIds.removeAll()
                } else {
                    selectedIds = Set(sonos.players.map(\.id))
                }
            }

            Divider()

            // Saved group presets
            ForEach(sonos.groupPresets) { preset in
                let names = sonos.presetDisplayNames(for: preset)
                let presetSelected = isPresetSelected(preset)

                speakerRow(
                    icon: "speaker.wave.2.circle.fill",
                    name: preset.name,
                    subtitle: names.joined(separator: ", "),
                    isSelected: presetSelected
                ) {
                    if presetSelected {
                        selectedIds.removeAll()
                    } else {
                        selectedIds = Set(preset.playerIds)
                    }
                }
                .contextMenu {
                    Button(role: .destructive) {
                        sonos.deleteGroupPreset(id: preset.id)
                    } label: {
                        Label("Delete Group", systemImage: "trash")
                    }
                }

                Divider()
            }

            // Individual speakers
            ForEach(sortedPlayers) { player in
                let isSelected = selectedIds.contains(player.id)
                let trackInfo = currentTrackInfo(for: player)

                speakerRow(
                    icon: nil,
                    name: player.name,
                    subtitle: trackInfo,
                    isSelected: isSelected
                ) {
                    if isSelected {
                        selectedIds.remove(player.id)
                    } else {
                        selectedIds.insert(player.id)
                    }
                }

                if player.id != sortedPlayers.last?.id {
                    Divider()
                }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func speakerRow(icon: String?, name: String, subtitle: String?, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 16))
                        .foregroundStyle(.orange)
                        .frame(width: 24)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(isSelected ? .orange : .secondary)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func currentTrackInfo(for player: SonosPlayer) -> String? {
        if let track = player.currentTrack, player.isCoordinator {
            return "\(track.title) — \(track.artist)"
        } else if !player.isCoordinator,
                  let coord = sonos.coordinators.first(where: { $0.id == player.groupId }),
                  let track = coord.currentTrack {
            return "\(track.title) — \(track.artist)"
        }
        return nil
    }
}
