import Foundation
import HomeKit
import Observation
import SwiftUI

@Observable
class HomeKitManager: NSObject, @unchecked Sendable {
    var isReady = false
    var statusMessage = "Initializing HomeKit..."
    var snapshotImage: Data?

    // Multi-camera support
    var cameras: [(accessory: HMAccessory, profile: HMCameraProfile)] = []
    var currentCameraIndex: Int = 0
    var autoRotateEnabled = true
    var isStreaming = false

    // Camera health — names of cameras that have failed stream/snapshot enough
    // to be considered offline. The dashboard shows these as a dimmed last-frame
    // tile with an OFFLINE badge. Cleared on foreground and on reachability recovery.
    var unavailableCameras: Set<String> = []
    private var snapshotFailureCounts: [String: Int] = [:]
    private let snapshotFailureThreshold = 2

    // Soft-failure retry (camera sleeping/busy): one pending retry per camera,
    // capped consecutively so the 30s tile refresh stays the long-term probe.
    private var snapshotRetryPending: Set<String> = []
    private var snapshotSoftFailCounts: [String: Int] = [:]
    private let snapshotSoftFailLimit = 3

    // Cached camera images (keyed by camera name)
    var cachedImages: [String: UIImage] = [:]
    // When each cached image was captured — shown on the dashboard's
    // last-frame fallback tile ("OFFLINE · 8:12 AM").
    var cachedImageDates: [String: Date] = [:]

    // Incremented when a snapshot arrives — used to trigger SwiftUI updates
    // for the live HMCameraView tiles on the dashboard.
    var snapshotGeneration: Int = 0

    // Two-way audio support
    var isMicrophoneActive = false

    // Activity detection
    var motionDetectedCameras: Set<String> = []  // camera names with active motion
    var activitySnapshots: [ActivitySnapshot] = []  // today's activity history
    private var lastActivitySnapshotTime: [String: Date] = [:]  // throttle per camera
    private var pendingActivityCapture: (cameraName: String, timestamp: Date)?
    private var motionClearTimers: [String: Timer] = [:]

    // Garage door support
    var garageDoors: [HMAccessory] = []
    var garageDoorStates: [UUID: GarageDoorState] = [:]  // keyed by accessory uniqueIdentifier
    var onGarageDoorOpened: (() -> Void)?

    private var homeManager: HMHomeManager?
    private var rotationTimer: Timer?
    private var retryCount = 0
    private let maxRetries = 1
    private var intentionalStop = false

    // Camera cache directory
    private var cacheDir: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CameraSnapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // Activity snapshots cache directory (separate from live cache)
    private var activityCacheDir: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ActivitySnapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Currently active camera profile
    var currentProfile: HMCameraProfile? {
        guard !cameras.isEmpty, currentCameraIndex < cameras.count else { return nil }
        return cameras[currentCameraIndex].profile
    }

    /// Currently active camera name
    var currentCameraName: String {
        guard !cameras.isEmpty, currentCameraIndex < cameras.count else { return "No camera" }
        return cameras[currentCameraIndex].accessory.name
    }

    func start() {
        guard homeManager == nil else { return }
        let manager = HMHomeManager()
        manager.delegate = self
        homeManager = manager
    }

    // MARK: - Camera Discovery

    func findAllCameras() {
        guard let home = homeManager?.primaryHome ?? homeManager?.homes.first else {
            statusMessage = "No HomeKit home found"
            return
        }

        statusMessage = "Searching \(home.name)..."
        var found: [(accessory: HMAccessory, profile: HMCameraProfile)] = []

        for accessory in home.accessories {
            if let profile = accessory.cameraProfiles?.first {
                found.append((accessory: accessory, profile: profile))
                print("HomeKit: found camera '\(accessory.name)' stream:\(profile.streamControl != nil)")
            }
        }

        cameras = found

        if cameras.isEmpty {
            let names = home.accessories.map { "\($0.name) (cat: \($0.category.categoryType))" }
            print("HomeKit: no cameras found. Accessories: \(names)")
            statusMessage = "No cameras found"
        } else {
            statusMessage = "Found \(cameras.count) camera\(cameras.count == 1 ? "" : "s")"
            currentCameraIndex = 0
            startStream()
            if cameras.count > 1 && autoRotateEnabled {
                startAutoRotation()
            }
            // Subscribe to motion sensors on camera accessories
            subscribeToMotionSensors()
            // Warm the last-frame cache so dashboard tiles can fall back to
            // the most recent image instead of rendering black.
            loadAllCachedImages()
        }
    }

