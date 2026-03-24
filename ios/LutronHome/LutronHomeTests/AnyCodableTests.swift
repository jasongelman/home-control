import XCTest
@testable import LutronHome

final class AnyCodableTests: XCTestCase {

    // MARK: - String

    func testStringValue() {
        let ac = AnyCodable("hello")
        XCTAssertEqual(ac.stringValue, "hello")
        XCTAssertNil(ac.intValue)
        XCTAssertNil(ac.doubleValue)
        XCTAssertNil(ac.boolValue)
    }

    // MARK: - Int

    func testIntValue() {
        let ac = AnyCodable(42)
        XCTAssertEqual(ac.intValue, 42)
        XCTAssertNil(ac.stringValue)
    }

    func testIntToDouble() {
        let ac = AnyCodable(100)
        XCTAssertEqual(ac.doubleValue, 100.0)
    }

    // MARK: - Double

    func testDoubleValue() {
        let ac = AnyCodable(3.14)
        XCTAssertEqual(ac.doubleValue, 3.14)
        XCTAssertNil(ac.stringValue)
    }

    func testDoubleToInt() {
        let ac = AnyCodable(25.0)
        XCTAssertEqual(ac.intValue, 25)
    }

    func testDoubleToIntTruncates() {
        let ac = AnyCodable(99.7)
        XCTAssertEqual(ac.intValue, 99)
    }

    // MARK: - Bool

    func testBoolTrue() {
        let ac = AnyCodable(true)
        XCTAssertEqual(ac.boolValue, true)
    }

    func testBoolFalse() {
        let ac = AnyCodable(false)
        XCTAssertEqual(ac.boolValue, false)
    }

    // MARK: - Dict

    func testDictValue() {
        let inner: [String: AnyCodable] = ["key": AnyCodable("val")]
        let ac = AnyCodable(inner)
        XCTAssertNotNil(ac.dictValue)
        XCTAssertEqual(ac.dictValue?["key"]?.stringValue, "val")
    }

    // MARK: - Array

    func testArrayValue() {
        let inner: [AnyCodable] = [AnyCodable(1), AnyCodable(2)]
        let ac = AnyCodable(inner)
        XCTAssertNotNil(ac.arrayValue)
        XCTAssertEqual(ac.arrayValue?.count, 2)
    }

    // MARK: - JSON Decode round-trip

    func testDecodeInt() throws {
        let json = Data("42".utf8)
        let ac = try JSONDecoder().decode(AnyCodable.self, from: json)
        XCTAssertEqual(ac.intValue, 42)
        // Int-first decoding means doubleValue should use fallback
        XCTAssertEqual(ac.doubleValue, 42.0)
    }

    func testDecodeDouble() throws {
        let json = Data("3.14".utf8)
        let ac = try JSONDecoder().decode(AnyCodable.self, from: json)
        XCTAssertEqual(ac.doubleValue, 3.14)
    }

    func testDecodeString() throws {
        let json = Data("\"hello\"".utf8)
        let ac = try JSONDecoder().decode(AnyCodable.self, from: json)
        XCTAssertEqual(ac.stringValue, "hello")
    }

    func testDecodeBool() throws {
        let json = Data("true".utf8)
        let ac = try JSONDecoder().decode(AnyCodable.self, from: json)
        XCTAssertEqual(ac.boolValue, true)
    }

    func testDecodeNestedDict() throws {
        let json = Data("""
        {"Name": "Kitchen", "Level": 75}
        """.utf8)
        let ac = try JSONDecoder().decode([String: AnyCodable].self, from: json)
        XCTAssertEqual(ac["Name"]?.stringValue, "Kitchen")
        XCTAssertEqual(ac["Level"]?.intValue, 75)
        XCTAssertEqual(ac["Level"]?.doubleValue, 75.0)
    }

    func testDecodeZoneLevelAsInt() throws {
        // LEAP returns zone levels as integers — the root cause of the original bug
        let json = Data("""
        {"Zone": {"href": "/zone/42"}, "Level": 100}
        """.utf8)
        let zs = try JSONDecoder().decode([String: AnyCodable].self, from: json)
        let level = zs["Level"]?.doubleValue
        XCTAssertEqual(level, 100.0, "Level decoded as Int should convert to Double")
    }

    func testDecodeZoneLevelAsDouble() throws {
        let json = Data("""
        {"Zone": {"href": "/zone/42"}, "Level": 75.5}
        """.utf8)
        let zs = try JSONDecoder().decode([String: AnyCodable].self, from: json)
        let level = zs["Level"]?.doubleValue
        XCTAssertEqual(level, 75.5)
    }

    func testEncodeInt() throws {
        let ac = AnyCodable(42)
        let data = try JSONEncoder().encode(ac)
        let str = String(data: data, encoding: .utf8)
        XCTAssertEqual(str, "42")
    }

    func testEncodeString() throws {
        let ac = AnyCodable("test")
        let data = try JSONEncoder().encode(ac)
        let str = String(data: data, encoding: .utf8)
        XCTAssertEqual(str, "\"test\"")
    }

    func testEncodeNull() throws {
        let ac = AnyCodable(NSNull())
        let data = try JSONEncoder().encode(ac)
        let str = String(data: data, encoding: .utf8)
        XCTAssertEqual(str, "null")
    }

    // MARK: - Href parsing via nested dict

    func testNestedHrefParsing() throws {
        let json = Data("""
        {"AssociatedArea": {"href": "/area/5"}}
        """.utf8)
        let dict = try JSONDecoder().decode([String: AnyCodable].self, from: json)
        let href = dict["AssociatedArea"]?.dictValue?["href"]?.stringValue
        XCTAssertEqual(href, "/area/5")
    }
}
