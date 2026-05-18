import Foundation

/// A Codable representation of arbitrary JSON.
///
/// JSON-RPC params and results are schema-free at the transport layer —
/// each method has its own shape. To stay generic without resorting to
/// `Any` (which doesn't conform to `Codable`), the transport decodes
/// incoming params into a `JSONValue` and re-encodes outgoing results
/// from the same enum. Method handlers convert between `JSONValue` and
/// their own typed models lazily, after dispatch.
///
/// The double / int split mirrors how `JSONSerialization` distinguishes
/// integer literals from floating-point literals in JSON. Decoding tries
/// `Int` first so well-known integer ids and counts stay integral.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
            return
        }

        if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
            return
        }

        // Try Int before Double so whole-number JSON values stay
        // integral. `Double` would happily accept `42` but lose the
        // int-ness — and JSON-RPC ids are commonly integers, so we
        // want to preserve that.
        if let int = try? container.decode(Int.self) {
            self = .int(int)
            return
        }

        if let double = try? container.decode(Double.self) {
            self = .double(double)
            return
        }

        if let string = try? container.decode(String.self) {
            self = .string(string)
            return
        }

        if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
            return
        }

        if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
            return
        }

        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Value is not a recognized JSON type."
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let bool):
            try container.encode(bool)
        case .int(let int):
            try container.encode(int)
        case .double(let double):
            try container.encode(double)
        case .string(let string):
            try container.encode(string)
        case .array(let array):
            try container.encode(array)
        case .object(let object):
            try container.encode(object)
        }
    }
}