    // MARK: - Garage Door Discovery & Control

    func findGarageDoors() {
        guard let home = homeManager?.primaryHome ?? homeManager?.homes.first else { return }

        garageDoors = home.accessories.filter { accessory in
            accessory.services.contains { $0.serviceType == HMServiceTypeGarageDoorOpener }
        }
        print("HomeKit: found \(garageDoors.count) garage doors")

        // Read initial states, set delegate, enable notifications
        for door in garageDoors {
            door.delegate = self
            refreshGarageDoorState(door)
            enableGarageDoorNotifications(door)
        }
    }

    func refreshGarageDoorState(_ accessory: HMAccessory) {
        guard let service = accessory.services.first(where: { $0.serviceType == HMServiceTypeGarageDoorOpener }) else { return }

        let currentChar = service.characteristics.first { $0.characteristicType == HMCharacteristicTypeCurrentDoorState }
        let targetChar = service.characteristics.first { $0.characteristicType == HMCharacteristicTypeTargetDoorState }
        let obstructionChar = service.characteristics.first { $0.characteristicType == HMCharacteristicTypeObstructionDetected }

        // Read current values
        currentChar?.readValue { [weak self] error in
            guard let self, error == nil else { return }
            self.updateGarageDoorState(accessory)
        }
        targetChar?.readValue { _ in }
        obstructionChar?.readValue { _ in }
    }

    private func updateGarageDoorState(_ accessory: HMAccessory) {
        guard let service = accessory.services.first(where: { $0.serviceType == HMServiceTypeGarageDoorOpener }) else { return }

        let currentVal = service.characteristics.first { $0.characteristicType == HMCharacteristicTypeCurrentDoorState }?.value as? Int ?? -1
        let targetVal = service.characteristics.first { $0.characteristicType == HMCharacteristicTypeTargetDoorState }?.value as? Int ?? -1
        let obstructed = service.characteristics.first { $0.characteristicType == HMCharacteristicTypeObstructionDetected }?.value as? Bool ?? false

        let state = GarageDoorState(
            current: GarageDoorPosition(rawValue: currentVal) ?? .unknown,
            target: GarageDoorPosition(rawValue: targetVal) ?? .unknown,
            obstructionDetected: obstructed
        )

        let previousState = garageDoorStates[accessory.uniqueIdentifier]
        DispatchQueue.main.async {
            self.garageDoorStates[accessory.uniqueIdentifier] = state
        }
        print("HomeKit: garage '\(accessory.name)' state: \(state.current.label)")

        // Trigger lights when door opens (transition from non-open to opening/open)
        let wasOpen = previousState?.current == .open || previousState?.current == .opening
        let isNowOpen = state.current == .open || state.current == .opening
        if !wasOpen && isNowOpen {
            DispatchQueue.main.async { self.onGarageDoorOpened?() }
        }
    }

    private func enableGarageDoorNotifications(_ accessory: HMAccessory) {
        guard let service = accessory.services.first(where: { $0.serviceType == HMServiceTypeGarageDoorOpener }) else { return }

        for char in service.characteristics {
            if char.properties.contains(HMCharacteristicPropertySupportsEventNotification) {
                char.enableNotification(true) { error in
                    if let error {
                        print("HomeKit: notification enable failed for \(char.characteristicType): \(error)")
                    }
                }
            }
        }
    }

