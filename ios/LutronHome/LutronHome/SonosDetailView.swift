import SwiftUI

struct SonosDetailView: View {
    let player: SonosPlayer
    @Environment(SonosManager.self) var sonos
    @Environment(\.dismiss) private var dismiss
    @State private var scrubPosition: Double?
    @State private var localVolumes: [String: Double] = [:]
    @State private var volumeDebounce: [String: Task<Void, Never>] = [:]
    @State private var showSpeakerPicker = false
    /// The coordinator whose group is currently targeted for playback.
    /// Defaults to the player this view was opened with.
    @State private var targetCoordinatorId: String?

    init(player: SonosPlayer) {
        self.player = player
    }

    private var currentPlayer: SonosPlayer {
        sonos.players.first(where: { $0.id == player.id }) ?? player
    }

    /// The coordinator we're targeting — either the one the user picked, or the original player.
    private var targetCoordinator: SonosPlayer {
        if let id = targetCoordinatorId,
           let coord = sonos.coordinators.first(where: { $0.id == id }) {
            return coord
        }
        // Fall back to the player this view was opened with (if it's a coordinator)
        if currentPlayer.isCoordinator { return currentPlayer }
        // Otherwise find its coordinator
        return sonos.coordinators.first(where: { $0.id == currentPlayer.groupId }) ?? currentPlayer
    }

    /// All speakers in the target coordinator's group
    private var targetGroupPlayers: [SonosPlayer] {
        sonos.groupMembers(for: targetCoordinator)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    heroAlbumArt
                    VStack(spacing: 20) {
                        trackInfo
                        progressBar
                        transportRow
                        speakerButton
                        volumeSection
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    .padding(.bottom, 40)
                }
            }
            .ignoresSafeArea(.container, edges: .top)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.orange)
                }
            }
            .sheet(isPresented: $showSpeakerPicker) {
                SpeakerPickerSheet(
                    selectedCoordinatorId: Binding(
                        get: { targetCoordinator.id },
                        set: { targetCoordinatorId = $0 }
                    )
                )
                .presentationDetents([.medium])
            }
        }
    }

    // MARK: - Hero Album Art

    private var heroAlbumArt: some View {
        Group {
            if let track = targetCoordinator.currentTrack, let artURL = track.albumArtURL {
                AsyncImage(url: artURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Rectangle().fill(Color(.tertiarySystemBackground))
                            .overlay(
                                Image(systemName: "music.note")
                                    .font(.system(size: 48))
                                    .foregroundStyle(.secondary)
                            )
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .clipped()
            } else {
                Rectangle()
                    .fill(Color(.tertiarySystemBackground))
                    .aspectRatio(1, contentMode: .fit)
                    .overlay(
                        Image(systemName: "speaker.wave.2")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                    )
            }
        }
    }

    // MARK: - Track Info

    private var trackInfo: some View {
        VStack(spacing: 4) {
            if let track = targetCoordinator.currentTrack {
                Text(track.title)
                    .font(.title2.weight(.bold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                let subtitle = [track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " · ")
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                Text("Not Playing")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Progress Bar

    @ViewBuilder
    private var progressBar: some View {
        if let track = targetCoordinator.currentTrack, track.duration > 0 {
            VStack(spacing: 4) {
                Slider(
                    value: Binding(
                        get: { scrubPosition ?? track.position },
                        set: { scrubPosition = $0 }
                    ),
                    in: 0...max(track.duration, 1)
                ) { editing in
                    if !editing, let pos = scrubPosition {
                        Task { try? await sonos.seek(playerId: targetCoordinator.id, position: pos) }
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
                Task { try? await sonos.previous(playerId: targetCoordinator.id) }
            } label: {
                Image(systemName: "backward.fill")
                    .font(.title2)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)

            Button {
                Task {
                    if targetCoordinator.state == .playing {
                        try? await sonos.pausePlayback(playerId: targetCoordinator.id)
                    } else {
                        try? await sonos.play(playerId: targetCoordinator.id)
                    }
                }
            } label: {
                Image(systemName: targetCoordinator.state == .playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)

            Button {
                Task { try? await sonos.next(playerId: targetCoordinator.id) }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title2)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Speaker Button

    private var speakerButton: some View {
        let memberCount = targetGroupPlayers.count

        return Button { showSpeakerPicker = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 12))
                if memberCount > 1 {
                    Text("\(targetCoordinator.name) + \(memberCount - 1)")
                        .font(.system(size: 13, weight: .medium))
                } else {
                    Text(targetCoordinator.name)
                        .font(.system(size: 13, weight: .medium))
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Volume Section

    private var volumeSection: some View {
        VStack(spacing: 10) {
            ForEach(targetGroupPlayers) { gPlayer in
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

                    if targetGroupPlayers.count > 1 {
                        Text(gPlayer.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .leading)
                    }

                    Slider(
                        value: Binding(
                            get: { localVolumes[gPlayer.id] ?? Double(gPlayer.volume) },
                            set: { newVal in
                                localVolumes[gPlayer.id] = newVal
                                volumeDebounce[gPlayer.id]?.cancel()
                                volumeDebounce[gPlayer.id] = Task {
                                    try? await Task.sleep(for: .milliseconds(150))
                                    guard !Task.isCancelled else { return }
                                    try? await sonos.setVolume(playerId: gPlayer.id, level: Int(newVal))
                                }
                            }
                        ),
                        in: 0...100
                    )
                    .tint(.orange)

                    Text("\(Int(localVolumes[gPlayer.id] ?? Double(gPlayer.volume)))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .trailing)
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

// MARK: - Speaker Picker Sheet

private struct SpeakerPickerSheet: View {
    @Binding var selectedCoordinatorId: String
    @Environment(SonosManager.self) var sonos
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(sonos.coordinators) { coordinator in
                    let members = sonos.groupMembers(for: coordinator)
                    let isSelected = coordinator.id == selectedCoordinatorId

                    Button {
                        selectedCoordinatorId = coordinator.id
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(coordinator.name)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)

                                if members.count > 1 {
                                    Text(members.map(\.name).joined(separator: ", "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                if let track = coordinator.currentTrack {
                                    Text("\(track.title) — \(track.artist)")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                } else {
                                    Text("Not playing")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }

                            Spacer()

                            if isSelected {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(.orange)
                            } else {
                                Image(systemName: "circle")
                                    .font(.system(size: 20))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Speakers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}
