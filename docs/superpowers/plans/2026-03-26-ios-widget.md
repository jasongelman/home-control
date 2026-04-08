# iOS Widget + Voice Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add WidgetKit widgets (small + medium) with contextual recommended actions, an "All Off" button, appliance status, voice input, and Siri integration to the Lutron Home iOS app.

**Architecture:** App Intents unify widget actions and Siri. The main app writes device state, usage events, scenes, and appliance status to a shared App Group container. The widget's `TimelineProvider` reads this data and runs a recommendation engine. Intents call the Node.js server's REST API to execute commands. Speech recognition uses `SFSpeechRecognizer` with Claude API fallback for ambiguous input.

**Tech Stack:** WidgetKit, App Intents, App Groups, SFSpeechRecognizer, Anthropic Claude API

**Spec:** `docs/superpowers/specs/2026-03-26-ios-widget-design.md`

---

## File Structure

### New Files

| File | Responsibility |
|------|----------------|
| `ios/LutronHome/LutronHome/AppGroupManager.swift` | Read/write shared App Group container (devices, scenes, usage, appliances, server host) |
| `ios/LutronHome/LutronHome/RecommendationEngine.swift` | Pure function: usage events + device state + time → ranked `SuggestedAction` list |
| `ios/LutronHome/LutronHome/SuggestedAction.swift` | Model for widget recommended actions |
| `ios/LutronHome/LutronHome/ServerAPIClient.swift` | HTTP client for calling server REST endpoints from intents/widget |
| `ios/LutronHome/LutronHome/Intents/ActivateSceneIntent.swift` | AppIntent: activate a scene by ID via server API |
| `ios/LutronHome/LutronHome/Intents/SetDeviceLevelIntent.swift` | AppIntent: set device level via server API |
| `ios/LutronHome/LutronHome/Intents/AllLightsOffIntent.swift` | AppIntent: turn off all lights except Sebastian's Room via server API |
| `ios/LutronHome/LutronHome/Intents/VoiceCommandIntent.swift` | AppIntent: route free-form text to Claude API for interpretation and execution |
| `ios/LutronHome/LutronHome/Intents/LutronShortcutsProvider.swift` | `AppShortcutsProvider` registering Siri phrases |
| `ios/LutronHome/LutronHomeWidget/LutronHomeWidget.swift` | Widget entry point, `WidgetBundle`, timeline entry model |
| `ios/LutronHome/LutronHomeWidget/WidgetTimelineProvider.swift` | `TimelineProvider` reading App Group data, producing entries |
| `ios/LutronHome/LutronHomeWidget/SmallWidgetView.swift` | Small (2×2) widget SwiftUI view |
| `ios/LutronHome/LutronHomeWidget/MediumWidgetView.swift` | Medium (4×2) widget SwiftUI view |
| `ios/LutronHome/LutronHomeWidget/Info.plist` | Widget extension configuration |
| `ios/LutronHome/LutronHomeWidget/LutronHomeWidget.entitlements` | App Group entitlement for widget |
| `ios/LutronHome/LutronHomeTests/RecommendationEngineTests.swift` | Tests for recommendation engine |
| `ios/LutronHome/LutronHomeTests/AppGroupManagerTests.swift` | Tests for App Group serialization |

### Modified Files

| File | Changes |
|------|---------|
| `ios/LutronHome/LutronHome/LutronHome.entitlements` | Add `com.apple.security.application-groups` |
| `ios/LutronHome/LutronHome/LutronStore.swift` | Write to App Group on state changes, call `WidgetCenter.shared.reloadAllTimelines()` |
| `ios/LutronHome/LutronHome/UsageTracker.swift` | Dual-write events to App Group in addition to local UserDefaults |
| `ios/LutronHome/LutronHome/LutronHomeApp.swift` | Register `AppShortcutsProvider` |
| `ios/LutronHome/LutronHome.xcodeproj/project.pbxproj` | Add widget extension target, file references, App Group capability |

---

## Task 1: App Group Manager + Shared Models

**Files:**
- Create: `ios/LutronHome/LutronHome/SuggestedAction.swift`
- Create: `ios/LutronHome/LutronHome/AppGroupManager.swift`
- Create: `ios/LutronHome/LutronHomeTests/AppGroupManagerTests.swift`

- [ ] **Step 1: Create `SuggestedAction` model**

```swift
// ios/LutronHome/LutronHome/SuggestedAction.swift
import Foundation

struct SuggestedAction: Codable, Identifiable {
    enum ActionType: String, Codable {
        case device
        case scene
    }

    let type: ActionType
    let id: String          // device integrationId (as string) or scene ID
    let label: String       // display name
    let subtitle: String    // e.g. "5 devices", "Set to 80%", "Turn off"
    let level: Double?      // target level for device actions (nil for scenes)
}
```

- [ ] **Step 2: Create `AppGroupManager`**

```swift
// ios/LutronHome/LutronHome/AppGroupManager.swift
import Foundation
import WidgetKit

struct AppGroupManager {
    static let suiteName = "group.com.jasongelman.LutronHome"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    // MARK: - Keys
    private enum Key {
        static let devices = "widget_devices"
        static let scenes = "widget_scenes"
        static let usageEvents = "widget_usage_events"
        static let lightsOnCount = "widget_lights_on_count"
        static let serverHost = "widget_server_host"
        static let applianceStatus = "widget_appliance_status"
    }

    // MARK: - Appliance Status (lightweight for widget)
    struct ApplianceInfo: Codable {
        let name: String            // e.g. "Dishwasher", "Washer"
        let remainingMinutes: Int   // minutes until done
    }

    // MARK: - Write (called from main app)

    static func writeDevices(_ devices: [Int: DeviceState]) {
        guard let defaults else { return }
        let array = Array(devices.values)
        if let data = try? JSONEncoder().encode(array) {
            defaults.set(data, forKey: Key.devices)
        }
        let lightsOn = array.filter { $0.category == .light && $0.level > 0 }.count
        defaults.set(lightsOn, forKey: Key.lightsOnCount)
    }

    static func writeScenes(_ scenes: [LightScene]) {
        guard let defaults else { return }
        if let data = try? JSONEncoder().encode(scenes) {
            defaults.set(data, forKey: Key.scenes)
        }
    }

    static func writeUsageEvents(_ events: [UsageEvent]) {
        guard let defaults else { return }
        if let data = try? JSONEncoder().encode(events) {
            defaults.set(data, forKey: Key.usageEvents)
        }
    }

    static func writeServerHost(_ host: String) {
        guard let defaults else { return }
        defaults.set(host, forKey: Key.serverHost)
    }

    static func writeApplianceStatus(_ appliances: [ApplianceInfo]) {
        guard let defaults else { return }
        if let data = try? JSONEncoder().encode(appliances) {
            defaults.set(data, forKey: Key.applianceStatus)
        }
    }

    // MARK: - Read (called from widget / intents)

    static func readDevices() -> [DeviceState] {
        guard let defaults,
              let data = defaults.data(forKey: Key.devices),
              let devices = try? JSONDecoder().decode([DeviceState].self, from: data) else { return [] }
        return devices
    }

    static func readScenes() -> [LightScene] {
        guard let defaults,
              let data = defaults.data(forKey: Key.scenes),
              let scenes = try? JSONDecoder().decode([LightScene].self, from: data) else { return [] }
        return scenes
    }

    static func readUsageEvents() -> [UsageEvent] {
        guard let defaults,
              let data = defaults.data(forKey: Key.usageEvents),
              let events = try? JSONDecoder().decode([UsageEvent].self, from: data) else { return [] }
        return events
    }

    static func readLightsOnCount() -> Int {
        defaults?.integer(forKey: Key.lightsOnCount) ?? 0
    }

    static func readServerHost() -> String {
        defaults?.string(forKey: Key.serverHost) ?? "192.168.1.191"
    }

    static func readApplianceStatus() -> [ApplianceInfo] {
        guard let defaults,
              let data = defaults.data(forKey: Key.applianceStatus),
              let appliances = try? JSONDecoder().decode([ApplianceInfo].self, from: data) else { return [] }
        return appliances
    }

    // MARK: - Widget Refresh

    static func reloadWidgets() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}
```