    func toggleGarageDoor(_ accessory: HMAccessory) {
        guard let service = accessory.services.first(where: { $0.serviceType == HMServiceTypeGarageDoorOpener }),
              let targetChar = service.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypeTargetDoorState }) else {
            return
        }
        let currentState = garageDoorStates[accessory.uniqueIdentifier]?.current ?? .closed
        let newValue = currentState == .open ? 1 : 0  // 0=Open, 1=Closed
        targetChar.writeValue(newValue) { [weak self] error in
            if let error {
                print("HomeKit: garage door toggle error — \(error)")
            } else {
                // Refresh state after toggle
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self?.refreshGarageDoorState(accessory)
                }
            }
        }
    }

    // MARK: - Camera Selection & Rotation

    func selectCamera(index: Int) {
        guard index >= 0, index < cameras.count, index != currentCameraIndex else { return }
        stopStream()
        currentCameraIndex = index
        retryCount = 0
        startStream()
    }

    func toggleAutoRotate() {
        autoRotateEnabled.toggle()
        if autoRotateEnabled && cameras.count > 1 {
            startAutoRotation()
        } else {
            stopAutoRotation()
        }
    }

    private func startAutoRotation() {
        stopAutoRotation()
        rotationTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.rotateToNextCamera()
        }
    }

    private func stopAutoRotation() {
        rotationTimer?.invalidate()
        rotationTimer = nil
    }

    private func rotateToNextCamera() {
        guard cameras.count > 1 else { return }
        let next = (currentCameraIndex + 1) % cameras.count
        selectCamera(index: next)
    }

    // MARK: - Snapshot

    func requestSnapshot() {
        guard let snapshotControl = currentProfile?.snapshotControl else {
            print("HomeKit: no snapshot control available")
            return
        }
        snapshotControl.delegate = self
        snapshotControl.takeSnapshot()
    }

    /// Request a snapshot for a specific camera by index (used by dashboard tiles).
    func requestSnapshotForTile(cameraIndex: Int) {
        guard cameraIndex < cameras.count else { return }
        let profile = cameras[cameraIndex].profile
        guard let snapshotControl = profile.snapshotControl else { return }
        snapshotControl.delegate = self
        snapshotControl.takeSnapshot()
    }

    // MARK: - Stream Control

    func startStream() {
        guard !isStreaming else { return }
        guard let streamControl = currentProfile?.streamControl else {
            print("HomeKit: no stream control for \(currentCameraName)")
            statusMessage = "\(currentCameraName): no stream"
            return
        }
        intentionalStop = false
        streamControl.delegate = self
        streamControl.startStream()
        statusMessage = "\(currentCameraName): starting..."
    }

    func stopStream() {
        intentionalStop = true
        isStreaming = false
        currentProfile?.streamControl?.stopStream()
    }

    /// Called on background/foreground transitions
    func handleScenePhase(active: Bool) {
        if active {
            if !cameras.isEmpty {
                retryCount = 0
                // Re-check previously-failed cameras on foreground — they may be back.
                unavailableCameras.removeAll()
                snapshotFailureCounts.removeAll()
                startStream()
                if cameras.count > 1 && autoRotateEnabled {
                    startAutoRotation()
                }
            }
        } else {
            stopAutoRotation()
            stopStream()
        }
    }

    // MARK: - Camera Health

    /// Mark a camera offline so the dashboard hides it and stops requesting from it.
    private func markCameraUnavailable(_ name: String) {
        if unavailableCameras.insert(name).inserted {
            print("HomeKit: camera '\(name)' marked unavailable — hiding tile")
        }
    }

    /// Mark a camera reachable again after a successful stream/snapshot.
    private func markCameraAvailable(_ name: String) {
        snapshotFailureCounts[name] = 0
        snapshotSoftFailCounts[name] = 0
        if unavailableCameras.remove(name) != nil {
            print("HomeKit: camera '\(name)' available again")
        }
    }

    /// Retry a soft-failed snapshot (camera sleeping/busy) after a short delay
    /// instead of leaving the tile stale until the next 30s refresh cycle.
    private func scheduleSnapshotRetry(for name: String) {
        guard !snapshotRetryPending.contains(name),
              snapshotSoftFailCounts[name, default: 0] < snapshotSoftFailLimit else { return }
        snapshotSoftFailCounts[name, default: 0] += 1
        snapshotRetryPending.insert(name)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            self.snapshotRetryPending.remove(name)
            guard let entry = self.cameras.first(where: { $0.accessory.name == name }),
                  let control = entry.profile.snapshotControl else { return }
            control.delegate = self
            control.takeSnapshot()
        }
    }

    // MARK: - Auto-Retry with Backoff

    private func retryStream() {
        guard retryCount < maxRetries else {
            statusMessage = "\(currentCameraName): unavailable"
            print("HomeKit: retries exhausted for \(currentCameraName) — marking unavailable")
            markCameraUnavailable(currentCameraName)
            retryCount = 0
            return
        }
        retryCount += 1
        let delay = pow(2.0, Double(retryCount)) // 2s, 4s, 8s
        if retryCount == 1 {
            print("HomeKit: retrying stream in \(delay)s (attempt \(retryCount)/\(maxRetries))")
        }
        statusMessage = "\(currentCameraName): retrying..."

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.intentionalStop else { return }
            self.isStreaming = false
            self.startStream()
        }
    }

    // MARK: - Two-Way Audio

    /// Whether the current camera supports audio (speaker)
    var hasAudioSupport: Bool {
        currentProfile?.microphoneControl != nil || currentProfile?.speakerControl != nil
    }

    /// Toggle the microphone for two-way talk
    func toggleMicrophone() {
        guard let micControl = currentProfile?.microphoneControl else {
            print("HomeKit: no microphone control available for \(currentCameraName)")
            return
        }

        let newMuted = !isMicrophoneActive
        // microphoneControl.mute characteristic
        if let muteChar = micControl.mute {
            muteChar.writeValue(!newMuted) { [weak self] error in
                if let error {
                    print("HomeKit: mic toggle error — \(error)")
                } else {
                    DispatchQueue.main.async {
                        self?.isMicrophoneActive = newMuted
                    }
                }
            }
        }
    }

    /// Set speaker volume (0.0 - 1.0)
    func setSpeakerVolume(_ volume: Float) {
        guard let speakerControl = currentProfile?.speakerControl,
              let volumeChar = speakerControl.volume else { return }
        let intVolume = Int(volume * 100)
        volumeChar.writeValue(intVolume) { error in
            if let error { print("HomeKit: volume error — \(error)") }
        }
    }

    // MARK: - Camera Image Caching

    /// Save a UIImage to disk cache for a camera name
    func cacheImage(_ image: UIImage, for cameraName: String) {
        let safeName = cameraName.replacingOccurrences(of: "/", with: "_")
        let url = cacheDir.appendingPathComponent("\(safeName).jpg")
        if let data = image.jpegData(compressionQuality: 0.8) {
            try? data.write(to: url)
        }
        cachedImages[cameraName] = image
        cachedImageDates[cameraName] = Date()
    }

    /// Load cached image for a camera name
    func loadCachedImage(for cameraName: String) -> UIImage? {
        if let cached = cachedImages[cameraName] { return cached }
        let safeName = cameraName.replacingOccurrences(of: "/", with: "_")
        let url = cacheDir.appendingPathComponent("\(safeName).jpg")
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { return nil }
        cachedImages[cameraName] = image
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let modified = attrs[.modificationDate] as? Date {
            cachedImageDates[cameraName] = modified
        }
        return image
    }

    /// Load all cached images on startup
    func loadAllCachedImages() {
        for cam in cameras {
            _ = loadCachedImage(for: cam.accessory.name)
        }
    }

    /// Capture current stream frame as a cached image via snapshot
    func captureAndCacheSnapshot() {
        guard let snapshotControl = currentProfile?.snapshotControl else { return }
        snapshotControl.delegate = self
        snapshotControl.takeSnapshot()
    }

    // MARK: - Motion Sensor Subscription

    private func subscribeToMotionSensors() {
        for (accessory, _) in cameras {
            accessory.delegate = self
            var foundMotion = false
            for service in accessory.services where service.serviceType == HMServiceTypeMotionSensor {
                for char in service.characteristics where char.characteristicType == HMCharacteristicTypeMotionDetected {
                    foundMotion = true
                    char.enableNotification(true) { error in
                        if let error {
                            print("HomeKit: motion notification failed for \(accessory.name): \(error)")
                        } else {
                            print("HomeKit: subscribed to motion for \(accessory.name)")
                        }
                    }
                    char.readValue { _ in }
                }
            }
            if !foundMotion {
                print("HomeKit: no motion sensor on \(accessory.name)")
            }
        }
    }

    // MARK: - Activity Snapshot Capture

    private func captureActivitySnapshot(for entry: (accessory: HMAccessory, profile: HMCameraProfile)) {
        let cameraName = entry.accessory.name
        let now = Date()

        // Throttle: skip if last snapshot for this camera was < 30 seconds ago
        if let lastTime = lastActivitySnapshotTime[cameraName], now.timeIntervalSince(lastTime) < 30 {
            print("HomeKit: throttling activity snapshot for \(cameraName)")
            return
        }
        lastActivitySnapshotTime[cameraName] = now

        // Mark motion detected (UI indicator)
        DispatchQueue.main.async { [weak self] in
            self?.motionDetectedCameras.insert(cameraName)
            // Clear motion indicator after 10 seconds
            self?.motionClearTimers[cameraName]?.invalidate()
            self?.motionClearTimers[cameraName] = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { _ in
                DispatchQueue.main.async {
                    self?.motionDetectedCameras.remove(cameraName)
                }
            }
        }

        // Set pending flag so snapshot callback routes to activity storage
        pendingActivityCapture = (cameraName: cameraName, timestamp: now)

        // Take snapshot from this camera's snapshot control
        guard let snapshotControl = entry.profile.snapshotControl else {
            print("HomeKit: no snapshot control for activity capture on \(cameraName)")
            pendingActivityCapture = nil
            return
        }
        snapshotControl.delegate = self
        snapshotControl.takeSnapshot()
        print("HomeKit: capturing activity snapshot for \(cameraName)")
    }

    /// Save an activity snapshot image to disk and add to in-memory array
    private func saveActivitySnapshot(_ image: UIImage, cameraName: String, timestamp: Date) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let safeName = cameraName.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: " ", with: "_")
        let filename = "\(safeName)_\(formatter.string(from: timestamp)).jpg"
        let url = activityCacheDir.appendingPathComponent(filename)

        if let data = image.jpegData(compressionQuality: 0.7) {
            try? data.write(to: url)
        }

        let snapshot = ActivitySnapshot(cameraName: cameraName, timestamp: timestamp, image: image)
        DispatchQueue.main.async { [weak self] in
            self?.activitySnapshots.insert(snapshot, at: 0)  // newest first
            print("HomeKit: saved activity snapshot for \(cameraName) — total: \(self?.activitySnapshots.count ?? 0)")
        }
    }

    // MARK: - Activity Snapshot Persistence

    /// Load today's activity snapshots from disk
    func loadTodayActivitySnapshots() {
        let fm = FileManager.default
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        guard let files = try? fm.contentsOfDirectory(at: activityCacheDir, includingPropertiesForKeys: [.creationDateKey]) else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"

        var loaded: [ActivitySnapshot] = []
        for file in files where file.pathExtension == "jpg" {
            let name = file.deletingPathExtension().lastPathComponent
            // Parse: CameraName_2026-03-28_143022
            // Find the date portion (last 17 chars: yyyy-MM-dd_HHmmss)
            guard name.count > 17 else { continue }
            let dateString = String(name.suffix(17))
            let cameraName = String(name.dropLast(18)).replacingOccurrences(of: "_", with: " ")

            guard let timestamp = formatter.date(from: dateString),
                  timestamp >= today,
                  let data = try? Data(contentsOf: file),
                  let image = UIImage(data: data) else { continue }

            loaded.append(ActivitySnapshot(cameraName: cameraName, timestamp: timestamp, image: image))
        }

        loaded.sort { $0.timestamp > $1.timestamp }
        DispatchQueue.main.async { [weak self] in
            self?.activitySnapshots = loaded
            print("HomeKit: loaded \(loaded.count) activity snapshots from today")
        }
    }

    /// Delete activity snapshots older than 24 hours
    func cleanupOldActivitySnapshots() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)

        guard let files = try? fm.contentsOfDirectory(at: activityCacheDir, includingPropertiesForKeys: [.creationDateKey]) else { return }

        var removed = 0
        for file in files {
            if let attrs = try? fm.attributesOfItem(atPath: file.path),
               let created = attrs[.creationDate] as? Date,
               created < cutoff {
                try? fm.removeItem(at: file)
                removed += 1
            }
        }
        if removed > 0 {
            print("HomeKit: cleaned up \(removed) old activity snapshots")
        }
    }
}

