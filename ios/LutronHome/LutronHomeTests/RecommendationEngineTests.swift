import XCTest
@testable import LutronHome

final class RecommendationEngineTests: XCTestCase {

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
        let result = RecommendationEngine.recommend(
            events: events, devices: [kitchenLightOn], scenes: [], maxCount: 3
        )
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
        let result = RecommendationEngine.recommend(
            events: events, devices: [kitchenLightOn], scenes: [eveningScene], maxCount: 3
        )
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
