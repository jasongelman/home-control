import SwiftUI
import HomeKit

struct EditorialCameraSection: View {
    @Environment(HomeKitManager.self) var homeKit
    @State private var showDetail = false

    var body: some View {
        let cameras = homeKit.cameras
        let offline = homeKit.unavailableCameras

        // A tile is shown only when the camera currently has a real live snapshot
        // AND isn't marked offline. We deliberately do NOT fall back to a cached
        // frame: HMCameraView's offscreen render can produce an all-black image
        // (see the note on HMCameraViewRepresentable), and a camera that never
        // connects to HomeKit ends up caching exactly that black frame — which then
        // renders as a permanent black "OFFLINE" tile. Keying on the live snapshot
        // instead hides such a camera entirely, and keeps it hidden through the
        // foreground `unavailableCameras.removeAll()` re-try window since it never
        // gains a snapshot. Indices are into `homeKit.cameras` and preserved so each
        // tile's `cameraIndex` resolves to the right snapshot control / selection.
        let visibleIndices = cameras.indices.filter { i in
            let cam = cameras[i]
            let hasSnapshot = cam.profile.snapshotControl?.mostRecentSnapshot != nil
            return hasSnapshot && !offline.contains(cam.accessory.name)
        }

        if !visibleIndices.isEmpty {
            let visibleCount = visibleIndices.count
            let liveCount = visibleIndices.filter { !offline.contains(cameras[$0].accessory.name) }.count

            VStack(alignment: .leading, spacing: EditorialTheme.gridSpacing) {
                EditorialSectionHeader(
                    title: "CAMERAS",
                    trailing: liveCount == visibleCount
                        ? "\(visibleCount) FEEDS"
                        : "\(liveCount)/\(visibleCount) LIVE"
                )

                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: EditorialTheme.gridSpacing
                ) {
                    ForEach(visibleIndices, id: \.self) { index in
                        let camera = cameras[index]
                        LiveCameraTile(
                            cameraIndex: index,
                            name: camera.accessory.name,
                            hasMotion: homeKit.motionDetectedCameras.contains(camera.accessory.name),
                            isOffline: offline.contains(camera.accessory.name)
                        ) {
                            homeKit.selectCamera(index: index)
                            showDetail = true
                        }
                    }
                }
            }
            .sheet(isPresented: $showDetail) {
                CameraDetailView(homeKit: homeKit)
            }
        }
    }
}

// MARK: - Live Camera Tile (uses HMCameraView directly)

private struct LiveCameraTile: View {
    @Environment(HomeKitManager.self) var homeKit
    let cameraIndex: Int
    let name: String
    let hasMotion: Bool
    let isOffline: Bool
    let onTap: () -> Void

    @State private var refreshTimer: Timer?

    var body: some View {
        let snapshotControl = homeKit.cameras[safe: cameraIndex]?.profile.snapshotControl
        let hasLiveSnapshot = snapshotControl?.mostRecentSnapshot != nil

        Button(action: onTap) {
            ZStack(alignment: .bottomLeading) {
                if hasLiveSnapshot && !isOffline {
                    // Live HMCameraView rendering the snapshot
                    HMCameraViewRepresentable(
                        snapshotControl: snapshotControl,
                        generation: homeKit.snapshotGeneration
                    )
                    .frame(height: 100)
                    .clipped()
                } else if let lastFrame = homeKit.cachedImages[name] {
                    // Last known frame, desaturated, so the tile is never black
                    Image(uiImage: lastFrame)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 100)
                        .clipped()
                        .saturation(0)
                        .overlay(Color.black.opacity(0.35))
                } else {
                    Rectangle()
                        .fill(Color.black)
                        .frame(height: 100)
                        .overlay(
                            Text("NO SIGNAL")
                                .font(.system(size: 8, weight: .semibold))
                                .tracking(0.8)
                                .foregroundStyle(.white.opacity(0.6))
                        )
                }

                // Name label
                Text(name.uppercased())
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.5))
                    .padding(6)

                // Status badge when showing a stale frame
                if !hasLiveSnapshot || isOffline {
                    Text(staleBadgeText)
                        .font(.system(size: 7, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.5))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(6)
                }

                // Motion dot
                if hasMotion {
                    Circle()
                        .fill(EditorialTheme.accent)
                        .frame(width: 8, height: 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(8)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: EditorialTheme.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: EditorialTheme.cardRadius)
                    .stroke(EditorialTheme.cardBorder, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .onAppear {
            homeKit.requestSnapshotForTile(cameraIndex: cameraIndex)
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
                homeKit.requestSnapshotForTile(cameraIndex: cameraIndex)
            }
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    private var staleBadgeText: String {
        let time = homeKit.cachedImageDates[name].map {
            $0.formatted(date: .omitted, time: .shortened).uppercased()
        }
        if isOffline {
            return time.map { "OFFLINE · \($0)" } ?? "OFFLINE"
        }
        return time.map { "LAST · \($0)" } ?? "CONNECTING"
    }
}

// MARK: - UIViewRepresentable for HMCameraView

/// Wraps HMCameraView in SwiftUI so the system renders the snapshot natively.
/// This avoids the offscreen-render-to-UIImage approach which always produces
/// black frames because HMCameraView uses a private compositing layer.
private struct HMCameraViewRepresentable: UIViewRepresentable {
    let snapshotControl: HMCameraSnapshotControl?
    /// Changes whenever a new snapshot arrives, forcing SwiftUI to call updateUIView.
    let generation: Int

    func makeUIView(context: Context) -> HMCameraView {
        let view = HMCameraView()
        view.backgroundColor = .black
        view.clipsToBounds = true
        view.contentMode = .scaleAspectFill
        if let snapshot = snapshotControl?.mostRecentSnapshot {
            view.cameraSource = snapshot
        }
        return view
    }

    func updateUIView(_ uiView: HMCameraView, context: Context) {
        if let snapshot = snapshotControl?.mostRecentSnapshot {
            uiView.cameraSource = snapshot
        }
    }
}

// MARK: - Safe Array Subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