// MARK: - ActivitySnapshot Model

struct ActivitySnapshot: Identifiable {
    let id = UUID()
    let cameraName: String
    let timestamp: Date
    let image: UIImage
}

// MARK: - HMHomeManagerDelegate

extension HomeKitManager: HMHomeManagerDelegate {
    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        isReady = true
        let homeCount = manager.homes.count
        let primary = manager.primaryHome?.name ?? "none"
        print("HomeKit: ready — \(homeCount) homes, primary: \(primary)")
        statusMessage = "HomeKit ready (\(homeCount) homes)"
        findAllCameras()
        findGarageDoors()
    }
}

// MARK: - HMCameraStreamControlDelegate

extension HomeKitManager: HMCameraStreamControlDelegate {
    func cameraStreamControlDidStartStream(_ cameraStreamControl: HMCameraStreamControl) {
        isStreaming = true
        retryCount = 0
        markCameraAvailable(currentCameraName)
        statusMessage = currentCameraName
        print("HomeKit: stream started for \(currentCameraName)")
        // Capture a snapshot for cache after stream stabilizes
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.captureAndCacheSnapshot()
        }
    }

    func cameraStreamControl(_ cameraStreamControl: HMCameraStreamControl, didStopStreamWithError error: (any Error)?) {
        isStreaming = false
        if let error {
            let nsError = error as NSError

            if intentionalStop {
                statusMessage = "Stream stopped"
                return
            }

            // Codes 23 (stream busy) and 52 (timed out) are transient — retry silently
            if nsError.domain == "HMErrorDomain" && (nsError.code == 23 || nsError.code == 52) {
                retryStream()
            } else {
                print("HomeKit: stream error — code \(nsError.code): \(error)")
                statusMessage = "\(currentCameraName): error \(nsError.code)"
                retryStream()
            }
        } else {
            if !intentionalStop {
                statusMessage = "\(currentCameraName): stopped"
            } else {
                statusMessage = "Stream stopped"
            }
            print("HomeKit: stream stopped")
        }
    }
}

