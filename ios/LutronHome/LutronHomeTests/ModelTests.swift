import XCTest
@testable import LutronHome

final class DeviceCategoryTests: XCTestCase {

    // MARK: - CCO → Window

    func testCCOIsWindow() {
        XCTAssertEqual(DeviceCategory.classify(controlType: "CCO", name: "MBTH Window Film"), .window)
    }

    func testCCOOverridesFanName() {
        XCTAssertEqual(DeviceCategory.classify(controlType: "CCO", name: "Fake Fan CCO"), .window)
    }

    // MARK: - Shade → Shades & Drapes

    func testShadeControlType() {
        XCTAssertEqual(DeviceCategory.classify(controlType: "Shade", name: "Rear Drapes"), .shadesAndDrapes)
    }

    func testShadeControlTypeAny() {
        XCTAssertEqual(DeviceCategory.classify(controlType: "Shade", name: "Side Shades"), .shadesAndDrapes)
    }

    // MARK: - Fan

    func testFanByName() {
        XCTAssertEqual(DeviceCategory.classify(controlType: "Switched", name: "MBth Fan"), .fan)
    }

    func testFanCaseInsensitive() {
        XCTAssertEqual(DeviceCategory.classify(controlType: "Switched", name: "Ceiling FAN"), .fan)
    }

    func testFanDimmed() {
        XCTAssertEqual(DeviceCategory.classify(controlType: "Dimmed", name: "Fan Light"), .fan)
    }

    // MARK: - Exterior Switched → Light

    func testExteriorSwitchedLandscape() {
        XCTAssertEqual(DeviceCategory.classify(controlType: "Switched", name: "Landscape"), .light)
    }

    func testExteriorSwitchedGarageFloods() {
        XCTAssertEqual(DeviceCategory.classify(controlType: "Switched", name: "Garage Floods"), .light)
    }

    func testExteriorSwitchedDeck() {
        XCTAssertEqual(DeviceCategory.classify(controlType: "Switched", name: "Deck - X102-02"), .light)
    }

    // MARK: - Switched (non-exterior) → Outlet

    func testSwitchedOutlet() {
        XCTAssertEqual(DeviceCategory.classify(controlType: "Switched", name: "MBD Switched Outlets"), .outlet)
    }

    func testSwitchedGeneric() {
        XCTAssertEqual(DeviceCategory.classify(controlType: "Switched", name: "Some Random Switch"), .outlet)
    }

    // MARK: - Dimmed → Light

    func testDimmedLight() {
        XCTAssertEqual(DeviceCategory.classify(controlType: "Dimmed", name: "Kitchen Recessed"), .light)
    }

    func testUnknownControlType() {
        XCTAssertEqual(DeviceCategory.classify(controlType: "Unknown", name: "Zone 42"), .light)
    }

    // MARK: - Category Properties

    func testCategoryIcons() {
        XCTAssertEqual(DeviceCategory.light.icon, "lightbulb.fill")
        XCTAssertEqual(DeviceCategory.shadesAndDrapes.icon, "blinds.vertical.open")
        XCTAssertEqual(DeviceCategory.outlet.icon, "poweroutlet.type.b")
        XCTAssertEqual(DeviceCategory.fan.icon, "fan")
        XCTAssertEqual(DeviceCategory.window.icon, "window.vertical.open")
    }

    func testCategoryRawValues() {
        XCTAssertEqual(DeviceCategory.light.rawValue, "Lights")
        XCTAssertEqual(DeviceCategory.shadesAndDrapes.rawValue, "Shades & Drapes")
        XCTAssertEqual(DeviceCategory.outlet.rawValue, "Outlets")
        XCTAssertEqual(DeviceCategory.fan.rawValue, "Fans")
        XCTAssertEqual(DeviceCategory.window.rawValue, "Windows")
    }
}

final class FloorMappingTests: XCTestCase {

    // MARK: - Upstairs

    func testAtticBedroom() {
        XCTAssertEqual(Floor.floor(for: "Attic Guest Bedroom"), .upstairs)
    }

    func testAtticBathroom() {
        XCTAssertEqual(Floor.floor(for: "Attic Bathroom"), .upstairs)
    }

    func testPlayroom() {
        XCTAssertEqual(Floor.floor(for: "Playroom"), .upstairs)
    }

    func testSecretRoom() {
        XCTAssertEqual(Floor.floor(for: "Secret Room"), .upstairs)
    }

    // MARK: - Main Floor

    func testKitchen() {
        XCTAssertEqual(Floor.floor(for: "Kitchen"), .mainFloor)
    }

