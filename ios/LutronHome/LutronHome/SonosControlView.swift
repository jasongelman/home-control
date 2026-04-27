import SwiftUI

/// Full-screen Sonos control hub — speakers, groups, volume, now-playing, favorites.
struct SonosControlView: View {
    @Environment(SonosManager.self) var sonos
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPlayerId: String?
    @State private var showGroupEditor = false
    @State private var showMediaBrowser = false
    @State private var browseStack: [(id: String, title: String)] = []
    @State private var browseItems: [SonosContentItem] = []
    @State private var isBrowsing = false

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
                if showMediaBrowser {
                    mediaBrowserSection
                }
                if sonos.isCloudLinked {
                    favoritesSection
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
            if sonos.isCloudLinked {
                Task {
                    try? await sonos.loadFavorites()
                    try? await sonos.loadPlaylists()
                }
            }
            Task { try? await sonos.loadMusicServices() }
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

    // MARK: - Sources (TV + Music Services)

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("SOURCES")

            // TV input
            if !sonos.tvCapableSpeakers.isEmpty {
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

            // Music services
            ForEach(sonos.musicServices) { service in
                Button {
                    browseStack = [(id: service.containerID, title: service.name)]
                    showMediaBrowser = true
                    Task { await browseInto(objectID: service.containerID) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: serviceIcon(service.name))
                            .font(.system(size: 11))
                            .foregroundStyle(EditorialTheme.accent)
                            .frame(width: 16)
                        Text(service.name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(EditorialTheme.primaryText)
                        Spacer()
                        Image(systemName: "chevron.right")
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

    private func serviceIcon(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("spotify") { return "waveform" }
        if lower.contains("audible") || lower.contains("audiobook") { return "book.fill" }
        if lower.contains("amazon") { return "music.note" }
        if lower.contains("apple") { return "music.note" }
        if lower.contains("radio") || lower.contains("tunein") { return "radio" }
        if lower.contains("podcast") { return "mic.fill" }
        if lower.contains("soundcloud") { return "cloud.fill" }
        return "music.note.list"
    }

    // MARK: - Media Browser

    private var mediaBrowserSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Breadcrumb navigation
            HStack(spacing: 4) {
                ForEach(Array(browseStack.enumerated()), id: \.offset) { index, crumb in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 7))
                            .foregroundStyle(EditorialTheme.tertiaryText)
                    }
                    Button {
                        // Navigate back to this level
                        browseStack = Array(browseStack.prefix(index + 1))
                        Task { await browseInto(objectID: crumb.id) }
                    } label: {
                        Text(crumb.title.uppercased())
                            .font(.system(size: 8, weight: index == browseStack.count - 1 ? .bold : .medium))
                            .tracking(0.4)
                            .foregroundStyle(index == browseStack.count - 1 ? EditorialTheme.primaryText : EditorialTheme.secondaryText)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Button {
                    showMediaBrowser = false
                    browseStack = []
                    browseItems = []
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(EditorialTheme.secondaryText)
                }
                .buttonStyle(.plain)
            }

            if isBrowsing {
                HStack {
                    Spacer()
                    ProgressView()
                        .scaleEffect(0.7)
                    Spacer()
                }
                .padding(.vertical, 12)
            } else if browseItems.isEmpty {
                Text("No items found")
                    .font(.system(size: 10))
                    .foregroundStyle(EditorialTheme.secondaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            } else {
                ForEach(browseItems) { item in
                    if item.isContainer {
                        Button {
                            browseStack.append((id: item.id, title: item.title))
                            Task { await browseInto(objectID: item.id) }
                        } label: {
                            contentRow(item: item, isContainer: true)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            guard let playerId = selectedPlayerId else { return }
                            Task { try? await sonos.playMedia(playerId: playerId, uri: item.uri, metadata: item.metadata) }
                        } label: {
                            contentRow(item: item, isContainer: false)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .editorialCard(padding: 10)
    }

    private func contentRow(item: SonosContentItem, isContainer: Bool) -> some View {
        HStack(spacing: 8) {
            if !item.albumArtURI.isEmpty {
                let artURL = item.albumArtURI.hasPrefix("http")
                    ? URL(string: item.albumArtURI)
                    : URL(string: "\(sonos.players.first?.baseURL ?? "")\(item.albumArtURI)")
                AsyncImage(url: artURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(EditorialTheme.cardBackground)
                }
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: isContainer ? "folder.fill" : "music.note")
                    .font(.system(size: 10))
                    .foregroundStyle(EditorialTheme.secondaryText)
                    .frame(width: 32, height: 32)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(EditorialTheme.primaryText)
                    .lineLimit(1)
                if !item.artist.isEmpty {
                    Text(item.artist)
                        .font(.system(size: 8))
                        .foregroundStyle(EditorialTheme.secondaryText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: isContainer ? "chevron.right" : "play.fill")
                .font(.system(size: 9))
                .foregroundStyle(isContainer ? EditorialTheme.secondaryText : EditorialTheme.accent)
        }
        .padding(.vertical, 3)
    }

    private func browseInto(objectID: String) async {
        isBrowsing = true
        let items = (try? await sonos.browseContent(objectID: objectID)) ?? []
        await MainActor.run {
            browseItems = items
            isBrowsing = false
        }
    }

    // MARK: - Favorites

    @ViewBuilder
    private var favoritesSection: some View {
        if !sonos.favorites.isEmpty, let player = selectedPlayer {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("FAVORITES")

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(sonos.favorites) { fav in
                        Button {
                            Task { try? await sonos.playFavorite(groupId: player.groupId, favoriteId: fav.id) }
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