- [ ] **Step 3: Write tests for `AppGroupManager` serialization**

```swift
// ios/LutronHome/LutronHomeTests/AppGroupManagerTests.swift
import XCTest
@testable import LutronHome

final class AppGroupManagerTests: XCTestCase {
    func testApplianceInfoRoundTrips() throws {
        let info = AppGroupManager.ApplianceInfo(name: "Dishwasher", remainingMinutes: 42)
        let data = try JSONEncoder().encode([info])
        let decoded = try JSONDecoder().decode([AppGroupManager.ApplianceInfo].self, from: data)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].name, "Dishwasher")
        XCTAssertEqual(decoded[0].remainingMinutes, 42)
    }

    func testSuggestedActionRoundTrips() throws {
        let action = SuggestedAction(
            type: .scene, id: "abc123", label: "Evening Scene",
            subtitle: "5 devices", level: nil
        )
        let data = try JSONEncoder().encode(action)
        let decoded = try JSONDecoder().decode(SuggestedAction.self, from: data)
        XCTAssertEqual(decoded.type, .scene)
        XCTAssertEqual(decoded.id, "abc123")
        XCTAssertEqual(decoded.label, "Evening Scene")
    }

    func testDeviceStateRoundTrips() throws {
        let device = DeviceState(
            integrationId: 5, name: "Kitchen Lights", type: .light,
            category: .light, room: "Kitchen", level: 80,
            components: nil, lastUpdated: Date().timeIntervalSince1970
        )
        let data = try JSONEncoder().encode([device])
        let decoded = try JSONDecoder().decode([DeviceState].self, from: data)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].integrationId, 5)
        XCTAssertEqual(decoded[0].level, 80)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run:
```bash
cd /Users/jasongelman/claude-code/lutron-home/ios/LutronHome
xcodebuild test -project LutronHome.xcodeproj -scheme LutronHome -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:LutronHomeTests/AppGroupManagerTests 2>&1 | tail -20
```
Expected: All 3 tests PASS

- [ ] **Step 5: Commit**

```bash
git add ios/LutronHome/LutronHome/SuggestedAction.swift ios/LutronHome/LutronHome/AppGroupManager.swift ios/LutronHome/LutronHomeTests/AppGroupManagerTests.swift
git commit -m "feat: add AppGroupManager and SuggestedAction model for widget data sharing"
```

---

## Task 2: Recommendation Engine

**Files:**
- Create: `ios/LutronHome/LutronHome/RecommendationEngine.swift`
- Create: `ios/LutronHome/LutronHomeTests/RecommendationEngineTests.swift`

- [ ] **Step 1: Write failing tests for recommendation engine**

```swift
// ios/LutronHome/LutronHomeTests/RecommendationEngineTests.swift
import XCTest
@testable import LutronHome

final class RecommendationEngineTests: XCTestCase {

    // Helper to create a usage event at a specific hour
    private func event(deviceId: Int, room: String, level: Double, hour: Int, daysAgo: Int = 0) -> UsageEvent {
        var components = Calendar.current.dateComponents(in: .current, from: Date())
        components.hour = hour
        components.minute = 0
        if daysAgo > 0 {
            components.day = (components.day ?? 1) - daysAgo
        }
        let date = Calendar.current.date(from: components) ?? Date()
        return UsageEvent(
            type: .device, id: String(deviceId), action: .setLevel,
            level: level, room: room, timestamp: date.timeIntervalSince1970
        )
    }

    private func sceneEvent(sceneId: String, hour: Int, daysAgo: Int = 0) -> UsageEvent {
        var components = Calendar.current.dateComponents(in: .current, from: Date())
        components.hour = hour
        if daysAgo > 0 {
            components.day = (components.day ?? 1) - daysAgo
        }
        let date = Calendar.current.date(from: components) ?? Date()
        return UsageEvent(
            type: .scene, id: sceneId, action: .activate,
            level: nil, room: nil, timestamp: date.timeIntervalSince1970
        )
    }

    private let kitchenLight = DeviceState(
        integrationId: 10, name: "Kitchen Lights", type: .light,
        category: .light, room: "Kitchen", level: 0,
        components: nil, lastUpdated: 0
    )
    private let kitchenLightOn = DeviceState(
        integrationId: 10, name: "Kitchen Lights", type: .light,
        category: .light, room: "Kitchen", level: 80,
        components: nil, lastUpdated: 0
    )
    private let diningShade = DeviceState(
        integrationId: 20, name: "Dining Shade", type: .shade,
        category: .shadesAndDrapes, room: "Dining Room", level: 0,
        components: nil, lastUpdated: 0
    )
    private let eveningScene = LightScene(
        id: "scene1", name: "Evening Scene", icon: "sunset",
        targets: [SceneDeviceTarget(deviceId: 10, level: 80)],
        createdAt: 0, updatedAt: 0
    )

