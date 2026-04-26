import SwiftUI
import HomeKit

struct EditorialCameraSection: View {
    @Environment(HomeKitManager.self) var homeKit
    @State private var showDetail = false

    var body: some View {
        if !homeKit.cameras.isEmpty {
            VStack(alignment: .leading, spacing: EditorialTheme.gridSpacing) {
                EditorialSectionHeader(
                    title: "CAMERAS",
                    trailing: "\(homeKit.cameras.count) FEEDS"
                )

                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: EditorialTheme.gridSpacing
                ) {
                    ForEach(Array(homeKit.cameras.enumerated()), id: \.offset) { index, camera in
                        LiveCameraTile(
                            cameraIndex: index,
                            name: camera.accessory.name,
                            hasMotion: homeKit.motionDetectedCameras.contains(camera.accessory.name)
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
    let onTap: () -> Void

    @State private var refreshTimer: Timer?

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottomLeading) {
                // Live HMCameraView rendering the snapshot
                HMCameraViewRepresentable(
                    snapshotControl: homeKit.cameras[safe: cameraIndex]?.profile.snapshotControl,
                    generation: homeKit.snapshotGeneration
                )
                .frame(height: 100)
                .clipped()

                // Name label
                Text(name.uppercased())
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.5))
                    .padding(6)

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
