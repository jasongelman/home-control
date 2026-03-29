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
