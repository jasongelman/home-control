import XCTest
@testable import LutronHome

final class StoreTests: XCTestCase {

    // MARK: - lightsOn filtering

    func testLightsOnFiltersLightsOnly() {
        let store = LutronStore()
        store.devices = [
            1: makeDevice(id: 1, category: .light, level: 50),
            2: makeDevice(id: 2, category: .shadesAndDrapes, level: 100),
            3: makeDevice(id: 3, category: .outlet, level: 75),
            4: makeDevice(id: 4, category: .light, level: 0),
            5: makeDevice(id: 5, category: .light, level: 25),
        ]
        let on = store.lightsOn
        XCTAssertEqual(on.count, 2, "Only lights with level > 0 should be included")
        XCTAssertTrue(on.allSatisfy { $0.category == .light })
        XCTAssertTrue(on.allSatisfy { $0.level > 0 })
    }

    func testLightsOnEmpty() {
        let store = LutronStore()
        store.devices = [
            1: makeDevice(id: 1, category: .light, level: 0),
        ]
        XCTAssertTrue(store.lightsOn.isEmpty)
    }

    func testLightsOnSorted() {
        let store = LutronStore()
        store.devices = [
            1: makeDevice(id: 1, name: "Chandelier", room: "Kitchen", category: .light, level: 50),
            2: makeDevice(id: 2, name: "Accent", room: "Kitchen", category: .light, level: 50),
            3: makeDevice(id: 3, name: "Sconces", room: "Dining Room", category: .light, level: 50),
        ]
        let on = store.lightsOn
        // Sorted by (room, name): Dining Room < Kitchen, then Accent < Chandelier
        XCTAssertEqual(on[0].name, "Sconces")
        XCTAssertEqual(on[1].name, "Accent")
        XCTAssertEqual(on[2].name, "Chandelier")
    }

    // MARK: - rooms grouping

    func testRoomsGroupedByRoom() {
        let store = LutronStore()
        store.devices = [
            1: makeDevice(id: 1, room: "Kitchen", category: .light, level: 50),
            2: makeDevice(id: 2, room: "Kitchen", category: .light, level: 0),
            3: makeDevice(id: 3, room: "Bedroom 1", category: .light, level: 25),
        ]
        let rooms = store.rooms
        XCTAssertEqual(rooms.count, 2)
        // Sorted by room name: Bedroom 1 < Kitchen
        XCTAssertEqual(rooms[0].name, "Bedroom 1")
        XCTAssertEqual(rooms[0].devices.count, 1)
        XCTAssertEqual(rooms[1].name, "Kitchen")
        XCTAssertEqual(rooms[1].devices.count, 2)
    }

    // MARK: - LEAP message structures

    func testLEAPMessageDecode() throws {
        let json = Data("""
        {
            "CommuniqueType": "ReadResponse",
            "Header": {
                "ClientTag": "1",
                "Url": "/zone/42",
                "StatusCode": "200 OK",
                "MessageBodyType": "OneZoneStatus"
            },
            "Body": {
                "ZoneStatus": {
                    "Zone": {"href": "/zone/42"},
                    "Level": 75
                }
            }
        }
        """.utf8)
        let msg = try JSONDecoder().decode(LEAPMessage.self, from: json)
        XCTAssertEqual(msg.CommuniqueType, "ReadResponse")
        XCTAssertEqual(msg.Header.ClientTag, "1")
        XCTAssertEqual(msg.Header.Url, "/zone/42")
        XCTAssertEqual(msg.Header.StatusCode, "200 OK")
        XCTAssertEqual(msg.Header.MessageBodyType, "OneZoneStatus")
        XCTAssertNotNil(msg.Body?.ZoneStatus)
        let zs = msg.Body!.ZoneStatus!
        XCTAssertEqual(zs["Zone"]?.dictValue?["href"]?.stringValue, "/zone/42")
        XCTAssertEqual(zs["Level"]?.doubleValue, 75.0)
    }

    func testLEAPMessageDecodeMultipleZones() throws {
        let json = Data("""
        {
            "CommuniqueType": "SubscribeResponse",
            "Header": {
                "ClientTag": "2",
                "Url": "/zone/status",
                "StatusCode": "200 OK",
                "MessageBodyType": "MultipleZoneStatus"
            },
            "Body": {
                "ZoneStatuses": [
                    {"Zone": {"href": "/zone/1"}, "Level": 100},
                    {"Zone": {"href": "/zone/2"}, "Level": 0},
                    {"Zone": {"href": "/zone/3"}, "Level": 50}
                ]
            }
        }
        """.utf8)
        let msg = try JSONDecoder().decode(LEAPMessage.self, from: json)
        XCTAssertEqual(msg.Body?.ZoneStatuses?.count, 3)
        XCTAssertEqual(msg.Body?.ZoneStatuses?[0]["Level"]?.doubleValue, 100.0)
        XCTAssertEqual(msg.Body?.ZoneStatuses?[2]["Level"]?.doubleValue, 50.0)
    }

    func testLEAPMessageDecodeAreas() throws {
        let json = Data("""
        {
            "CommuniqueType": "ReadResponse",
            "Header": {"ClientTag": "3", "Url": "/area", "StatusCode": "200 OK"},
            "Body": {
                "Areas": [
                    {"href": "/area/1", "Name": "Kitchen"},
                    {"href": "/area/2", "Name": "Family Room"}
                ]
            }
        }
        """.utf8)
        let msg = try JSONDecoder().decode(LEAPMessage.self, from: json)
        XCTAssertEqual(msg.Body?.Areas?.count, 2)
        XCTAssertEqual(msg.Body?.Areas?[0]["Name"]?.stringValue, "Kitchen")
    }

    func testLEAPPayloadEncode() throws {
        let payload = LEAPMessagePayload(
            CommuniqueType: "CreateRequest",
            Header: LEAPMessageHeader(Url: "/zone/42/commandprocessor"),
            Body: LEAPBodyPayload(Command: LEAPCommand(
                CommandType: "GoToLevel",
                Parameter: [["Type": AnyCodable("Level"), "Value": AnyCodable(75)]],
                FadeTime: "00:00:02"
            ))
        )
        let data = try JSONEncoder().encode(payload)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(dict["CommuniqueType"] as? String, "CreateRequest")
        let body = dict["Body"] as? [String: Any]
        let command = body?["Command"] as? [String: Any]
        XCTAssertEqual(command?["CommandType"] as? String, "GoToLevel")
        XCTAssertEqual(command?["FadeTime"] as? String, "00:00:02")
    }

    // MARK: - LEAPError

    func testLEAPErrorDescriptions() {
        XCTAssertNotNil(LEAPError.disconnected.errorDescription)
        XCTAssertTrue(LEAPError.timeout(url: "/zone").errorDescription!.contains("/zone"))
        XCTAssertTrue(LEAPError.loginFailed(status: "401").errorDescription!.contains("401"))
        XCTAssertNotNil(LEAPError.notConnected.errorDescription)
    }

    // MARK: - Helpers

    private func makeDevice(
        id: Int = 1,
        name: String = "Test",
        room: String = "Test Room",
        category: DeviceCategory = .light,
        level: Double = 0
    ) -> DeviceState {
        DeviceState(
            integrationId: id,
            name: name,
            type: category == .shadesAndDrapes ? .shade : .light,
            category: category,
            room: room,
            level: level,
            components: nil,
            lastUpdated: 0
        )
    }
}
