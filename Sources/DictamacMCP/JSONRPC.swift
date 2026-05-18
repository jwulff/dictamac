import Foundation

/// JSON-RPC 2.0 request identifier.
///
/// The spec permits a `String`, `Number`, or `null` for the `id` field.
/// This enum only carries the *present, non-null* shapes (`string` /
/// `int`); the "absent" and "explicit null" cases are modelled
/// separately on a request by ``JSONRPCIDField`` and on a response by
/// `JSONRPCResponse.id == nil`.
public enum JSONRPCID: Hashable, Sendable {
    case string(String)
    case int(Int)
}

extension JSONRPCID: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) {
            self = .int(int)
            return
        }
        if let string = try? container.decode(String.self) {
            self = .string(string)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "JSON-RPC id must be a string or integer."
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        }
    }
}

/// Three-state representation of the `id` field on a JSON-RPC request.
///
/// The spec (§4.1, §4.2) treats these as semantically distinct cases:
///
/// - ``absent`` — the `id` key is missing from the JSON object. This is
///   a *notification*: the server MUST NOT produce a response, even on
///   unknown methods or errors.
/// - ``null`` — the `id` key is present with the literal value `null`.
///   This is still a *request*: the server MUST produce a response, and
///   that response MUST echo `"id": null`. Clients are discouraged from
///   using null ids in practice (§4.2) but the spec requires servers to
///   handle them correctly.
/// - ``value(_:)`` — the `id` key is present with a string or integer
///   value. Normal request: server responds with the same id echoed
///   back.
///
/// Collapsing ``absent`` and ``null`` together — as a plain `JSONRPCID?`
/// would — produces a spec violation: a client sending `"id": null` to
/// invoke a method would hang waiting for a response that never comes.
public enum JSONRPCIDField: Hashable, Sendable {
    case absent
    case null
    case value(JSONRPCID)

    /// True iff this represents a notification (absent id) per
    /// JSON-RPC 2.0 §4.1. Notifications must not be answered.
    public var isNotification: Bool {
        if case .absent = self { return true }
        return false
    }

    /// Convert the three-state request id into the two-state response
    /// id (`JSONRPCID?`), where `nil` encodes as JSON `null`.
    ///
    /// This is meaningful only when the caller has already decided a
    /// response will be written — i.e. the id was not ``absent``. For
    /// notifications (``absent``) the dispatcher must skip writing a
    /// response entirely; this method maps the field to `nil` in that
    /// case too, but the dispatcher should never consult it then.
    public var responseID: JSONRPCID? {
        switch self {
        case .absent, .null:
            return nil
        case .value(let id):
            return id
        }
    }
}

/// A single JSON-RPC 2.0 request envelope.
///
/// `id` is a three-state ``JSONRPCIDField`` rather than a plain
/// `JSONRPCID?`: the spec assigns distinct meanings to "key absent"
/// (notification — no response), "key present and null" (request with
/// null id — response MUST echo `"id": null`), and "key present with
/// string/int value" (normal request). Collapsing the first two into a
/// single `nil` would cause the server to drop responses to valid
/// requests whose client chose to send `"id": null`.
///
/// `params` is a `JSONValue?` rather than a typed model — the transport
/// doesn't know the per-method param shape, so the handler decodes it
/// lazily.
public struct JSONRPCRequest: Decodable, Sendable, Equatable {
    public let jsonrpc: String
    public let id: JSONRPCIDField
    public let method: String
    public let params: JSONValue?

    public init(
        jsonrpc: String = "2.0",
        id: JSONRPCIDField = .absent,
        method: String,
        params: JSONValue? = nil
    ) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.method = method
        self.params = params
    }

    /// Decoding distinguishes the three id states by inspecting the
    /// container directly: ``KeyedDecodingContainer/contains(_:)`` tells
    /// us "key absent", ``KeyedDecodingContainer/decodeNil(forKey:)``
    /// tells us "key present and null", and anything else falls through
    /// to a normal ``JSONRPCID`` decode. This is the only place in the
    /// transport that needs to make that distinction; once the request
    /// is constructed the dispatcher reads the typed field directly.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.jsonrpc = try container.decodeIfPresent(String.self, forKey: .jsonrpc) ?? "2.0"
        self.method = try container.decode(String.self, forKey: .method)
        self.params = try container.decodeIfPresent(JSONValue.self, forKey: .params)

        if container.contains(.id) {
            if try container.decodeNil(forKey: .id) {
                self.id = .null
            } else {
                self.id = .value(try container.decode(JSONRPCID.self, forKey: .id))
            }
        } else {
            self.id = .absent
        }
    }

    private enum CodingKeys: String, CodingKey {
        case jsonrpc, id, method, params
    }
}

