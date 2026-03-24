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

    // Cached camera images (keyed by camera name)
    var cachedImages: [String: UIImage] = [:]

    // Two-way audio support
    var isMicrophoneActive = false

    // Garage door support
    var garageDoors: [HMAccessory] = []
    var garageDoorStates: [UUID: GarageDoorState] = [:]  // keyed by accessory uniqueIdentifier

    private var homeManager: HMHomeManager?
    private var rotationTimer: Timer?
    private var retryCount = 0
    private let maxRetries = 3
    private var intentionalStop = false

    // Camera cache directory
    private var cacheDir: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CameraSnapshots", isDirectory: true)
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

        DispatchQueue.main.async {
            self.garageDoorStates[accessory.uniqueIdentifier] = state
        }
        print("HomeKit: garage '\(accessory.name)' state: \(state.current.label)")
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

    // MARK: - Auto-Retry with Backoff

    private func retryStream() {
        guard retryCount < maxRetries else {
            statusMessage = "\(currentCameraName): stream failed"
            print("HomeKit: max retries reached for \(currentCameraName)")
            retryCount = 0
            return
        }
        retryCount += 1
        let delay = pow(2.0, Double(retryCount)) // 2s, 4s, 8s
        print("HomeKit: retrying stream in \(delay)s (attempt \(retryCount)/\(maxRetries))")
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
    }

    /// Load cached image for a camera name
    func loadCachedImage(for cameraName: String) -> UIImage? {
        if let cached = cachedImages[cameraName] { return cached }
        let safeName = cameraName.replacingOccurrences(of: "/", with: "_")
        let url = cacheDir.appendingPathComponent("\(safeName).jpg")
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { return nil }
        cachedImages[cameraName] = image
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
            print("HomeKit: stream error — code \(nsError.code): \(error)")

            if intentionalStop {
                statusMessage = "Stream stopped"
                return
            }

            // Error 52 = operationTimedOut — auto-retry
            if nsError.domain == "HMErrorDomain" && nsError.code == 52 {
                statusMessage = "\(currentCameraName): timed out"
                retryStream()
            } else {
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
            print("HomeKit: snapshot error — \(error)")
            statusMessage = "Snapshot failed"
            return
        }
        if snapshot != nil {
            print("HomeKit: snapshot taken")
            statusMessage = "Snapshot captured"
            // The mostRecentSnapshot gives us the HMCameraSource to render
            if let mostRecent = cameraSnapshotControl.mostRecentSnapshot {
                renderAndCacheSnapshot(mostRecent)
            }
        }
    }

    func cameraSnapshotControlDidUpdateMostRecentSnapshot(_ cameraSnapshotControl: HMCameraSnapshotControl) {
        print("HomeKit: most recent snapshot updated")
        if let mostRecent = cameraSnapshotControl.mostRecentSnapshot {
            renderAndCacheSnapshot(mostRecent)
        }
    }

    /// Render a snapshot via HMCameraView and cache the result
    private func renderAndCacheSnapshot(_ snapshot: HMCameraSnapshot) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let cameraView = HMCameraView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            cameraView.cameraSource = snapshot
            // Give the view a moment to render, then capture
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let renderer = UIGraphicsImageRenderer(bounds: cameraView.bounds)
                let image = renderer.image { _ in
                    cameraView.drawHierarchy(in: cameraView.bounds, afterScreenUpdates: true)
                }
                // Only cache if image has actual content (not all black)
                if let data = image.pngData(), data.count > 1000 {
                    self.cacheImage(image, for: self.currentCameraName)
                    self.snapshotImage = image.jpegData(compressionQuality: 0.8)
                    print("HomeKit: cached snapshot for \(self.currentCameraName)")
                }
            }
        }
    }
}

// MARK: - HMAccessoryDelegate (garage door state changes)

extension HomeKitManager: HMAccessoryDelegate {
    func accessory(_ accessory: HMAccessory, service: HMService, didUpdateValueFor characteristic: HMCharacteristic) {
        // Update garage door state when characteristics change
        if service.serviceType == HMServiceTypeGarageDoorOpener {
            updateGarageDoorState(accessory)
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