    func testFamilyRoom() {
        XCTAssertEqual(Floor.floor(for: "Family Room"), .mainFloor)
    }

    func testDiningRoom() {
        XCTAssertEqual(Floor.floor(for: "Dining Room"), .mainFloor)
    }

    func testJasonOffice() {
        XCTAssertEqual(Floor.floor(for: "Jason Office"), .mainFloor)
    }

    func testRachelOffice() {
        XCTAssertEqual(Floor.floor(for: "Rachel Office"), .mainFloor)
    }

    func testLivingRoom() {
        XCTAssertEqual(Floor.floor(for: "Living Room"), .mainFloor)
    }

    func testMainEntry() {
        XCTAssertEqual(Floor.floor(for: "Main Entry"), .mainFloor)
    }

    func testMudroomEntry() {
        XCTAssertEqual(Floor.floor(for: "Mudroom Entry"), .mainFloor)
    }

    func testPowderRoom() {
        XCTAssertEqual(Floor.floor(for: "Powder Room"), .mainFloor)
    }

    // MARK: - Downstairs

    func testBedroom1() {
        XCTAssertEqual(Floor.floor(for: "Bedroom 1"), .downstairs)
    }

    func testBedroom2() {
        XCTAssertEqual(Floor.floor(for: "Bedroom 2"), .downstairs)
    }

    func testMasterSuite() {
        XCTAssertEqual(Floor.floor(for: "Master Suite"), .downstairs)
    }

    func testPrimaryBedroom() {
        XCTAssertEqual(Floor.floor(for: "Primary Bedroom"), .downstairs)
    }

    func testPrimaryBathroom() {
        XCTAssertEqual(Floor.floor(for: "Primary Bathroom"), .downstairs)
    }

    func testRachelCloset() {
        XCTAssertEqual(Floor.floor(for: "Rachel Closet"), .downstairs)
    }

    func testJasonCloset() {
        XCTAssertEqual(Floor.floor(for: "Jason Closet"), .downstairs)
    }

    func testNannySuite() {
        XCTAssertEqual(Floor.floor(for: "Nanny Suite"), .downstairs)
    }

    func testGym() {
        XCTAssertEqual(Floor.floor(for: "Gym"), .downstairs)
    }

    func testLaundry() {
        XCTAssertEqual(Floor.floor(for: "Laundry"), .downstairs)
    }

    // MARK: - Exterior

    func testFront() {
        XCTAssertEqual(Floor.floor(for: "Front"), .exterior)
    }

    func testDriveway() {
        XCTAssertEqual(Floor.floor(for: "Driveway"), .exterior)
    }

    func testRear() {
        XCTAssertEqual(Floor.floor(for: "Rear"), .exterior)
    }

    func testGarage() {
        XCTAssertEqual(Floor.floor(for: "Garage"), .exterior)
    }

    // MARK: - Unknown defaults to mainFloor

    func testUnknownRoom() {
        XCTAssertEqual(Floor.floor(for: "Mystery Room"), .mainFloor)
    }

    // MARK: - Floor Properties

    func testFloorIcons() {
        XCTAssertEqual(Floor.upstairs.icon, "arrow.up")
        XCTAssertEqual(Floor.mainFloor.icon, "house")
        XCTAssertEqual(Floor.downstairs.icon, "arrow.down")
        XCTAssertEqual(Floor.exterior.icon, "tree")
    }

    func testAllFloorsCovered() {
        XCTAssertEqual(Floor.allCases.count, 4)
    }
}

final class DeviceStateTests: XCTestCase {

    func testIsOnTrue() {
        let device = makeDevice(level: 50)
        XCTAssertTrue(device.isOn)
    }

    func testIsOnFalse() {
        let device = makeDevice(level: 0)
        XCTAssertFalse(device.isOn)
    }

    func testBrightnessPercent() {
        let device = makeDevice(level: 73.6)
        XCTAssertEqual(device.brightnessPercent, 74)
    }

    func testBrightnessPercentZero() {
        let device = makeDevice(level: 0)
        XCTAssertEqual(device.brightnessPercent, 0)
    }

    func testBrightnessPercentFull() {
        let device = makeDevice(level: 100)
        XCTAssertEqual(device.brightnessPercent, 100)
    }

    func testIdMatchesIntegrationId() {
        let device = makeDevice(id: 42)
        XCTAssertEqual(device.id, 42)
    }

    // Helper
    private func makeDevice(id: Int = 1, level: Double = 0) -> DeviceState {
        DeviceState(
            integrationId: id,
            name: "Test Light",
            type: .light,
            category: .light,
            room: "Test Room",
            level: level,
            components: nil,
            lastUpdated: 0
        )
    }
}
