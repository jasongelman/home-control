import SwiftUI

/// Full-screen Sonos control hub — speakers, groups, volume, now-playing, favorites.
struct SonosControlView: View {
    @Environment(SonosManager.self) var sonos
    @Environment(SpotifyManager.self) var spotify
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPlayerId: String?
    @State private var showGroupEditor = false
    @State private var favoriteFilter = ""
    @State private var spotifyQuery = ""
    @State private var searchTask: Task<Void, Never>?

    private var selectedPlayer: SonosPlayer? {
        guard let id = selectedPlayerId else { return nil }
        return sonos.players.first(where: { $0.id == id })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                speakersSection
                if let player = selectedPlayer {
                    nowPlayingSection(player)
                    transportSection(player)
                }
                volumeSection
                sourcesSection
                if spotify.isLinked {
                    spotifySearchSection
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
            // Auto-select the first playing coordinator, or first coordinator
            if selectedPlayerId == nil {
                selectedPlayerId = sonos.coordinators.first(where: { $0.state == .playing })?.id
                    ?? sonos.coordinators.first?.id
            }
            Task {
                if sonos.isCloudLinked {
                    try? await sonos.loadFavorites()
                    try? await sonos.loadPlaylists()
                }
                if sonos.favorites.isEmpty {
                    try? await sonos.loadLocalFavorites()
                }
            }
        }
    }

    // MARK: - Speakers Section