/// A single JSON-RPC 2.0 response envelope.
///
/// Per spec §5: `result` and `error` are mutually exclusive — exactly
/// one must be present in a valid response. The transport enforces this
/// at the construction sites
/// (``JSONRPCResponse/success(id:result:)`` /
/// ``JSONRPCResponse/failure(id:error:)``) so handlers never assemble a
/// response object directly.
///
/// `id` is optional because of the `-32700 Parse error` case: when a
/// line fails to decode as JSON, there is no original id to echo back
/// and the spec requires emitting `"id": null` in the response.
public struct JSONRPCResponse: Codable, Sendable, Equatable {
    public let jsonrpc: String
    public let id: JSONRPCID?
    public let result: JSONValue?
    public let error: JSONRPCError?

    private init(id: JSONRPCID?, result: JSONValue?, error: JSONRPCError?) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = error
    }

    /// Build a success response. `result` may be `JSONValue.null` for
    /// methods that conventionally return no payload.
    public static func success(id: JSONRPCID?, result: JSONValue) -> JSONRPCResponse {
        JSONRPCResponse(id: id, result: result, error: nil)
    }

    /// Build a failure response. The `id` is `nil` only when we never
    /// successfully decoded the original request (the `-32700 Parse
    /// error` path).
    public static func failure(id: JSONRPCID?, error: JSONRPCError) -> JSONRPCResponse {
        JSONRPCResponse(id: id, result: nil, error: error)
    }

    /// Decoding is symmetric with ``encode(to:)``: a missing `id` is
    /// treated identically to `"id": null`. `result` / `error` are
    /// both optional; one or the other will be present on a valid
    /// JSON-RPC response, but we don't enforce that invariant at the
    /// decoder so test harnesses can decode partial fixtures.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.jsonrpc = try container.decodeIfPresent(String.self, forKey: .jsonrpc) ?? "2.0"
        if container.contains(.id), try !container.decodeNil(forKey: .id) {
            self.id = try container.decode(JSONRPCID.self, forKey: .id)
        } else {
            self.id = nil
        }
        self.result = try container.decodeIfPresent(JSONValue.self, forKey: .result)
        self.error = try container.decodeIfPresent(JSONRPCError.self, forKey: .error)
    }

    /// Encoding rule: `result` and `error` are mutually exclusive, so
    /// we emit whichever is present (and never both). `id` is encoded
    /// as JSON `null` rather than omitted when the response has no
    /// originating id — that is the shape the spec asks for in parse-
    /// error responses.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)

        // Encode id explicitly as null when absent. `encodeIfPresent`
        // would drop the key entirely, which violates the spec for
        // parse-error responses.
        switch id {
        case .some(let value):
            try container.encode(value, forKey: .id)
        case .none:
            try container.encodeNil(forKey: .id)
        }

        if let result {
            try container.encode(result, forKey: .result)
        }
        if let error {
            try container.encode(error, forKey: .error)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case jsonrpc, id, result, error
    }
}

/// JSON-RPC 2.0 error object. Codes follow the spec's reserved ranges:
///
/// - `-32700` Parse error
/// - `-32600` Invalid request
/// - `-32601` Method not found
/// - `-32602` Invalid params
/// - `-32603` Internal error
///
/// Application-level errors should use the `-32000` to `-32099` range
/// or, in MCP's case, surface as tool-call failures with `isError: true`
/// rather than transport-level errors.
public struct JSONRPCError: Codable, Sendable, Equatable {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    // MARK: - Canonical reserved codes

    public static func parseError(_ message: String = "Parse error") -> JSONRPCError {
        JSONRPCError(code: -32700, message: message)
    }

    public static func invalidRequest(_ message: String = "Invalid Request") -> JSONRPCError {
        JSONRPCError(code: -32600, message: message)
    }

    public static func methodNotFound(_ message: String = "Method not found") -> JSONRPCError {
        JSONRPCError(code: -32601, message: message)
    }

    public static func invalidParams(_ message: String = "Invalid params") -> JSONRPCError {
        JSONRPCError(code: -32602, message: message)
    }

    public static func internalError(_ message: String = "Internal error") -> JSONRPCError {
        JSONRPCError(code: -32603, message: message)
    }
}

/// Errors that an MCP method handler can throw to be mapped onto the
/// canonical JSON-RPC reserved error codes by ``MCPServer``.
///
/// Anything else thrown by a handler becomes `-32603 Internal error`
/// with the underlying description preserved as the message — handlers
/// shouldn't leak internal types onto the wire, so we wrap.
public enum MCPProtocolError: Error, Sendable, Equatable {
    /// Maps to `-32602 Invalid params`. Use this when params decode
    /// fails, a required field is missing, or a constraint is violated
    /// (e.g. `limit` out of range).
    case invalidParams(String)
}