// MARK: - HMCameraSnapshotControlDelegate

extension HomeKitManager: HMCameraSnapshotControlDelegate {
    func cameraSnapshotControl(_ cameraSnapshotControl: HMCameraSnapshotControl, didTake snapshot: HMCameraSnapshot?, error: (any Error)?) {
        if let error {
            let nsError = error as NSError
            let name = cameraNameForControl(cameraSnapshotControl)
            // Code 4 = HMErrorCodeNotFound, Code 100 = snapshot unavailable — camera
            // sleeping/busy. Retry shortly rather than waiting out the 30s cycle.
            if nsError.domain == "HMErrorDomain" && (nsError.code == 4 || nsError.code == 100) {
                scheduleSnapshotRetry(for: name)
                return
            }
            // Hard failures (e.g. code 54 timeout): count toward marking the camera
            // offline so the dashboard shows its last-frame fallback.
            snapshotFailureCounts[name, default: 0] += 1
            if snapshotFailureCounts[name, default: 0] >= snapshotFailureThreshold {
                markCameraUnavailable(name)
            }
            print("HomeKit: snapshot error for \(name) — \(error)")
            statusMessage = "Snapshot failed"
            return
        }
        if snapshot != nil {
            let name = cameraNameForControl(cameraSnapshotControl)
            markCameraAvailable(name)
            print("HomeKit: snapshot taken for \(name)")
            statusMessage = "Snapshot captured"
            snapshotGeneration += 1
            if let mostRecent = cameraSnapshotControl.mostRecentSnapshot {
                renderAndCacheSnapshot(mostRecent, cameraName: name)
            }
        }
    }

