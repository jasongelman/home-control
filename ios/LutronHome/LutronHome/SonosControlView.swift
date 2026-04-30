import SwiftUI

/// Full-screen Sonos control hub — speakers, groups, volume, now-playing, favorites.
struct SonosControlView: View {
    @Environment(SonosManager.self) var sonos
    @Environment(SpotifyManager.self) var spotify
    @Environment(\.dismiss) private var dismiss
    @State private var favoriteFilter = ""
    @State private var spotifyQuery = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var selectedSpeakerIds: Set<String> = []
    @State private var localVolumes: [String: Double] = [:]
    @State private var volumeDebounce: [String: Task<Void, Never>] = [:]

    private let gridColumns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                speakerCardsSection
                sourcesSection
                if spotify.isLinked {
                    spotifySearchSection
                    if !spotify.recentTracks.isEmpty && spotifyQuery.isEmpty {
                        recentlyPlayedSection
                    }
                }
                favoritesSection
                if sonos.isCloudLinked {
                    playlistsSection
                }
            }
            .padding()
        }
        .navigationTitle("Sonos")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
                    .foregroundStyle(EditorialTheme.accent)
            }
        }
        .onAppear {
            // Select all speakers by default
            if selectedSpeakerIds.isEmpty {
                selectedSpeakerIds = Set(sonos.coordinators.map(\.id))
            }
            // Load all data sources in parallel
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
                    }
                }()
                _ = await (cloud, local, spot)
            }
        }
    }

    // MARK: - Speaker Cards (2-Column)

    private var speakerCardsSection: some View {
        let cols = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        return HStack(alignment: .top, spacing: 10) {
            ForEach(sonos.coordinators) { coordinator in
                speakerCard(coordinator)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func speakerCard(_ coordinator: SonosPlayer) -> some View {
        let p = sonos.players.first(where: { $0.id == coordinator.id }) ?? coordinator
        let members = sonos.players.filter { coordinator.groupMembers.contains($0.id) }
        let allSpeakers = [p] + members
        let isSelected = selectedSpeakerIds.contains(p.id)

        return VStack(spacing: 8) {
            // Room name header — tap to select/deselect
            Button {
                if selectedSpeakerIds.contains(p.id) {
                    // Don't allow deselecting if it's the only one selected
                    if selectedSpeakerIds.count > 1 {
                        selectedSpeakerIds.remove(p.id)
                    }
                } else {
                    selectedSpeakerIds.insert(p.id)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 10))
                        .foregroundStyle(isSelected ? EditorialTheme.accent : EditorialTheme.secondaryText)
                    Text(p.name.uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(EditorialTheme.primaryText)
                        .lineLimit(1)
                    if !members.isEmpty {
                        Text("+\(members.count)")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(EditorialTheme.secondaryText)
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)

            // Album art — capped height so both cards fit on screen
            if let track = p.currentTrack {
                let artURL = track.albumArtURL
                if let artURL {
                    AsyncImage(url: artURL) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        case .failure:
                            Rectangle().fill(EditorialTheme.cardBackground)
                                .overlay(Image(systemName: "photo").foregroundStyle(EditorialTheme.tertiaryText))
                        default:
                            Rectangle().fill(EditorialTheme.cardBackground)
                        }
                    }
                    .frame(height: 120)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Rectangle()
                        .fill(EditorialTheme.cardBackground)
                        .frame(height: 120)
                        .frame(maxWidth: .infinity)
                        .overlay(
                            Image(systemName: "music.note")
                                .font(.system(size: 18))
                                .foregroundStyle(EditorialTheme.secondaryText)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                // Track title + artist below art
                Text(track.title)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(EditorialTheme.primaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                if !track.artist.isEmpty {
                    Text(track.artist)
                        .font(.system(size: 8))
                        .foregroundStyle(EditorialTheme.secondaryText)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }

                // Transport controls
                HStack(spacing: 16) {
                    Spacer()
                    transportButton("backward.fill", size: 10) {
                        try? await sonos.previous(playerId: p.id)
                    }
                    transportButton(p.state == .playing ? "pause.fill" : "play.fill", size: 14) {
                        if p.state == .playing {
                            try? await sonos.pausePlayback(playerId: p.id)
                        } else {
                            try? await sonos.play(playerId: p.id)
                        }
                    }
                    transportButton("forward.fill", size: 10) {
                        try? await sonos.next(playerId: p.id)
                    }
                    Spacer()
                }
            } else {
                // Not playing — show placeholder art capped to same height
                Rectangle()
                    .fill(EditorialTheme.cardBackground)
                    .frame(height: 120)
                    .frame(maxWidth: .infinity)
                    .overlay(
                        VStack(spacing: 4) {
                            Image(systemName: "speaker.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(EditorialTheme.tertiaryText)
                            Text("Not playing")
                                .font(.system(size: 9))
                                .foregroundStyle(EditorialTheme.tertiaryText)
                        }
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            // Volume for each speaker in this group
            ForEach(allSpeakers, id: \.id) { speaker in
                HStack(spacing: 4) {
                    Button {
                        Task { try? await sonos.setMute(playerId: speaker.id, muted: !speaker.isMuted) }
                    } label: {
                        Image(systemName: speaker.isMuted ? "speaker.slash.fill" : "speaker.wave.1.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(speaker.isMuted ? EditorialTheme.secondaryText : EditorialTheme.accent)
                            .frame(width: 12)
                    }
                    .buttonStyle(.plain)

                    if allSpeakers.count > 1 {
                        Text(speaker.name)
                            .font(.system(size: 7, weight: .medium))
                            .foregroundStyle(EditorialTheme.tertiaryText)
                            .lineLimit(1)
                            .frame(width: 40, alignment: .leading)
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
        .padding(10)
        .background(EditorialTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: EditorialTheme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: EditorialTheme.cardRadius)
                .stroke(isSelected ? EditorialTheme.accent.opacity(0.4) : EditorialTheme.cardBorder, lineWidth: isSelected ? 1.5 : 0.5)
        )
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
                Button {
                    let targets = selectedCoordinators
                    Task { for coord in targets { try? await sonos.playTVInput(playerId: coord.id) } }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "tv")
                            .font(.system(size: 11))
                            .foregroundStyle(EditorialTheme.accent)
                            .frame(width: 16)
                        Text("TV Audio")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(EditorialTheme.primaryText)
                        Spacer()
                        Text(sonos.tvCapableSpeakers.first?.name ?? "")
                            .font(.system(size: 9))
                            .foregroundStyle(EditorialTheme.secondaryText)
                        Image(systemName: "play.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(EditorialTheme.secondaryText)
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
            .editorialCard(padding: 10)
        }
    }

    // MARK: - Spotify Search

    private var spotifySearchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("SPOTIFY")

            // Search bar
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(EditorialTheme.secondaryText)
                TextField("Search tracks, albums, playlists…", text: $spotifyQuery)
                    .font(.system(size: 11))
                    .foregroundStyle(EditorialTheme.primaryText)
                    .onSubmit { performSpotifySearch() }
                    .onChange(of: spotifyQuery) {
                        searchTask?.cancel()
                        searchTask = Task {
                            try? await Task.sleep(for: .milliseconds(500))
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
                            .font(.system(size: 10))
                            .foregroundStyle(EditorialTheme.secondaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(EditorialTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))

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
                            Button { playSpotifyItem(uri: item.uri, title: item.title) } label: {
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
        Task {
            do { try await spotify.search(query: query) }
            catch { print("Spotify search error: \(error)") }
        }
    }

    /// Coordinators the user has selected for playback.
    private var selectedCoordinators: [SonosPlayer] {
        let sel = sonos.coordinators.filter { selectedSpeakerIds.contains($0.id) }
        return sel.isEmpty ? Array(sonos.coordinators.prefix(1)) : sel
    }

    private func playSpotifyItem(uri: String, title: String) {
        let targets = selectedCoordinators
        guard !targets.isEmpty else {
            print("SonosControlView: no selected coordinators for playback")
            return
        }
        let desc = sonos.spotifyServiceDesc ?? "SA_RINCON3079_X_#Svc3079-0-Token"
        let sonosURI = SpotifyManager.sonosURI(spotifyURI: uri, sn: sonos.spotifySN)
        let metadata = SpotifyManager.sonosMetadata(spotifyURI: uri, title: title, serviceDesc: desc)
        print("SonosControlView: playing '\(title)' on \(targets.map(\.name)) — uri=\(sonosURI)")
        Task {
            for coord in targets {
                do {
                    try await sonos.playMedia(playerId: coord.id, uri: sonosURI, metadata: metadata)
                } catch {
                    print("SonosControlView: playMedia failed for \(coord.name) — \(error)")
                }
            }
        }
    }

    // MARK: - Recently Played (3-Column Grid)

    private var recentlyPlayedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("RECENTLY PLAYED")
            LazyVGrid(columns: gridColumns, spacing: 10) {
                ForEach(spotify.recentTracks.prefix(9)) { track in
                    Button { playSpotifyItem(uri: track.uri, title: track.name) } label: {
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
                            Button { playFavorite(fav) } label: {
                                artCard(imageURL: fav.imageURL, title: fav.name, subtitle: nil)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func playFavorite(_ fav: SonosFavorite) {
        let targets = selectedCoordinators
        guard !targets.isEmpty else { return }
        Task {
            for coord in targets {
                if sonos.isCloudLinked {
                    try? await sonos.playFavorite(groupId: coord.groupId, favoriteId: fav.id)
                } else if let uri = fav.uri {
                    try? await sonos.playMedia(playerId: coord.id, uri: uri, metadata: fav.metadata ?? "")
                }
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
                        let targets = selectedCoordinators
                        Task { for coord in targets { try? await sonos.playPlaylist(groupId: coord.groupId, playlistId: pl.id) } }
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
                AsyncImage(url: imageURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(EditorialTheme.cardBackground)
                }
                .aspectRatio(1, contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Rectangle()
                    .fill(EditorialTheme.cardBackground)
                    .aspectRatio(1, contentMode: .fill)
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
                              p.images.first.flatMap { URL(string: $0.url) }))
            }
        }
        return items
    }
}
