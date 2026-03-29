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
    @State private var showActivityTimeline = false

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

                // Activity count badge
                if !homeKit.activitySnapshots.isEmpty {
                    Button {
                        showActivityTimeline = true
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "figure.walk.motion")
                                .font(.system(size: 9))
                            Text("\(homeKit.activitySnapshots.count)")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.orange.opacity(0.15))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

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

                    // Overlay bar: camera name, LIVE indicator, motion, dots
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

                        // Motion detected indicator
                        if homeKit.motionDetectedCameras.contains(homeKit.currentCameraName) {
                            HStack(spacing: 3) {
                                Image(systemName: "figure.walk.motion")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.orange.opacity(0.7), in: Capsule())
                            .transition(.opacity)
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
        .sheet(isPresented: $showActivityTimeline) {
            ActivityTimelineView(homeKit: homeKit)
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
    @State private var showActivityTimeline = false

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

                    // Activity Timeline
                    Button {
                        showActivityTimeline = true
                    } label: {
                        VStack(spacing: 4) {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.title3)
                                if !homeKit.activitySnapshots.isEmpty {
                                    Text("\(homeKit.activitySnapshots.count)")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 3)
                                        .background(.orange, in: Capsule())
                                        .offset(x: 8, y: -4)
                                }
                            }
                            Text("Activity")
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
        .sheet(isPresented: $showActivityTimeline) {
            ActivityTimelineView(homeKit: homeKit)
        }
    }
}

// MARK: - Activity Timeline View

struct ActivityTimelineView: View {
    var homeKit: HomeKitManager
    @Environment(\.dismiss) var dismiss
    @State private var selectedCamera: String? = nil  // nil = all cameras
    @State private var selectedSnapshot: ActivitySnapshot? = nil

    private var cameraNames: [String] {
        Array(Set(homeKit.activitySnapshots.map(\.cameraName))).sorted()
    }

    private var filteredSnapshots: [ActivitySnapshot] {
        if let camera = selectedCamera {
            return homeKit.activitySnapshots.filter { $0.cameraName == camera }
        }
        return homeKit.activitySnapshots
    }

    private var groupedByHour: [(hour: String, snapshots: [ActivitySnapshot])] {
        let formatter = DateFormatter()
        formatter.dateFormat = "h a"

        var groups: [String: [ActivitySnapshot]] = [:]
        var hourOrder: [String] = []

        for snapshot in filteredSnapshots {
            let key = formatter.string(from: snapshot.timestamp)
            if groups[key] == nil {
                hourOrder.append(key)
            }
            groups[key, default: []].append(snapshot)
        }

        return hourOrder.map { (hour: $0, snapshots: groups[$0]!) }
    }

    var body: some View {
        NavigationView {
            Group {
                if homeKit.activitySnapshots.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 0) {
                        // Camera filter pills
                        if cameraNames.count > 1 {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    filterPill(title: "All", isSelected: selectedCamera == nil) {
                                        selectedCamera = nil
                                    }
                                    ForEach(cameraNames, id: \.self) { name in
                                        filterPill(title: name, isSelected: selectedCamera == name) {
                                            selectedCamera = name
                                        }
                                    }
                                }
                                .padding(.horizontal)
                                .padding(.vertical, 10)
                            }
                        }

                        // Timeline
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 16) {
                                ForEach(groupedByHour, id: \.hour) { group in
                                    VStack(alignment: .leading, spacing: 8) {
                                        // Hour header
                                        Text(group.hour)
                                            .font(.subheadline)
                                            .fontWeight(.semibold)
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal)

                                        // Snapshot grid
                                        LazyVGrid(columns: [
                                            GridItem(.flexible(), spacing: 8),
                                            GridItem(.flexible(), spacing: 8),
                                            GridItem(.flexible(), spacing: 8)
                                        ], spacing: 8) {
                                            ForEach(group.snapshots) { snapshot in
                                                activityThumbnail(snapshot)
                                            }
                                        }
                                        .padding(.horizontal)
                                    }
                                }
                            }
                            .padding(.vertical)
                        }
                    }
                }
            }
            .navigationTitle("Today's Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    if !homeKit.activitySnapshots.isEmpty {
                        Text("\(filteredSnapshots.count) events")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .sheet(item: $selectedSnapshot) { snapshot in
                activityDetail(snapshot)
            }
        }
    }

    // MARK: - Subviews

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "figure.walk.motion")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No Activity Detected Today")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Screenshots will appear here when motion is detected by your cameras.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    private func filterPill(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.orange.opacity(0.2) : Color(.tertiarySystemBackground))
                .foregroundStyle(isSelected ? .orange : .secondary)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(isSelected ? Color.orange.opacity(0.3) : Color(.separator).opacity(0.3), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    private func activityThumbnail(_ snapshot: ActivitySnapshot) -> some View {
        Button {
            selectedSnapshot = snapshot
        } label: {
            VStack(spacing: 4) {
                Image(uiImage: snapshot.image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 80)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack(spacing: 2) {
                    if selectedCamera == nil {
                        Text(snapshot.cameraName)
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(snapshot.timestamp, format: .dateTime.hour().minute())
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func activityDetail(_ snapshot: ActivitySnapshot) -> some View {
        NavigationView {
            VStack(spacing: 16) {
                Image(uiImage: snapshot.image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)

                VStack(spacing: 6) {
                    Text(snapshot.cameraName)
                        .font(.headline)
                    Text(snapshot.timestamp, format: .dateTime.hour().minute().second())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(snapshot.timestamp, format: .dateTime.weekday(.wide).month().day())
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer()
            }
            .padding(.top, 20)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { selectedSnapshot = nil }
                }
            }
        }
    }
}
