import Foundation
import Testing
@testable import DictamacMCP

/// Round-trip and edge-case coverage for the JSON-RPC params/result
/// carrier. Every variant must survive an encode → decode cycle so the
/// transport layer never silently mutates payloads it doesn't
/// understand.
struct JSONValueTests {

    // MARK: - Decoding from raw JSON

    @Test func decodesNull() throws {
        let json = "null".data(using: .utf8)!
        let value = try JSONDecoder().decode(JSONValue.self, from: json)
        #expect(value == .null)
    }

    @Test func decodesBool() throws {
        let trueValue = try JSONDecoder().decode(JSONValue.self, from: "true".data(using: .utf8)!)
        let falseValue = try JSONDecoder().decode(JSONValue.self, from: "false".data(using: .utf8)!)
        #expect(trueValue == .bool(true))
        #expect(falseValue == .bool(false))
    }

    @Test func decodesIntegerAsInt() throws {
        // A whole-number JSON literal must come back as `.int(_)`,
        // not `.double(_)`. JSON-RPC ids and small counts are
        // integral and we don't want them silently becoming doubles
        // somewhere in the dispatch path.
        let value = try JSONDecoder().decode(JSONValue.self, from: "42".data(using: .utf8)!)
        #expect(value == .int(42))
    }

    @Test func decodesFloatingPointAsDouble() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: "3.14".data(using: .utf8)!)
        guard case .double(let d) = value else {
            Issue.record("expected double, got \(value)")
            return
        }
        #expect(abs(d - 3.14) < 1e-9)
    }

    @Test func decodesString() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: "\"hello\"".data(using: .utf8)!)
        #expect(value == .string("hello"))
    }

    @Test func decodesArray() throws {
        let json = "[1, \"two\", true, null]".data(using: .utf8)!
        let value = try JSONDecoder().decode(JSONValue.self, from: json)
        #expect(value == .array([.int(1), .string("two"), .bool(true), .null]))
    }

    @Test func decodesNestedObject() throws {
        let json = """
        {"name": "dictamac", "count": 3, "nested": {"flag": true}}
        """.data(using: .utf8)!
        let value = try JSONDecoder().decode(JSONValue.self, from: json)
        let expected: JSONValue = .object([
            "name": .string("dictamac"),
            "count": .int(3),
            "nested": .object(["flag": .bool(true)])
        ])
        #expect(value == expected)
    }

    // MARK: - Encoding back to JSON

    @Test func encodesAndDecodesRoundTrip() throws {
        let original: JSONValue = .object([
            "id": .int(7),
            "title": .string("standup"),
            "tags": .array([.string("work"), .string("daily")]),
            "ok": .bool(true),
            "ratio": .double(0.5),
            "extra": .null
        ])

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: encoded)
        #expect(decoded == original)
    }

    @Test func encodesNullExplicitly() throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(JSONValue.null)
        let asString = String(data: data, encoding: .utf8)
        #expect(asString == "null")
    }
}
