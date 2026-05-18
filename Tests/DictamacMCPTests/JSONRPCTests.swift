import Foundation
import Testing
@testable import DictamacMCP

/// Codable round-trips and envelope-shape assertions for the JSON-RPC
/// 2.0 types. The transport layer's correctness rests on these shapes
/// staying byte-stable, so every assertion is exact.
struct JSONRPCTests {

    // MARK: - JSONRPCID

    @Test func idDecodesFromInteger() throws {
        let id = try JSONDecoder().decode(JSONRPCID.self, from: "7".data(using: .utf8)!)
        #expect(id == .int(7))
    }

    @Test func idDecodesFromString() throws {
        let id = try JSONDecoder().decode(JSONRPCID.self, from: "\"abc\"".data(using: .utf8)!)
        #expect(id == .string("abc"))
    }

    @Test func idEncodesPreservingType() throws {
        let intEncoded = try JSONEncoder().encode(JSONRPCID.int(5))
        let strEncoded = try JSONEncoder().encode(JSONRPCID.string("xyz"))
        #expect(String(data: intEncoded, encoding: .utf8) == "5")
        #expect(String(data: strEncoded, encoding: .utf8) == "\"xyz\"")
    }

    // MARK: - JSONRPCRequest

    @Test func requestDecodesFullEnvelope() throws {
        let line = """
        {"jsonrpc":"2.0","id":1,"method":"foo","params":{"x":1}}
        """.data(using: .utf8)!

        let request = try JSONDecoder().decode(JSONRPCRequest.self, from: line)
        #expect(request.jsonrpc == "2.0")
        #expect(request.id == .int(1))
        #expect(request.method == "foo")
        #expect(request.params == .object(["x": .int(1)]))
    }

    @Test func requestDecodesAsNotificationWithoutId() throws {
        let line = """
        {"jsonrpc":"2.0","method":"ping"}
        """.data(using: .utf8)!

        let request = try JSONDecoder().decode(JSONRPCRequest.self, from: line)
        #expect(request.id == nil, "missing id field must decode as a nil id (notification)")
        #expect(request.method == "ping")
        #expect(request.params == nil)
    }

    @Test func requestWithStringIdRoundTrips() throws {
        let line = """
        {"jsonrpc":"2.0","id":"req-1","method":"foo"}
        """.data(using: .utf8)!

        let request = try JSONDecoder().decode(JSONRPCRequest.self, from: line)
        #expect(request.id == .string("req-1"))
    }

    // MARK: - JSONRPCResponse

    @Test func successResponseSerializesWithResultAndNoError() throws {
        let response = JSONRPCResponse.success(id: .int(1), result: .string("ok"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(response)
        let asString = String(data: data, encoding: .utf8) ?? ""
        #expect(asString == #"{"id":1,"jsonrpc":"2.0","result":"ok"}"#)
    }

    @Test func failureResponseSerializesWithErrorAndNoResult() throws {
        let response = JSONRPCResponse.failure(
            id: .int(2),
            error: .methodNotFound("Method not found: nope")
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(response)
        let asString = String(data: data, encoding: .utf8) ?? ""
        #expect(asString == #"{"error":{"code":-32601,"message":"Method not found: nope"},"id":2,"jsonrpc":"2.0"}"#)
    }

    @Test func parseErrorResponseEmitsExplicitNullId() throws {
        // Spec §5.1: when the id can't be recovered (parse error),
        // the response MUST have `"id": null`, not a missing key.
        let response = JSONRPCResponse.failure(id: nil, error: .parseError())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(response)
        let asString = String(data: data, encoding: .utf8) ?? ""
        #expect(asString.contains(#""id":null"#))
        #expect(asString.contains(#""code":-32700"#))
    }

    // MARK: - JSONRPCError canonical codes

    @Test func canonicalErrorsCarryReservedCodes() {
        #expect(JSONRPCError.parseError().code == -32700)
        #expect(JSONRPCError.invalidRequest().code == -32600)
        #expect(JSONRPCError.methodNotFound().code == -32601)
        #expect(JSONRPCError.invalidParams().code == -32602)
        #expect(JSONRPCError.internalError().code == -32603)
    }

    @Test func errorEncodesDataFieldWhenPresent() throws {
        let error = JSONRPCError(code: -32000, message: "boom", data: .string("details"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(error)
        let asString = String(data: data, encoding: .utf8) ?? ""
        #expect(asString == #"{"code":-32000,"data":"details","message":"boom"}"#)
    }
}