    private var speakersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("SPEAKERS")
                Spacer()
                Button {
                    showGroupEditor.toggle()
                } label: {
                    Text(showGroupEditor ? "DONE" : "GROUP")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(EditorialTheme.accent)
                }
                .buttonStyle(.plain)
            }

            ForEach(sonos.coordinators) { coordinator in
                let isSelected = coordinator.id == selectedPlayerId
                let members = sonos.players.filter {
                    coordinator.groupMembers.contains($0.id)
                }

                Button {
                    selectedPlayerId = coordinator.id
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Image(systemName: coordinator.state == .playing ? "speaker.wave.2.fill" : "speaker.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(coordinator.state == .playing ? EditorialTheme.accent : EditorialTheme.secondaryText)
                                .frame(width: 14)

                            Text(coordinator.name)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(EditorialTheme.primaryText)

                            if !members.isEmpty {
                                Text("+\(members.count)")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(EditorialTheme.secondaryText)
                            }

                            Spacer(minLength: 0)

                            if coordinator.state == .playing, let track = coordinator.currentTrack {
                                Text(track.title)
                                    .font(.system(size: 9))
                                    .foregroundStyle(EditorialTheme.secondaryText)
                                    .lineLimit(1)
                                    .frame(maxWidth: 100, alignment: .trailing)
                            }
                        }

                        if showGroupEditor && !members.isEmpty {
                            ForEach(members) { member in
                                HStack(spacing: 6) {
                                    Image(systemName: "link")
                                        .font(.system(size: 8))
                                        .foregroundStyle(EditorialTheme.secondaryText)
                                        .frame(width: 14)
                                    Text(member.name)
                                        .font(.system(size: 9))
                                        .foregroundStyle(EditorialTheme.secondaryText)
                                    Spacer()
                                    Button("Remove") {
                                        Task { try? await sonos.ungroupPlayer(playerId: member.id) }
                                    }
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundStyle(.red)
                                    .buttonStyle(.plain)
                                }
                                .padding(.leading, 4)
                            }
                        }
                    }
                    .padding(8)
                    .background(isSelected ? EditorialTheme.cardBackground : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: EditorialTheme.cardRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: EditorialTheme.cardRadius)
                            .stroke(isSelected ? EditorialTheme.accent.opacity(0.4) : EditorialTheme.cardBorder, lineWidth: isSelected ? 1 : 0.5)
                    )
                }
                .buttonStyle(.plain)

                if showGroupEditor {
                    groupAddRow(coordinator: coordinator)
                }
            }
        }
    }

    @ViewBuilder
    private func groupAddRow(coordinator: SonosPlayer) -> some View {
        let ungrouped = sonos.players.filter {
            $0.id != coordinator.id && !coordinator.groupMembers.contains($0.id) && $0.isCoordinator && $0.id != coordinator.groupId
        }
        if !ungrouped.isEmpty {
            HStack(spacing: 6) {
                Text("Add to group:")
                    .font(.system(size: 8))
                    .foregroundStyle(EditorialTheme.secondaryText)
                ForEach(ungrouped) { p in
                    Button {
                        Task { try? await sonos.groupPlayers(coordinatorId: coordinator.id, memberIds: [p.id]) }
                    } label: {
                        Text(p.name)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(EditorialTheme.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(EditorialTheme.accent, lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, 22)
            .padding(.bottom, 4)
        }
    }

    // MARK: - Now Playing

    private func nowPlayingSection(_ player: SonosPlayer) -> some View {
        let p = sonos.players.first(where: { $0.id == player.id }) ?? player
        return VStack(spacing: 8) {
            if let track = p.currentTrack {
                HStack(spacing: 12) {
                    if let artURL = track.albumArtURL {
                        AsyncImage(url: artURL) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Rectangle().fill(EditorialTheme.cardBackground)
                        }
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }

                    VStack(alignment: .leading, spacing: 2) {
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
                        if !track.album.isEmpty {
                            Text(track.album)
                                .font(.system(size: 9))
                                .foregroundStyle(EditorialTheme.tertiaryText)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .editorialCard(padding: 10)

                // Progress bar
                if track.duration > 0 {
                    VStack(spacing: 2) {
                        GeometryReader { geo in
                            let progress = min(track.position / track.duration, 1.0)
                            ZStack(alignment: .leading) {
                                Rectangle().fill(EditorialTheme.cardBorder).frame(height: 2)
                                Rectangle().fill(EditorialTheme.accent).frame(width: geo.size.width * progress, height: 2)
                            }
                        }
                        .frame(height: 2)

                        HStack {
                            Text(formatTime(track.position))
                            Spacer()
                            Text(formatTime(track.duration))
                        }
                        .font(.system(size: 8, weight: .medium).monospacedDigit())
                        .foregroundStyle(EditorialTheme.secondaryText)
                    }
                }
            } else {
                HStack {
                    Image(systemName: "speaker.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(EditorialTheme.secondaryText)
                    Text("Nothing playing on \(p.name)")
                        .font(.system(size: 11))
                        .foregroundStyle(EditorialTheme.secondaryText)
                    Spacer()
                }
                .editorialCard(padding: 10)
            }
        }
    }

    // MARK: - Transport

    private func transportSection(_ player: SonosPlayer) -> some View {
        let p = sonos.players.first(where: { $0.id == player.id }) ?? player
        return HStack(spacing: 28) {
            Spacer()
            transportButton("backward.fill") {
                try? await sonos.previous(playerId: p.id)
            }
            transportButton(p.state == .playing ? "pause.fill" : "play.fill", size: 20) {
                if p.state == .playing {
                    try? await sonos.pausePlayback(playerId: p.id)
                } else {
                    try? await sonos.play(playerId: p.id)
                }
            }
            transportButton("forward.fill") {
                try? await sonos.next(playerId: p.id)
            }
            Spacer()
        }
    }

    private func transportButton(_ icon: String, size: CGFloat = 14, action: @escaping () async throws -> Void) -> some View {
        Button {
            Task { try? await action() }
        } label: {
            Image(systemName: icon)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(EditorialTheme.primaryText)
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Volume Section

    private var volumeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("VOLUME")

            ForEach(sonos.players) { player in
                HStack(spacing: 8) {
                    Button {
                        Task { try? await sonos.setMute(playerId: player.id, muted: !player.isMuted) }
                    } label: {
                        Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(player.isMuted ? EditorialTheme.secondaryText : EditorialTheme.accent)
                            .frame(width: 16)
                    }
                    .buttonStyle(.plain)

                    Text(player.name)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(EditorialTheme.primaryText)
                        .frame(width: 70, alignment: .leading)
                        .lineLimit(1)

                    Slider(
                        value: Binding(
                            get: { Double(player.volume) },
                            set: { newVal in
                                Task { try? await sonos.setVolume(playerId: player.id, level: Int(newVal)) }
                            }
                        ),
                        in: 0...100
                    )
                    .tint(EditorialTheme.accent)

                    Text("\(player.volume)")
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(EditorialTheme.secondaryText)
                        .frame(width: 22, alignment: .trailing)
                }
            }
        }
        .editorialCard(padding: 10)
    }

    // MARK: - Sources (TV Audio)

    @ViewBuilder
    private var sourcesSection: some View {
        if !sonos.tvCapableSpeakers.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("SOURCES")

                Button {
                    guard let playerId = selectedPlayerId else { return }
                    Task { try? await sonos.playTVInput(playerId: playerId) }
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
            sectionLabel("SPOTIFY SEARCH")

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
                        // Debounced search
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
                HStack {
                    Spacer()
                    ProgressView().scaleEffect(0.7)
                    Spacer()
                }
                .padding(.vertical, 8)
            } else {
                // Tracks
                if let tracks = spotify.searchResults.tracks, !tracks.items.isEmpty {
                    Text("TRACKS")
                        .font(.system(size: 8, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(EditorialTheme.tertiaryText)
                        .padding(.top, 4)

                    ForEach(tracks.items) { track in
                        Button {
                            playSpotifyItem(uri: track.uri, title: track.name)
                        } label: {
                            HStack(spacing: 8) {
                                if let img = track.album.images.last {
                                    AsyncImage(url: URL(string: img.url)) { image in
                                        image.resizable().aspectRatio(contentMode: .fill)
                                    } placeholder: {
                                        Rectangle().fill(EditorialTheme.cardBackground)
                                    }
                                    .frame(width: 32, height: 32)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(track.name)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(EditorialTheme.primaryText)
                                        .lineLimit(1)
                                    Text(track.artists.map(\.name).joined(separator: ", "))
                                        .font(.system(size: 8))
                                        .foregroundStyle(EditorialTheme.secondaryText)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "play.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(EditorialTheme.accent)
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Albums
                if let albums = spotify.searchResults.albums, !albums.items.isEmpty {
                    Text("ALBUMS")
                        .font(.system(size: 8, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(EditorialTheme.tertiaryText)
                        .padding(.top, 4)

                    ForEach(albums.items) { album in
                        Button {
                            playSpotifyItem(uri: album.uri, title: album.name)
                        } label: {
                            HStack(spacing: 8) {
                                if let img = album.images.last {
                                    AsyncImage(url: URL(string: img.url)) { image in
                                        image.resizable().aspectRatio(contentMode: .fill)
                                    } placeholder: {
                                        Rectangle().fill(EditorialTheme.cardBackground)
                                    }
                                    .frame(width: 32, height: 32)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(album.name)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(EditorialTheme.primaryText)
                                        .lineLimit(1)
                                    Text(album.artists.map(\.name).joined(separator: ", "))
                                        .font(.system(size: 8))
                                        .foregroundStyle(EditorialTheme.secondaryText)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "play.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(EditorialTheme.accent)
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Playlists
                if let playlists = spotify.searchResults.playlists, !playlists.items.isEmpty {
                    Text("PLAYLISTS")
                        .font(.system(size: 8, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(EditorialTheme.tertiaryText)
                        .padding(.top, 4)

                    ForEach(playlists.items) { playlist in
                        Button {
                            playSpotifyItem(uri: playlist.uri, title: playlist.name)
                        } label: {
                            HStack(spacing: 8) {
                                if let img = playlist.images.first {
                                    AsyncImage(url: URL(string: img.url)) { image in
                                        image.resizable().aspectRatio(contentMode: .fill)
                                    } placeholder: {
                                        Rectangle().fill(EditorialTheme.cardBackground)
                                    }
                                    .frame(width: 32, height: 32)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(playlist.name)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(EditorialTheme.primaryText)
                                        .lineLimit(1)
                                    if let owner = playlist.owner?.display_name {
                                        Text(owner)
                                            .font(.system(size: 8))
                                            .foregroundStyle(EditorialTheme.secondaryText)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "play.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(EditorialTheme.accent)
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .editorialCard(padding: 10)
    }

    private func performSpotifySearch() {
        let query = spotifyQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { try? await spotify.search(query: query) }
    }

    private func playSpotifyItem(uri: String, title: String) {
        guard let playerId = selectedPlayerId else { return }
        let desc = sonos.spotifyServiceDesc ?? "SA_RINCON3079_X_#Svc3079-0-Token"
        let sonosURI = SpotifyManager.sonosURI(spotifyURI: uri, sn: sonos.spotifySN)
        let metadata = SpotifyManager.sonosMetadata(spotifyURI: uri, title: title, serviceDesc: desc)
        Task { try? await sonos.playMedia(playerId: playerId, uri: sonosURI, metadata: metadata) }
    }

    // MARK: - Favorites

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

                // Filter bar
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(EditorialTheme.secondaryText)
                    TextField("Filter favorites…", text: $favoriteFilter)
                        .font(.system(size: 11))
                        .foregroundStyle(EditorialTheme.primaryText)
                    if !favoriteFilter.isEmpty {
                        Button {
                            favoriteFilter = ""
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

                if favs.isEmpty {
                    Text("No matches")
                        .font(.system(size: 10))
                        .foregroundStyle(EditorialTheme.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(favs) { fav in
                            Button {
                                playFavorite(fav)
                            } label: {
                                VStack(spacing: 4) {
                                    if let imageURL = fav.imageURL {
                                        AsyncImage(url: imageURL) { image in
                                            image.resizable().aspectRatio(contentMode: .fill)
                                        } placeholder: {
                                            Rectangle().fill(EditorialTheme.cardBackground)
                                        }
                                        .frame(height: 80)
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                    } else {
                                        Rectangle()
                                            .fill(EditorialTheme.cardBackground)
                                            .frame(height: 80)
                                            .overlay(
                                                Image(systemName: "music.note")
                                                    .font(.system(size: 16))
                                                    .foregroundStyle(EditorialTheme.secondaryText)
                                            )
                                            .clipShape(RoundedRectangle(cornerRadius: 4))
                                    }
                                    Text(fav.name)
                                        .font(.system(size: 8, weight: .medium))
                                        .foregroundStyle(EditorialTheme.primaryText)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.center)
                                        .frame(height: 20)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func playFavorite(_ fav: SonosFavorite) {
        guard let player = selectedPlayer else { return }
        Task {
            if sonos.isCloudLinked {
                try? await sonos.playFavorite(groupId: player.groupId, favoriteId: fav.id)
            } else if let uri = fav.uri {
                try? await sonos.playMedia(playerId: player.id, uri: uri, metadata: fav.metadata ?? "")
            }
        }
    }

    // MARK: - Playlists

    @ViewBuilder
    private var playlistsSection: some View {
        if !sonos.playlists.isEmpty, let player = selectedPlayer {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("PLAYLISTS")

                ForEach(sonos.playlists) { pl in
                    Button {
                        Task { try? await sonos.playPlaylist(groupId: player.groupId, playlistId: pl.id) }
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

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(EditorialTheme.secondaryText)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
