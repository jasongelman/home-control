import SwiftUI

struct SonosDetailView: View {
    let player: SonosPlayer
    @Environment(SonosManager.self) var sonos
    @Environment(\.dismiss) private var dismiss
    @State private var localVolume: Double
    @State private var queueTracks: [SonosTrack] = []
    @State private var showQueue = false
    @State private var showGrouping = false
    @State private var scrubPosition: Double?

    init(player: SonosPlayer) {
        self.player = player
        _localVolume = State(initialValue: Double(player.volume))
    }

    private var currentPlayer: SonosPlayer {
        sonos.players.first(where: { $0.id == player.id }) ?? player
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    nowPlayingCard
                    progressBar
                    transportRow
                    volumeSection
                    if showQueue { queueSection }
                    if showGrouping { groupSection }
                    if sonos.isCloudLinked && !sonos.favorites.isEmpty { favoritesSection }
                }
                .padding()
            }
            .navigationTitle(currentPlayer.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.orange)
                }
            }
        }
        .onAppear {
            Task {
                queueTracks = (try? await sonos.getQueue(playerId: player.id)) ?? []
            }
        }
        .onChange(of: currentPlayer.volume) { _, newValue in
            localVolume = Double(newValue)
        }
    }

    // MARK: - Now Playing Card

    private var nowPlayingCard: some View {
        VStack(spacing: 12) {
            if let track = currentPlayer.currentTrack {
                if let artURL = track.albumArtURL {
                    AsyncImage(url: artURL) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(.tertiarySystemBackground))
                            .overlay(
                                Image(systemName: "music.note")
                                    .font(.system(size: 40))
                                    .foregroundStyle(.secondary)
                            )
                    }
                    .frame(width: 240, height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Text(track.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(track.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !track.album.isEmpty {
                    Text(track.album)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 40)
                Text("Not Playing")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Progress Bar

    @ViewBuilder
    private var progressBar: some View {
        if let track = currentPlayer.currentTrack, track.duration > 0 {
            VStack(spacing: 4) {
                Slider(
                    value: Binding(
                        get: { scrubPosition ?? track.position },
                        set: { scrubPosition = $0 }
                    ),
                    in: 0...max(track.duration, 1)
                ) { editing in
                    if !editing, let pos = scrubPosition {
                        Task { try? await sonos.seek(playerId: player.id, position: pos) }
                        scrubPosition = nil
                    }
                }
                .tint(.orange)

                HStack {
                    Text(formatTime(scrubPosition ?? track.position))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(formatTime(track.duration))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Transport Row

    private var transportRow: some View {
        HStack(spacing: 32) {
            Button {
                Task { try? await sonos.previous(playerId: player.id) }
            } label: {
                Image(systemName: "backward.fill")
                    .font(.title2)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)

            Button {
                Task {
                    if currentPlayer.state == .playing {
                        try? await sonos.pausePlayback(playerId: player.id)
                    } else {
                        try? await sonos.play(playerId: player.id)
                    }
                }
            } label: {
                Image(systemName: currentPlayer.state == .playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)

            Button {
                Task { try? await sonos.next(playerId: player.id) }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title2)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Volume Section

    private var volumeSection: some View {
        VStack(spacing: 8) {
            let groupPlayers = sonos.players.filter {
                $0.id == currentPlayer.id || currentPlayer.groupMembers.contains($0.id)
            }

            ForEach(groupPlayers) { gPlayer in
                HStack(spacing: 12) {
                    Button {
                        Task { try? await sonos.setMute(playerId: gPlayer.id, muted: !gPlayer.isMuted) }
                    } label: {
                        Image(systemName: gPlayer.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(gPlayer.isMuted ? Color.secondary : Color.orange)
                            .frame(width: 24)
                    }
                    .buttonStyle(.plain)

                    if groupPlayers.count > 1 {
                        Text(gPlayer.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .leading)
                    }

                    Slider(
                        value: Binding(
                            get: { Double(gPlayer.volume) },
                            set: { newVal in
                                Task { try? await sonos.setVolume(playerId: gPlayer.id, level: Int(newVal)) }
                            }
                        ),
                        in: 0...100
                    )
                    .tint(.orange)

                    Text("\(gPlayer.volume)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .trailing)
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Queue Section

    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Queue")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Spacer()
                if !queueTracks.isEmpty {
                    Button("Clear") {
                        Task {
                            try? await sonos.clearQueue(playerId: player.id)
                            queueTracks = []
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.red)
                }
            }

            if queueTracks.isEmpty {
                Text("Queue is empty")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                ForEach(Array(queueTracks.enumerated()), id: \.offset) { index, track in
                    HStack(spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title)
                                .font(.caption)
                                .lineLimit(1)
                            Text(track.artist)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button {
                            Task {
                                try? await sonos.removeFromQueue(playerId: player.id, index: index)
                                queueTracks.remove(at: index)
                            }
                        } label: {
                            Image(systemName: "minus.circle")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Group Section

    private var groupSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Speakers")
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)

            ForEach(sonos.players) { p in
                let isInGroup = p.id == currentPlayer.id || currentPlayer.groupMembers.contains(p.id)
                HStack(spacing: 10) {
                    Image(systemName: isInGroup ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isInGroup ? .orange : .secondary)
                    Text(p.name)
                        .font(.subheadline)
                    Spacer()
                    if p.id != currentPlayer.id {
                        Button(isInGroup ? "Remove" : "Add") {
                            Task {
                                if isInGroup {
                                    try? await sonos.ungroupPlayer(playerId: p.id)
                                } else {
                                    try? await sonos.groupPlayers(coordinatorId: currentPlayer.id, memberIds: [p.id])
                                }
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(isInGroup ? .red : .orange)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Favorites Section

    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Favorites")
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(sonos.favorites) { fav in
                    Button {
                        Task { try? await sonos.playFavorite(groupId: currentPlayer.groupId, favoriteId: fav.id) }
                    } label: {
                        VStack(spacing: 6) {
                            if let imageURL = fav.imageURL {
                                AsyncImage(url: imageURL) { image in
                                    image.resizable().aspectRatio(contentMode: .fill)
                                } placeholder: {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color(.tertiarySystemBackground))
                                }
                                .frame(width: 80, height: 80)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            } else {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(.tertiarySystemBackground))
                                    .frame(width: 80, height: 80)
                                    .overlay(
                                        Image(systemName: "music.note")
                                            .foregroundStyle(.secondary)
                                    )
                            }
                            Text(fav.name)
                                .font(.caption2)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Helpers

    private func formatTime(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