    func cameraSnapshotControlDidUpdateMostRecentSnapshot(_ cameraSnapshotControl: HMCameraSnapshotControl) {
        let name = cameraNameForControl(cameraSnapshotControl)
        print("HomeKit: most recent snapshot updated for \(name)")
        if let mostRecent = cameraSnapshotControl.mostRecentSnapshot {
            renderAndCacheSnapshot(mostRecent, cameraName: name)
        }
    }

    /// Resolve which camera a snapshot control belongs to by identity.
    private func cameraNameForControl(_ control: HMCameraSnapshotControl) -> String {
        for (accessory, profile) in cameras {
            if profile.snapshotControl === control {
                return accessory.name
            }
        }
        return currentCameraName
    }

    /// Render a snapshot via HMCameraView and cache the result.
    /// Uses `layer.render(in:)` instead of `drawHierarchy` because the view
    /// is hidden and `drawHierarchy` skips hidden views.
    private func renderAndCacheSnapshot(_ snapshot: HMCameraSnapshot, cameraName: String) {
        // Capture pending activity state before async
        let activityCapture = pendingActivityCapture
        pendingActivityCapture = nil

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let cameraView = HMCameraView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            cameraView.cameraSource = snapshot
            cameraView.isHidden = true

            // Attach to key window so the CALayer gets a backing
            let window = UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .first
            window?.addSubview(cameraView)
            cameraView.layoutIfNeeded()

            // Give the view a moment to load the snapshot source
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                let renderer = UIGraphicsImageRenderer(bounds: cameraView.bounds)
                let image = renderer.image { ctx in
                    cameraView.layer.render(in: ctx.cgContext)
                }
                cameraView.removeFromSuperview()

                // Only process if image has actual content (not all black)
                guard let data = image.pngData(), data.count > 1000 else { return }

                if let activity = activityCapture {
                    // Route to activity snapshot storage
                    self.saveActivitySnapshot(image, cameraName: activity.cameraName, timestamp: activity.timestamp)
                } else {
                    // Normal live snapshot caching
                    self.cacheImage(image, for: cameraName)
                    self.snapshotImage = image.jpegData(compressionQuality: 0.8)
                    print("HomeKit: cached snapshot for \(cameraName)")
                }
            }
        }
    }

}

