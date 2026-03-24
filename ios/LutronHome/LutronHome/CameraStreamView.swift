import SwiftUI
import HomeKit

/// UIViewRepresentable wrapper for HMCameraView to display live camera streams
struct CameraStreamView: UIViewRepresentable {
    let cameraSource: HMCameraSource?

    func makeUIView(context: Context) -> HMCameraView {
        let view = HMCameraView()
        view.cameraSource = cameraSource
        view.backgroundColor = .black
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        return view
    }

    func updateUIView(_ uiView: HMCameraView, context: Context) {
        if uiView.cameraSource !== cameraSource {
            uiView.cameraSource = cameraSource
        }
    }
}

/// Dashboard card with camera carousel — auto-rotates through all cameras
struct CameraCarouselCard: View {
    var homeKit: HomeKitManager
    @State private var showCameraPicker = false
    @State private var showFullScreen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "video.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Text("Cameras")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                Spacer()

                if homeKit.cameras.count > 1 {
                    // Auto-rotate toggle
                    Button {
                        homeKit.toggleAutoRotate()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: homeKit.autoRotateEnabled ? "autostartstop" : "autostartstop.slash")
                                .font(.system(size: 9))
                            Text("Auto")
                                .font(.system(size: 9, weight: .medium))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(homeKit.autoRotateEnabled ? Color.green.opacity(0.15) : Color(.systemGray5))
                        .foregroundStyle(homeKit.autoRotateEnabled ? .green : .secondary)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Text(homeKit.statusMessage)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            // Camera view
            if let profile = homeKit.currentProfile, profile.streamControl != nil {
                ZStack(alignment: .bottom) {
                    ZStack {
                        // Show cached image as background placeholder while stream loads
                        if let cachedImage = homeKit.cachedImages[homeKit.currentCameraName] {
                            Image(uiImage: cachedImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(height: 200)
                                .clipped()
                                .overlay(
                                    // Dim the cached image slightly to show it's not live
                                    Color.black.opacity(homeKit.isStreaming ? 0 : 0.3)
                                )
                        }

                        CameraStreamView(cameraSource: profile.streamControl?.cameraStream)
                            .frame(height: 200)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color(.separator).opacity(0.3), lineWidth: 1)
                    )
                    .onTapGesture { showFullScreen = true }

                    // Overlay bar: camera name, LIVE indicator, dots
                    HStack {
                        // LIVE badge
                        if homeKit.isStreaming {
                            HStack(spacing: 3) {
                                Circle()
                                    .fill(.red)
                                    .frame(width: 5, height: 5)
                                Text("LIVE")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.red.opacity(0.7), in: Capsule())
                        }

                        Text(homeKit.currentCameraName)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .shadow(radius: 2)

                        Spacer()

                        if homeKit.cameras.count > 1 {
                            // Dot indicators
                            HStack(spacing: 4) {
                                ForEach(0..<homeKit.cameras.count, id: \.self) { i in
                                    Circle()
                                        .fill(i == homeKit.currentCameraIndex ? Color.white : Color.white.opacity(0.4))
                                        .frame(width: 6, height: 6)
                                        .onTapGesture { homeKit.selectCamera(index: i) }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .top, endPoint: .bottom)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    )
                }
            } else if homeKit.currentProfile != nil {
                // Camera found but no stream yet — show cached image or placeholder
                cameraPlaceholder {
                    if let cachedImage = homeKit.cachedImages[homeKit.currentCameraName] {
                        ZStack {
                            Image(uiImage: cachedImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(height: 200)
                                .clipped()
                                .overlay(Color.black.opacity(0.4))
                            VStack(spacing: 6) {
                                ProgressView()
                                    .tint(.white)
                                Text("Connecting to \(homeKit.currentCameraName)...")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                        }
                    } else {
                        ProgressView()
                        Text("Connecting to \(homeKit.currentCameraName)...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onTapGesture { showFullScreen = true }
            } else if homeKit.isReady && homeKit.cameras.isEmpty {
                cameraPlaceholder {
                    Image(systemName: "video.slash")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("No cameras found")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if !homeKit.isReady {
                cameraPlaceholder {
                    ProgressView()
                    Text("Connecting to HomeKit...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Camera selector strip (when multiple)
            if homeKit.cameras.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(0..<homeKit.cameras.count, id: \.self) { i in
                            let cam = homeKit.cameras[i]
                            Button {
                                homeKit.selectCamera(index: i)
                            } label: {
                                HStack(spacing: 4) {
                                    // Show tiny cached thumbnail
                                    if let cached = homeKit.cachedImages[cam.accessory.name] {
                                        Image(uiImage: cached)
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                            .frame(width: 20, height: 20)
                                            .clipShape(RoundedRectangle(cornerRadius: 4))
                                    }
                                    Text(cam.accessory.name)
                                        .font(.system(size: 10, weight: .medium))
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(i == homeKit.currentCameraIndex ? Color.green.opacity(0.2) : Color(.tertiarySystemBackground))
                                .foregroundStyle(i == homeKit.currentCameraIndex ? .green : .secondary)
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule()
                                        .stroke(i == homeKit.currentCameraIndex ? Color.green.opacity(0.3) : Color(.separator).opacity(0.3), lineWidth: 0.5)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showFullScreen) {
            CameraDetailView(homeKit: homeKit)
        }
        .onAppear {
            homeKit.loadAllCachedImages()
        }
    }

    @ViewBuilder
    private func cameraPlaceholder<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.tertiarySystemBackground))
                .frame(height: 200)
            VStack(spacing: 8) {
                content()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Full-Screen Camera Detail

struct CameraDetailView: View {
    var homeKit: HomeKitManager
    @Environment(\.dismiss) var dismiss
    @State private var speakerVolume: Float = 0.5

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // Top bar
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(homeKit.currentCameraName)
                            .font(.headline)
                            .foregroundStyle(.white)
                        // LIVE indicator
                        if homeKit.isStreaming {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(.red)
                                    .frame(width: 6, height: 6)
                                Text("LIVE")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.red)
                            }
                        } else {
                            Text("Offline")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.gray)
                        }
                    }
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .padding()

                Spacer()

                // Stream view — expanded
                if let profile = homeKit.currentProfile, let streamControl = profile.streamControl {
                    ZStack {
                        // Cached image as backdrop
                        if let cachedImage = homeKit.cachedImages[homeKit.currentCameraName] {
                            Image(uiImage: cachedImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity)
                                .frame(height: 300)
                                .opacity(homeKit.isStreaming ? 0 : 1)
                        }

                        CameraStreamView(cameraSource: streamControl.cameraStream)
                            .frame(maxWidth: .infinity)
                            .frame(height: 300)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                } else {
                    // No stream — show cached or placeholder
                    ZStack {
                        if let cachedImage = homeKit.cachedImages[homeKit.currentCameraName] {
                            Image(uiImage: cachedImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity)
                                .frame(height: 300)
                                .overlay(Color.black.opacity(0.3))
                        }
                        VStack(spacing: 12) {
                            Image(systemName: "video.slash")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text("No stream available")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                }

                Spacer()

                // Main controls
                HStack(spacing: 30) {
                    // Snapshot
                    Button {
                        homeKit.requestSnapshot()
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "camera.fill")
                                .font(.title3)
                            Text("Snapshot")
                                .font(.caption2)
                        }
                        .foregroundStyle(.white)
                    }

                    // Talk (two-way audio)
                    if homeKit.hasAudioSupport {
                        Button {
                            homeKit.toggleMicrophone()
                        } label: {
                            VStack(spacing: 4) {
                                ZStack {
                                    Circle()
                                        .fill(homeKit.isMicrophoneActive ? Color.green : Color(.systemGray5))
                                        .frame(width: 50, height: 50)
                                    Image(systemName: homeKit.isMicrophoneActive ? "mic.fill" : "mic")
                                        .font(.title3)
                                        .foregroundStyle(homeKit.isMicrophoneActive ? .white : .white.opacity(0.7))
                                }
                                Text("Talk")
                                    .font(.caption2)
                            }
                            .foregroundStyle(.white)
                        }
                    }

                    // Play/Stop
                    if homeKit.isStreaming {
                        Button {
                            homeKit.stopStream()
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "stop.circle.fill")
                                    .font(.title3)
                                Text("Stop")
                                    .font(.caption2)
                            }
                            .foregroundStyle(.red)
                        }
                    } else {
                        Button {
                            homeKit.startStream()
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "play.circle.fill")
                                    .font(.title3)
                                Text("Play")
                                    .font(.caption2)
                            }
                            .foregroundStyle(.green)
                        }
                    }
                }
                .padding(.bottom, 12)

                // Volume slider (if speaker available)
                if homeKit.currentProfile?.speakerControl != nil {
                    HStack(spacing: 10) {
                        Image(systemName: "speaker.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.6))
                        Slider(value: $speakerVolume, in: 0...1) { editing in
                            if !editing {
                                homeKit.setSpeakerVolume(speakerVolume)
                            }
                        }
                        .tint(.white)
                        Image(systemName: "speaker.wave.3.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .padding(.horizontal, 30)
                    .padding(.bottom, 12)
                }

                // Camera selector
                if homeKit.cameras.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(0..<homeKit.cameras.count, id: \.self) { i in
                                let cam = homeKit.cameras[i]
                                Button {
                                    homeKit.selectCamera(index: i)
                                } label: {
                                    VStack(spacing: 4) {
                                        // Thumbnail from cache
                                        if let cached = homeKit.cachedImages[cam.accessory.name] {
                                            Image(uiImage: cached)
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                                .frame(width: 60, height: 40)
                                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 6)
                                                        .stroke(i == homeKit.currentCameraIndex ? Color.green : Color.clear, lineWidth: 2)
                                                )
                                        } else {
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(Color(.systemGray4))
                                                .frame(width: 60, height: 40)
                                                .overlay(
                                                    Image(systemName: "video.fill")
                                                        .font(.system(size: 12))
                                                        .foregroundStyle(.gray)
                                                )
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 6)
                                                        .stroke(i == homeKit.currentCameraIndex ? Color.green : Color.clear, lineWidth: 2)
                                                )
                                        }
                                        Text(cam.accessory.name)
                                            .font(.system(size: 9, weight: .medium))
                                            .foregroundStyle(i == homeKit.currentCameraIndex ? .green : .white.opacity(0.7))
                                            .lineLimit(1)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                    .padding(.bottom, 30)
                }
            }
        }
    }
}