    func testReturnsEmptyForNoEvents() {
        let result = RecommendationEngine.recommend(
            events: [], devices: [kitchenLight], scenes: [], maxCount: 3
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testRecommendsMostUsedDevice() {
        let currentHour = Calendar.current.component(.hour, from: Date())
        let events = (0..<10).map { _ in event(deviceId: 10, room: "Kitchen", level: 80, hour: currentHour) }
        let result = RecommendationEngine.recommend(
            events: events, devices: [kitchenLight], scenes: [], maxCount: 3
        )
        XCTAssertFalse(result.isEmpty)
        XCTAssertEqual(result[0].id, "10")
        XCTAssertEqual(result[0].type, .device)
    }

    func testSkipsDeviceAlreadyAtTargetLevel() {
        let currentHour = Calendar.current.component(.hour, from: Date())
        let events = (0..<10).map { _ in event(deviceId: 10, room: "Kitchen", level: 80, hour: currentHour) }
        // Kitchen light is already at 80 — should not recommend "set to 80"
        let result = RecommendationEngine.recommend(
            events: events, devices: [kitchenLightOn], scenes: [], maxCount: 3
        )
        // Should either be empty or recommend turning it off instead
        if let first = result.first {
            XCTAssertTrue(first.subtitle.lowercased().contains("off") || first.level == 0,
                          "Should suggest turning off, not setting to same level")
        }
    }

    func testRecommendsScenes() {
        let currentHour = Calendar.current.component(.hour, from: Date())
        let events = (0..<10).map { _ in sceneEvent(sceneId: "scene1", hour: currentHour) }
        let result = RecommendationEngine.recommend(
            events: events, devices: [kitchenLight], scenes: [eveningScene], maxCount: 3
        )
        XCTAssertFalse(result.isEmpty)
        XCTAssertEqual(result[0].type, .scene)
        XCTAssertEqual(result[0].id, "scene1")
    }

    func testSkipsSceneWhenAllDevicesAtSceneLevels() {
        let currentHour = Calendar.current.component(.hour, from: Date())
        let events = (0..<10).map { _ in sceneEvent(sceneId: "scene1", hour: currentHour) }
        // Kitchen light already at the scene target level (80)
        let result = RecommendationEngine.recommend(
            events: events, devices: [kitchenLightOn], scenes: [eveningScene], maxCount: 3
        )
        // Scene should be skipped since its target is already met
        let sceneActions = result.filter { $0.type == .scene && $0.id == "scene1" }
        XCTAssertTrue(sceneActions.isEmpty, "Should not recommend scene when devices already at target levels")
    }

    func testLimitsToMaxCount() {
        let currentHour = Calendar.current.component(.hour, from: Date())
        let events = (0..<10).map { _ in event(deviceId: 10, room: "Kitchen", level: 80, hour: currentHour) }
            + (0..<8).map { _ in event(deviceId: 20, room: "Dining Room", level: 100, hour: currentHour) }
        let result = RecommendationEngine.recommend(
            events: events, devices: [kitchenLight, diningShade], scenes: [eveningScene], maxCount: 2
        )
        XCTAssertLessThanOrEqual(result.count, 2)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
cd /Users/jasongelman/claude-code/lutron-home/ios/LutronHome
xcodebuild test -project LutronHome.xcodeproj -scheme LutronHome -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:LutronHomeTests/RecommendationEngineTests 2>&1 | tail -20
```
Expected: FAIL — `RecommendationEngine` not defined

- [ ] **Step 3: Implement `RecommendationEngine`**

```swift
// ios/LutronHome/LutronHome/RecommendationEngine.swift
import Foundation

enum RecommendationEngine {

    /// Produce up to `maxCount` recommended actions based on usage patterns and current state.
    static func recommend(
        events: [UsageEvent],
        devices: [DeviceState],
        scenes: [LightScene],
        maxCount: Int,
        now: Date = Date()
    ) -> [SuggestedAction] {
        guard !events.isEmpty else { return [] }

        let bucket = TimeBucket.current(date: now)
        let thirtyDaysAgo = now.timeIntervalSince1970 - 30 * 24 * 60 * 60
        let deviceMap = Dictionary(uniqueKeysWithValues: devices.map { ($0.integrationId, $0) })

        var scored: [SuggestedAction: Double] = [:]

        // --- Score devices ---
        let bucketDeviceEvents = events.filter { e in
            e.type == .device
                && TimeBucket.current(date: Date(timeIntervalSince1970: e.timestamp)) == bucket
                && e.timestamp > thirtyDaysAgo
        }

        // Count frequency per device, track most common level
        var deviceFrequency: [String: Int] = [:]
        var deviceLevels: [String: [Double]] = [:]
        var deviceRooms: [String: String] = [:]
        for e in bucketDeviceEvents {
            deviceFrequency[e.id, default: 0] += 1
            if let level = e.level { deviceLevels[e.id, default: []].append(level) }
            if let room = e.room { deviceRooms[e.id] = room }
        }

        for (idStr, count) in deviceFrequency {
            guard let deviceId = Int(idStr), let device = deviceMap[deviceId] else { continue }

            let levels = deviceLevels[idStr] ?? []
            let avgLevel = levels.isEmpty ? 0 : (levels.reduce(0, +) / Double(levels.count)).rounded()

            // State-aware filtering
            let currentLevel = device.level
            let tolerance: Double = 5

            if abs(currentLevel - avgLevel) < tolerance {
                // Device already at typical level — suggest turning off if it's on
                if currentLevel > 0 {
                    let action = SuggestedAction(
                        type: .device, id: idStr, label: device.name,
                        subtitle: "Turn off", level: 0
                    )
                    scored[action] = Double(count) * 0.5 // Lower score for "turn off" suggestions
                }
                continue
            }

            let subtitle: String
            if avgLevel == 0 {
                subtitle = "Turn off"
            } else if device.type == .shade {
                subtitle = "Open to \(Int(avgLevel))%"
            } else {
                subtitle = "Set to \(Int(avgLevel))%"
            }

            let action = SuggestedAction(
                type: .device, id: idStr, label: device.name,
                subtitle: subtitle, level: avgLevel
            )
            scored[action] = Double(count)
        }

        // --- Score scenes ---
        let bucketSceneEvents = events.filter { e in
            e.type == .scene
                && TimeBucket.current(date: Date(timeIntervalSince1970: e.timestamp)) == bucket
                && e.timestamp > thirtyDaysAgo
        }

        var sceneFrequency: [String: Int] = [:]
        for e in bucketSceneEvents {
            sceneFrequency[e.id, default: 0] += 1
        }

        for (sceneId, count) in sceneFrequency {
            guard let scene = scenes.first(where: { $0.id == sceneId }) else { continue }

            // Skip if all targets already at scene levels
            let allAtTarget = scene.targets.allSatisfy { target in
                guard let device = deviceMap[target.deviceId] else { return false }
                return abs(device.level - target.level) < 5
            }
            if allAtTarget { continue }

            let action = SuggestedAction(
                type: .scene, id: sceneId, label: scene.name,
                subtitle: "\(scene.targets.count) devices", level: nil
            )
            scored[action] = Double(count) * 1.2 // Slight boost for scenes
        }

        // Sort by score descending, take maxCount
        return scored
            .sorted { $0.value > $1.value }
            .prefix(maxCount)
            .map(\.key)
    }
}
```

- [ ] **Step 4: Make `SuggestedAction` conform to `Hashable` for dictionary use**

Add to `SuggestedAction.swift`:
```swift
extension SuggestedAction: Hashable {
    static func == (lhs: SuggestedAction, rhs: SuggestedAction) -> Bool {
        lhs.type == rhs.type && lhs.id == rhs.id && lhs.level == rhs.level
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(type)
        hasher.combine(id)
        hasher.combine(level)
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run:
```bash
cd /Users/jasongelman/claude-code/lutron-home/ios/LutronHome
xcodebuild test -project LutronHome.xcodeproj -scheme LutronHome -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:LutronHomeTests/RecommendationEngineTests 2>&1 | tail -20
```
Expected: All 6 tests PASS

- [ ] **Step 6: Commit**

```bash
git add ios/LutronHome/LutronHome/RecommendationEngine.swift ios/LutronHome/LutronHome/SuggestedAction.swift ios/LutronHome/LutronHomeTests/RecommendationEngineTests.swift
git commit -m "feat: add RecommendationEngine with time-bucket + state-aware scoring"
```

---

## Task 3: Server API Client

**Files:**
- Create: `ios/LutronHome/LutronHome/ServerAPIClient.swift`

- [ ] **Step 1: Create `ServerAPIClient` for widget/intent HTTP calls**

This is a lightweight HTTP client that calls the existing Node.js server REST API. The server runs on port 3001.

```swift
// ios/LutronHome/LutronHome/ServerAPIClient.swift
import Foundation

enum ServerAPIClient {
    enum APIError: Error, LocalizedError {
        case noServer
        case httpError(Int)
        case networkError(Error)

        var errorDescription: String? {
            switch self {
            case .noServer: return "Server address not configured"
            case .httpError(let code): return "Server returned HTTP \(code)"
            case .networkError(let err): return err.localizedDescription
            }
        }
    }

    private static func baseURL() -> URL? {
        let host = AppGroupManager.readServerHost()
        return URL(string: "http://\(host):3001")
    }

    /// Set a device to a specific level
    static func setDeviceLevel(deviceId: Int, level: Double, fadeTime: Double = 1.0) async throws {
        guard let base = baseURL() else { throw APIError.noServer }
        let url = base.appendingPathComponent("/api/devices/\(deviceId)")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let body: [String: Any] = ["level": level, "fadeTime": fadeTime]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    /// Activate a scene by ID
    static func activateScene(sceneId: String) async throws {
        guard let base = baseURL() else { throw APIError.noServer }
        let url = base.appendingPathComponent("/api/scenes/\(sceneId)/activate")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    /// Turn off all lights except those in Sebastian's Room
    static func turnOffAllLights() async throws {
        let devices = AppGroupManager.readDevices()
        let lightsToTurnOff = devices.filter {
            $0.category == .light && $0.level > 0 && $0.room != "Sebastian's Room"
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for device in lightsToTurnOff {
                group.addTask {
                    try await setDeviceLevel(deviceId: device.integrationId, level: 0, fadeTime: 1.0)
                }
            }
            try await group.waitForAll()
        }
    }

    /// Send a chat message and execute resulting actions via server
    static func sendChatMessage(_ text: String) async throws -> String {
        guard let base = baseURL() else { throw APIError.noServer }
        let url = base.appendingPathComponent("/api/chat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let body: [String: Any] = ["message": text]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let reply = json["reply"] as? String {
            return reply
        }
        return "Done"
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add ios/LutronHome/LutronHome/ServerAPIClient.swift
git commit -m "feat: add ServerAPIClient for widget/intent REST calls"
```

---

## Task 4: App Intents

**Files:**
- Create: `ios/LutronHome/LutronHome/Intents/ActivateSceneIntent.swift`
- Create: `ios/LutronHome/LutronHome/Intents/SetDeviceLevelIntent.swift`
- Create: `ios/LutronHome/LutronHome/Intents/AllLightsOffIntent.swift`
- Create: `ios/LutronHome/LutronHome/Intents/VoiceCommandIntent.swift`
- Create: `ios/LutronHome/LutronHome/Intents/LutronShortcutsProvider.swift`

- [ ] **Step 1: Create `ActivateSceneIntent`**

```swift
// ios/LutronHome/LutronHome/Intents/ActivateSceneIntent.swift
import AppIntents

struct ActivateSceneIntent: AppIntent {
    static var title: LocalizedStringResource = "Activate Scene"
    static var description = IntentDescription("Activate a saved lighting scene")

    @Parameter(title: "Scene Name")
    var sceneName: String

    static var parameterSummary: some ParameterSummary {
        Summary("Activate \(\.$sceneName)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let scenes = AppGroupManager.readScenes()
        guard let scene = scenes.first(where: {
            $0.name.localizedCaseInsensitiveCompare(sceneName) == .orderedSame
        }) else {
            return .result(dialog: "I couldn't find a scene called \"\(sceneName)\".")
        }

        try await ServerAPIClient.activateScene(sceneId: scene.id)
        return .result(dialog: "Activated \(scene.name).")
    }
}
```

- [ ] **Step 2: Create `SetDeviceLevelIntent`**

```swift
// ios/LutronHome/LutronHome/Intents/SetDeviceLevelIntent.swift
import AppIntents

struct SetDeviceLevelIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Device Level"
    static var description = IntentDescription("Set a light or shade to a specific level")

    @Parameter(title: "Device Name")
    var deviceName: String

    @Parameter(title: "Level", controlStyle: .slider, inclusiveRange: (0, 100))
    var level: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Set \(\.$deviceName) to \(\.$level)%")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let devices = AppGroupManager.readDevices()
        guard let device = devices.first(where: {
            $0.name.localizedCaseInsensitiveContains(deviceName)
        }) else {
            return .result(dialog: "I couldn't find a device called \"\(deviceName)\".")
        }

        try await ServerAPIClient.setDeviceLevel(
            deviceId: device.integrationId, level: Double(level)
        )

        let verb = level == 0 ? "Turned off" : "Set"
        let suffix = level == 0 ? "" : " to \(level)%"
        return .result(dialog: "\(verb) \(device.name)\(suffix).")
    }
}

// Helper for case-insensitive contains
private extension String {
    func localizedCaseInsensitiveContains(_ other: String) -> Bool {
        range(of: other, options: .caseInsensitive) != nil
    }
}
```

- [ ] **Step 3: Create `AllLightsOffIntent`**

```swift
// ios/LutronHome/LutronHome/Intents/AllLightsOffIntent.swift
import AppIntents

struct AllLightsOffIntent: AppIntent {
    static var title: LocalizedStringResource = "Turn Off All Lights"
    static var description = IntentDescription("Turn off all lights in the house, except Sebastian's Room")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await ServerAPIClient.turnOffAllLights()
        return .result(dialog: "All lights turned off.")
    }
}
```

- [ ] **Step 4: Create `VoiceCommandIntent`**

```swift
// ios/LutronHome/LutronHome/Intents/VoiceCommandIntent.swift
import AppIntents

struct VoiceCommandIntent: AppIntent {
    static var title: LocalizedStringResource = "Voice Command"
    static var description = IntentDescription("Tell Lutron Home what to do using natural language")

    @Parameter(title: "Command")
    var spokenText: String

    static var parameterSummary: some ParameterSummary {
        Summary("Tell Lutron Home \(\.$spokenText)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let reply = try await ServerAPIClient.sendChatMessage(spokenText)
        return .result(dialog: "\(reply)")
    }
}
```

- [ ] **Step 5: Create `LutronShortcutsProvider`**

```swift
// ios/LutronHome/LutronHome/Intents/LutronShortcutsProvider.swift
import AppIntents

struct LutronShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ActivateSceneIntent(),
            phrases: [
                "Activate \(\.$sceneName) in \(.applicationName)",
                "Turn on \(\.$sceneName) scene in \(.applicationName)"
            ],
            shortTitle: "Activate Scene",
            systemImageName: "lightswitch.on"
        )
        AppShortcut(
            intent: SetDeviceLevelIntent(),
            phrases: [
                "Set \(\.$deviceName) to \(\.$level) percent in \(.applicationName)",
                "Turn \(\.$deviceName) to \(\.$level) in \(.applicationName)"
            ],
            shortTitle: "Set Device Level",
            systemImageName: "slider.horizontal.3"
        )
        AppShortcut(
            intent: AllLightsOffIntent(),
            phrases: [
                "Turn off all lights in \(.applicationName)",
                "Lights off in \(.applicationName)"
            ],
            shortTitle: "All Lights Off",
            systemImageName: "lightbulb.slash"
        )
        AppShortcut(
            intent: VoiceCommandIntent(),
            phrases: [
                "Tell \(.applicationName) \(\.$spokenText)",
                "Ask \(.applicationName) \(\.$spokenText)"
            ],
            shortTitle: "Voice Command",
            systemImageName: "mic"
        )
    }
}
```

- [ ] **Step 6: Commit**

```bash
mkdir -p ios/LutronHome/LutronHome/Intents
git add ios/LutronHome/LutronHome/Intents/
git commit -m "feat: add App Intents for scenes, devices, all-off, and voice commands"
```

---

## Task 5: Entitlements + Main App Integration

**Files:**
- Modify: `ios/LutronHome/LutronHome/LutronHome.entitlements`
- Modify: `ios/LutronHome/LutronHome/LutronStore.swift`
- Modify: `ios/LutronHome/LutronHome/UsageTracker.swift`
- Modify: `ios/LutronHome/LutronHome/LutronHomeApp.swift`

- [ ] **Step 1: Add App Group to entitlements**

In `ios/LutronHome/LutronHome/LutronHome.entitlements`, add the App Group:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.developer.homekit</key>
    <true/>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.com.jasongelman.LutronHome</string>
    </array>
</dict>
</plist>
```

- [ ] **Step 2: Add App Group writes to `LutronStore.swift`**

Add a private method and call it from key state-change points.

After the `handleUnsolicited` method (around line 312), add:

```swift
    // MARK: - Widget Sync

    /// Push current state to App Group for widget consumption
    private func syncToAppGroup() {
        AppGroupManager.writeDevices(devices)
        AppGroupManager.writeScenes(scenes)
        AppGroupManager.writeServerHost(processorHost)
        AppGroupManager.reloadWidgets()
    }
```

Call `syncToAppGroup()` in these locations:
1. End of `handleUnsolicited` (after `devices[zoneId]?.level = level` on line ~310):
   ```swift
   syncToAppGroup()
   ```
2. End of `loadTopology` (after devices are fully loaded, around line ~290):
   ```swift
   syncToAppGroup()
   ```
3. In `setLevel` (after the LEAP command is sent, around line ~339):
   ```swift
   // Optimistically update App Group
   devices[deviceId]?.level = level
   syncToAppGroup()
   ```

Also add `import WidgetKit` at the top of the file.

- [ ] **Step 3: Add App Group dual-write to `UsageTracker.swift`**

In the `saveEvents()` method (line ~306), after saving to local UserDefaults, add the App Group write:

```swift
    private func saveEvents() {
        // Trim to max
        if events.count > Self.maxEvents {
            events = Array(events.suffix(Self.maxEvents))
        }
        if let data = try? JSONEncoder().encode(events) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
        // Sync to App Group for widget
        AppGroupManager.writeUsageEvents(events)
    }
```

- [ ] **Step 4: Register `AppShortcutsProvider` in `LutronHomeApp.swift`**

At the end of the `body` property (after the existing `.onChange` and `.preferredColorScheme` modifiers), add:

```swift
.onAppear {
    LutronShortcutsProvider.updateAppShortcutParameters()
}
```

Wait — `updateAppShortcutParameters` is a static method that should be called once. Place it inside the existing `.onAppear` block (around line 27), adding it after the existing setup code:

```swift
// Register Siri shortcuts
LutronShortcutsProvider.updateAppShortcutParameters()
```

- [ ] **Step 5: Add appliance status sync**

In `LutronHomeApp.swift`, the `homeConnect`, `smartHQ` managers are `@State` properties. We need to sync their status to App Group periodically. Add a helper function to the app struct and call it on scene phase change:

```swift
private func syncApplianceStatus() {
    var appliances: [AppGroupManager.ApplianceInfo] = []

    for dw in homeConnect.dishwashers where dw.operationState == .run {
        if let seconds = dw.remainingTime, seconds > 0 {
            appliances.append(.init(name: "Dishwasher", remainingMinutes: seconds / 60))
        }
    }
    for app in smartHQ.appliances where app.machineState == .running {
        if let minutes = app.remainingMinutes, minutes > 0 {
            let name = app.type == .washer ? "Washer" : "Dryer"
            appliances.append(.init(name: name, remainingMinutes: minutes))
        }
    }

    AppGroupManager.writeApplianceStatus(appliances)
    AppGroupManager.reloadWidgets()
}
```

Call `syncApplianceStatus()` in the `.active` scene phase handler alongside the existing resume calls.

- [ ] **Step 6: Verify the app builds**

Run:
```bash
cd /Users/jasongelman/claude-code/lutron-home/ios/LutronHome
xcodebuild build -project LutronHome.xcodeproj -scheme LutronHome -destination 'platform=iOS Simulator,name=iPhone 16' -configuration Debug 2>&1 | tail -20
```
Expected: BUILD SUCCEEDED

- [ ] **Step 7: Commit**

```bash
git add ios/LutronHome/LutronHome/LutronHome.entitlements ios/LutronHome/LutronHome/LutronStore.swift ios/LutronHome/LutronHome/UsageTracker.swift ios/LutronHome/LutronHome/LutronHomeApp.swift
git commit -m "feat: integrate App Group sync and Siri shortcuts in main app"
```

---

## Task 6: Widget Extension Target + Timeline Provider

**Files:**
- Create: `ios/LutronHome/LutronHomeWidget/LutronHomeWidget.swift`
- Create: `ios/LutronHome/LutronHomeWidget/WidgetTimelineProvider.swift`
- Create: `ios/LutronHome/LutronHomeWidget/LutronHomeWidget.entitlements`
- Create: `ios/LutronHome/LutronHomeWidget/Info.plist`

Note: The widget extension target must be added to the Xcode project. This is best done via Xcode's "File > New > Target > Widget Extension" flow, which auto-generates the pbxproj entries, build settings, and signing. The files below should replace the auto-generated content.

- [ ] **Step 1: Add widget extension target via Xcode CLI**

Since modifying `project.pbxproj` by hand is error-prone, the recommended approach is:

1. Open the project in Xcode
2. File > New > Target > Widget Extension
3. Product Name: `LutronHomeWidget`
4. Uncheck "Include Live Activity" (we'll add it later)
5. Uncheck "Include Configuration App Intent"
6. Finish

Then replace the generated files with our implementations. Alternatively, the implementing agent can use `xcodegen` or manually add the target entries to `project.pbxproj`.

- [ ] **Step 2: Create widget entitlements**

```xml
<!-- ios/LutronHome/LutronHomeWidget/LutronHomeWidget.entitlements -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.com.jasongelman.LutronHome</string>
    </array>
</dict>
</plist>
```

- [ ] **Step 3: Create `WidgetTimelineProvider`**

```swift
// ios/LutronHome/LutronHomeWidget/WidgetTimelineProvider.swift
import WidgetKit

struct LutronWidgetEntry: TimelineEntry {
    let date: Date
    let suggestions: [SuggestedAction]
    let lightsOnCount: Int
    let activeAppliance: AppGroupManager.ApplianceInfo?
}

struct LutronTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> LutronWidgetEntry {
        LutronWidgetEntry(
            date: Date(),
            suggestions: [
                SuggestedAction(type: .scene, id: "placeholder", label: "Evening Scene", subtitle: "5 devices", level: nil),
                SuggestedAction(type: .device, id: "placeholder2", label: "Kitchen Lights", subtitle: "Set to 80%", level: 80),
            ],
            lightsOnCount: 3,
            activeAppliance: nil
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (LutronWidgetEntry) -> Void) {
        completion(buildEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LutronWidgetEntry>) -> Void) {
        let entry = buildEntry()
        // Refresh every 15 minutes (also refreshes on WidgetCenter.reloadAllTimelines())
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: entry.date)!
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func buildEntry() -> LutronWidgetEntry {
        let devices = AppGroupManager.readDevices()
        let scenes = AppGroupManager.readScenes()
        let events = AppGroupManager.readUsageEvents()
        let lightsOn = AppGroupManager.readLightsOnCount()
        let appliances = AppGroupManager.readApplianceStatus()

        let suggestions = RecommendationEngine.recommend(
            events: events, devices: devices, scenes: scenes, maxCount: 3
        )

        // Pick appliance finishing soonest
        let activeAppliance = appliances
            .filter { $0.remainingMinutes > 0 }
            .min(by: { $0.remainingMinutes < $1.remainingMinutes })

        return LutronWidgetEntry(
            date: Date(),
            suggestions: suggestions,
            lightsOnCount: lightsOn,
            activeAppliance: activeAppliance
        )
    }
}
```

- [ ] **Step 4: Create `LutronHomeWidget` entry point**

```swift
// ios/LutronHome/LutronHomeWidget/LutronHomeWidget.swift
import SwiftUI
import WidgetKit

@main
struct LutronHomeWidgetBundle: WidgetBundle {
    var body: some Widget {
        LutronHomeSmallWidget()
        LutronHomeMediumWidget()
    }
}

struct LutronHomeSmallWidget: Widget {
    let kind = "LutronHomeSmallWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LutronTimelineProvider()) { entry in
            SmallWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Lutron Home")
        .description("Quick actions for your home")
        .supportedFamilies([.systemSmall])
    }
}

struct LutronHomeMediumWidget: Widget {
    let kind = "LutronHomeMediumWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LutronTimelineProvider()) { entry in
            MediumWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Lutron Home")
        .description("Quick actions, status, and controls")
        .supportedFamilies([.systemMedium])
    }
}
```

- [ ] **Step 5: Commit**

```bash
git add ios/LutronHome/LutronHomeWidget/
git commit -m "feat: add widget extension target with timeline provider"
```

---

## Task 7: Widget Views (Small + Medium)

**Files:**
- Create: `ios/LutronHome/LutronHomeWidget/SmallWidgetView.swift`
- Create: `ios/LutronHome/LutronHomeWidget/MediumWidgetView.swift`

- [ ] **Step 1: Create `SmallWidgetView`**

```swift
// ios/LutronHome/LutronHomeWidget/SmallWidgetView.swift
import SwiftUI
import WidgetKit
import AppIntents

struct SmallWidgetView: View {
    let entry: LutronWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("LUTRON HOME")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
                Spacer()
                // Mic button — opens app with voice input
                Link(destination: URL(string: "lutronhome://voice")!) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            // Action 1
            if let first = entry.suggestions.first {
                actionButton(first)
            }

            // Divider
            Rectangle()
                .fill(.quaternary)
                .frame(height: 0.5)
                .padding(.vertical, 6)

            // Action 2
            if entry.suggestions.count > 1 {
                actionButton(entry.suggestions[1])
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private func actionButton(_ action: SuggestedAction) -> some View {
        if action.type == .scene {
            Button(intent: ActivateSceneIntent(sceneName: action.label)) {
                actionLabel(action)
            }
            .buttonStyle(.plain)
        } else if let level = action.level {
            Button(intent: SetDeviceLevelIntent(deviceName: action.label, level: Int(level))) {
                actionLabel(action)
            }
            .buttonStyle(.plain)
        } else {
            actionLabel(action)
        }
    }

    private func actionLabel(_ action: SuggestedAction) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(action.label)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary.opacity(0.92))
                .lineLimit(1)
            Text(action.subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.primary.opacity(0.35))
                .lineLimit(1)
        }
    }
}
```

- [ ] **Step 2: Create `MediumWidgetView`**

```swift
// ios/LutronHome/LutronHomeWidget/MediumWidgetView.swift
import SwiftUI
import WidgetKit
import AppIntents

struct MediumWidgetView: View {
    let entry: LutronWidgetEntry

    private var statusText: String {
        let count = entry.lightsOnCount
        return count == 0 ? "All off" : "\(count) light\(count == 1 ? "" : "s") on"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(alignment: .firstTextBaseline) {
                Text("LUTRON HOME")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
                Text(statusText)
                    .font(.system(size: 10))
                    .foregroundStyle(.primary.opacity(0.3))
                Spacer()
                Link(destination: URL(string: "lutronhome://voice")!) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            // Bottom row: actions + optional appliance + all off
            HStack(alignment: .bottom, spacing: 0) {
                // Slot 1
                if let first = entry.suggestions.first {
                    actionButton(first)
                    divider()
                }

                // Slot 2
                if entry.suggestions.count > 1 {
                    actionButton(entry.suggestions[1])
                    divider()
                }

                // Slot 3: appliance override or 3rd recommendation
                if let appliance = entry.activeAppliance {
                    applianceSlot(appliance)
                } else if entry.suggestions.count > 2 {
                    actionButton(entry.suggestions[2])
                }

                divider()

                // All Off button
                Button(intent: AllLightsOffIntent()) {
                    VStack(spacing: 3) {
                        Image(systemName: "lightbulb.slash")
                            .font(.system(size: 14))
                        Text("All Off")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundStyle(.primary.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private func actionButton(_ action: SuggestedAction) -> some View {
        if action.type == .scene {
            Button(intent: ActivateSceneIntent(sceneName: action.label)) {
                actionLabel(action)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let level = action.level {
            Button(intent: SetDeviceLevelIntent(deviceName: action.label, level: Int(level))) {
                actionLabel(action)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            actionLabel(action)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func actionLabel(_ action: SuggestedAction) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(action.label)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary.opacity(0.92))
                .lineLimit(1)
            Text(action.subtitle)
                .font(.system(size: 10))
                .foregroundStyle(.primary.opacity(0.35))
                .lineLimit(1)
        }
    }

    private func applianceSlot(_ appliance: AppGroupManager.ApplianceInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(appliance.name)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary.opacity(0.55))
                .lineLimit(1)
            Text("\(appliance.remainingMinutes) min left")
                .font(.system(size: 10))
                .foregroundStyle(.primary.opacity(0.3))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func divider() -> some View {
        Rectangle()
            .fill(.quaternary)
            .frame(width: 0.5, height: 30)
            .padding(.horizontal, 6)
    }
}
```

- [ ] **Step 3: Add `ActivateSceneIntent` initializer for widget buttons**

The intent needs a convenience initializer that pre-fills the `sceneName` parameter. Add to `ActivateSceneIntent.swift`:

```swift
init() {}

init(sceneName: String) {
    self.sceneName = sceneName
}
```

Similarly for `SetDeviceLevelIntent.swift`:

```swift
init() {}

init(deviceName: String, level: Int) {
    self.deviceName = deviceName
    self.level = level
}
```

- [ ] **Step 4: Build the widget target**

Run:
```bash
cd /Users/jasongelman/claude-code/lutron-home/ios/LutronHome
xcodebuild build -project LutronHome.xcodeproj -scheme LutronHomeWidgetExtension -destination 'platform=iOS Simulator,name=iPhone 16' -configuration Debug 2>&1 | tail -20
```
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add ios/LutronHome/LutronHomeWidget/SmallWidgetView.swift ios/LutronHome/LutronHomeWidget/MediumWidgetView.swift ios/LutronHome/LutronHome/Intents/
git commit -m "feat: add small and medium widget views with intent-backed actions"
```

---

## Task 8: Voice Input via URL Scheme

**Files:**
- Modify: `ios/LutronHome/LutronHome/LutronHomeApp.swift`
- Modify: `ios/LutronHome/LutronHome/ContentView.swift`

The widget mic button uses a `Link(destination: URL(string: "lutronhome://voice")!)` to open the app. We need to handle this URL and present the chat view with speech recognition active.

- [ ] **Step 1: Add URL handling to `LutronHomeApp.swift`**

Add a `@State` property and `.onOpenURL` handler:

```swift
@State private var showVoiceInput = false
```

Add after the existing modifiers:
```swift
.onOpenURL { url in
    if url.host == "voice" {
        showVoiceInput = true
    }
}
```

Pass `showVoiceInput` as a binding to `ContentView` via environment or direct binding.

- [ ] **Step 2: Add voice input sheet to `ContentView`**

Add a `.sheet` modifier that presents `ChatView` with auto-focus on voice input when `showVoiceInput` is true. The existing `ChatView` in the app already handles text input — this extends it to auto-start speech recognition.

Add to the existing `ContentView`:

```swift
.sheet(isPresented: $showVoiceInput) {
    NavigationStack {
        ChatView(autoStartVoice: true)
            .navigationTitle("Voice Command")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showVoiceInput = false }
                }
            }
    }
}
```

The `showVoiceInput` state needs to be passed from `LutronHomeApp` to `ContentView`. Add it as an `@Environment` value or pass as a `@Binding`. Simplest approach: add `@Binding var showVoiceInput: Bool` to `ContentView` and pass it from the app struct.

- [ ] **Step 3: Add speech recognition to `ChatView`**

The existing `ChatView.swift` has a text input field. Add an `autoStartVoice` parameter and `SFSpeechRecognizer` integration:

Add to `ChatView`:

```swift
import Speech

// Add parameter
var autoStartVoice: Bool = false

// Add state
@State private var isListening = false
@State private var speechRecognizer = SFSpeechRecognizer()
@State private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
@State private var recognitionTask: SFSpeechRecognitionTask?
@State private var audioEngine = AVAudioEngine()

// Mic button next to text field
Button {
    if isListening { stopListening() } else { startListening() }
} label: {
    Image(systemName: isListening ? "mic.fill" : "mic")
        .foregroundStyle(isListening ? .red : .secondary)
}

// Methods
private func startListening() {
    SFSpeechRecognizer.requestAuthorization { status in
        guard status == .authorized else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        try? audioEngine.start()
        isListening = true

        recognitionTask = speechRecognizer?.recognitionTask(with: request) { result, error in
            if let result {
                messageText = result.bestTranscription.formattedString
                if result.isFinal {
                    stopListening()
                    // Auto-send on final result
                    sendMessage()
                }
            }
            if error != nil { stopListening() }
        }
    }
}

private func stopListening() {
    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
    recognitionRequest?.endAudio()
    recognitionTask?.cancel()
    recognitionRequest = nil
    recognitionTask = nil
    isListening = false
}
```

Add `.onAppear` to auto-start if `autoStartVoice`:
```swift
.onAppear {
    if autoStartVoice {
        startListening()
    }
}
```

- [ ] **Step 4: Add `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription` to Info.plist**

These are required for microphone and speech recognition access. Add to the Xcode target's Info.plist (or via build settings):

```
NSMicrophoneUsageDescription: "Lutron Home uses the microphone for voice commands to control your lights and shades."
NSSpeechRecognitionUsageDescription: "Lutron Home uses speech recognition to understand your voice commands."
```

- [ ] **Step 5: Build and verify**

Run:
```bash
cd /Users/jasongelman/claude-code/lutron-home/ios/LutronHome
xcodebuild build -project LutronHome.xcodeproj -scheme LutronHome -destination 'platform=iOS Simulator,name=iPhone 16' -configuration Debug 2>&1 | tail -20
```
Expected: BUILD SUCCEEDED

- [ ] **Step 6: Commit**

```bash
git add ios/LutronHome/LutronHome/LutronHomeApp.swift ios/LutronHome/LutronHome/ContentView.swift ios/LutronHome/LutronHome/ChatView.swift
git commit -m "feat: add voice input via URL scheme with speech recognition"
```

---

## Task 9: Xcode Project Configuration

**Files:**
- Modify: `ios/LutronHome/LutronHome.xcodeproj/project.pbxproj`

This task handles the Xcode project plumbing that makes everything compile together.

- [ ] **Step 1: Add widget extension target to Xcode project**

The most reliable way to do this:

1. Open `ios/LutronHome/LutronHome.xcodeproj` in Xcode
2. File > New > Target > Widget Extension
3. Name: `LutronHomeWidget`
4. Bundle Identifier: `com.jasongelman.LutronHome.Widget`
5. Team: WRS5YQAAC6 (same as main app)
6. Uncheck "Include Live Activity" and "Include Configuration App Intent"
7. When asked to activate the scheme, click Activate

After the target is created:
- Delete the auto-generated Swift files (they'll be replaced by our files from Tasks 6-7)
- Add our files to the target:
  - `LutronHomeWidget/LutronHomeWidget.swift`
  - `LutronHomeWidget/WidgetTimelineProvider.swift`
  - `LutronHomeWidget/SmallWidgetView.swift`
  - `LutronHomeWidget/MediumWidgetView.swift`
- Add shared files to both the main app AND widget targets (Target Membership):
  - `AppGroupManager.swift`
  - `SuggestedAction.swift`
  - `RecommendationEngine.swift`
  - `ServerAPIClient.swift`
  - `Models.swift` (for `DeviceState`, `LightScene`, etc.)
  - `UsageTracker.swift` (for `UsageEvent`, `TimeBucket`)
  - All files in `Intents/` directory
- Set the widget entitlements:
  - Build Settings > Code Signing Entitlements: `LutronHomeWidget/LutronHomeWidget.entitlements`
- Add App Group capability to widget target in Signing & Capabilities
- Embed the widget extension in the main app:
  - Main target > General > Frameworks, Libraries, and Embedded Content
  - Or: Build Phases > Embed App Extensions

- [ ] **Step 2: Verify both targets build**

```bash
cd /Users/jasongelman/claude-code/lutron-home/ios/LutronHome
xcodebuild build -project LutronHome.xcodeproj -scheme LutronHome -destination 'platform=iOS Simulator,name=iPhone 16' -configuration Debug 2>&1 | tail -5
xcodebuild build -project LutronHome.xcodeproj -scheme LutronHomeWidgetExtension -destination 'platform=iOS Simulator,name=iPhone 16' -configuration Debug 2>&1 | tail -5
```
Expected: Both BUILD SUCCEEDED

- [ ] **Step 3: Run all tests**

```bash
cd /Users/jasongelman/claude-code/lutron-home/ios/LutronHome
xcodebuild test -project LutronHome.xcodeproj -scheme LutronHome -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20
```
Expected: All tests PASS

- [ ] **Step 4: Commit**

```bash
git add ios/LutronHome/LutronHome.xcodeproj/ ios/LutronHome/LutronHomeWidget/
git commit -m "feat: add LutronHomeWidget extension target to Xcode project"
```

---

## Task 10: End-to-End Verification

- [ ] **Step 1: Build and install on simulator**

```bash
cd /Users/jasongelman/claude-code/lutron-home/ios/LutronHome
xcodebuild build -project LutronHome.xcodeproj -scheme LutronHome -destination 'platform=iOS Simulator,name=iPhone 16' -configuration Debug 2>&1 | tail -10
```

- [ ] **Step 2: Install and launch on simulator**

```bash
xcrun simctl install booted $(find ~/Library/Developer/Xcode/DerivedData -name "LutronHome.app" -path "*/Debug-iphonesimulator/*" | head -1)
xcrun simctl launch booted com.jasongelman.LutronHome
```

- [ ] **Step 3: Verify widget appears in widget gallery**

Long-press on simulator home screen > "+" button > search "Lutron". Both small and medium widgets should appear.

- [ ] **Step 4: Verify Siri integration**

```bash
# Check that shortcuts are registered
xcrun simctl spawn booted log stream --predicate 'subsystem == "com.apple.shortcuts"' --timeout 5
```

Or test in simulator: Settings > Siri & Search > search "Lutron Home" — shortcuts should appear.

- [ ] **Step 5: Run full test suite one final time**

```bash
cd /Users/jasongelman/claude-code/lutron-home/ios/LutronHome
xcodebuild test -project LutronHome.xcodeproj -scheme LutronHome -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "Test Suite|Tests? (Passed|Failed)|BUILD"
```
Expected: All tests pass, BUILD SUCCEEDED

- [ ] **Step 6: Final commit with all remaining changes**

```bash
git add -A ios/LutronHome/
git status
git commit -m "feat: complete iOS widget with recommendations, voice input, and Siri integration"
```
