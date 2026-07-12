import SwiftUI

struct EditorialSonosSection: View {
    @Environment(SonosManager.self) var sonos

    var body: some View {
        let active = sonos.coordinators.filter { $0.state == .playing || $0.currentTrack != nil }
        if !active.isEmpty {
            VStack(alignment: .leading, spacing: EditorialTheme.gridSpacing) {
                EditorialSectionHeader(
                    title: "NOW PLAYING",
                    trailing: "\(active.count) SPEAKER\(active.count == 1 ? "" : "S")"
                )

                ForEach(active, id: \.id) { player in
                    SonosCard(player: player)
                }
            }
        }
    }
}

private struct SonosCard: View {
    let player: SonosPlayer
    @Environment(SonosManager.self) var sonos
    @State private var showDetail = false

    var body: some View {
        Button { showDetail = true } label: {
            HStack(spacing: 10) {
                // Album art (left-aligned, matching row height)
                if let track = player.currentTrack, let artURL = track.albumArtURL {
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
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                VStack(alignment: .leading, spacing: 4) {
                    // Group name
                    Text(sonos.groupDisplayName(for: player).uppercased())
                        .font(.system(size: 9, weight: .medium))
                        .tracking(0.8)
                        .foregroundStyle(EditorialTheme.secondaryText)

                    // Track info
                    if let track = player.currentTrack {
                        Text(track.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(EditorialTheme.primaryText)
                            .lineLimit(1)
                        if !track.artist.isEmpty {
                            Text(track.artist)
                                .font(.system(size: 10))
                                .foregroundStyle(EditorialTheme.secondaryText)
                                .lineLimit(1)
                        }
                    } else {
                        Text("Not Playing")
                            .font(.system(size: 12))
                            .foregroundStyle(EditorialTheme.secondaryText)
                    }
                }

                Spacer(minLength: 4)

                // Transport controls
                HStack(spacing: 12) {
                    transportButton("backward.fill") {
                        try? await sonos.previous(playerId: player.id)
                    }

                    transportButton(player.state == .playing ? "pause.fill" : "play.fill") {
                        if player.state == .playing {
                            try? await sonos.pausePlayback(playerId: player.id)
                        } else {
                            try? await sonos.play(playerId: player.id)
                        }
                    }

                    transportButton("forward.fill") {
                        try? await sonos.next(playerId: player.id)
                    }
                }
            }
            .padding(10)
            .background(EditorialTheme.cardBackground)
            .overlay(Rectangle().stroke(EditorialTheme.cardBorder, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showDetail) {
            SonosDetailView(player: player)
        }
    }

    private func transportButton(_ icon: String, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(EditorialTheme.accent)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
    }
}