// MARK: - HMAccessoryDelegate (garage door state changes)

extension HomeKitManager: HMAccessoryDelegate {
    /// Camera recovery: the instant a dropped camera comes back, clear its
    /// offline mark and pull a fresh snapshot instead of waiting for a timer.
    func accessoryDidUpdateReachability(_ accessory: HMAccessory) {
        guard let entry = cameras.first(where: { $0.accessory.uniqueIdentifier == accessory.uniqueIdentifier }) else { return }
        let name = entry.accessory.name
        if accessory.isReachable {
            print("HomeKit: camera '\(name)' reachable — refreshing snapshot")
            markCameraAvailable(name)
            if let control = entry.profile.snapshotControl {
                control.delegate = self
                control.takeSnapshot()
            }
        } else {
            print("HomeKit: camera '\(name)' unreachable — tile falls back to last frame")
        }
    }

    func accessory(_ accessory: HMAccessory, service: HMService, didUpdateValueFor characteristic: HMCharacteristic) {
        // Update garage door state when characteristics change
        if service.serviceType == HMServiceTypeGarageDoorOpener {
            updateGarageDoorState(accessory)
        }

        // Handle motion detection on camera accessories
        if service.serviceType == HMServiceTypeMotionSensor,
           characteristic.characteristicType == HMCharacteristicTypeMotionDetected,
           let motionDetected = characteristic.value as? Bool, motionDetected {
            print("HomeKit: motion detected on \(accessory.name)")
            if let cameraEntry = cameras.first(where: { $0.accessory.uniqueIdentifier == accessory.uniqueIdentifier }) {
                captureActivitySnapshot(for: cameraEntry)
            }
        }
    }
}

// MARK: - Garage Door State Model

enum GarageDoorPosition: Int {
    case open = 0
    case closed = 1
    case opening = 2
    case closing = 3
    case stopped = 4
    case unknown = -1

    var label: String {
        switch self {
        case .open: return "Open"
        case .closed: return "Closed"
        case .opening: return "Opening"
        case .closing: return "Closing"
        case .stopped: return "Stopped"
        case .unknown: return "Unknown"
        }
    }

    var icon: String {
        switch self {
        case .open: return "door.garage.open"
        case .closed: return "door.garage.closed"
        case .opening, .closing: return "door.garage.double.bay.open"
        case .stopped: return "exclamationmark.triangle"
        case .unknown: return "questionmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .open: return .orange
        case .closed: return .green
        case .opening, .closing: return .blue
        case .stopped: return .red
        case .unknown: return .gray
        }
    }
}

struct GarageDoorState {
    let current: GarageDoorPosition
    let target: GarageDoorPosition
    let obstructionDetected: Bool
}
