import Foundation
import Testing
@testable import DictamacMCP

/// End-to-end tests for the JSON-RPC stdio read loop.
///
/// Every test wires the server to a triple of `Pipe()`s — one for
/// stdin, one for stdout, one for stderr — so the dispatch loop runs
/// against real pipes without forking a subprocess. The setup mirrors
/// what `dictamac --mcp` does in production except the handles are
/// pipes instead of `FileHandle.standard*`.
///
/// The "stdout is JSON-RPC only" invariant is the single most
/// load-bearing property of the MCP transport — `MCPServerStdoutTests`
/// covers it explicitly.
struct MCPServerTests {

    // MARK: - Helpers

    /// Pipe-backed harness: feed the server bytes via `inputWrite`,
    /// read its responses from `outputRead`, and inspect diagnostics
    /// via `errorRead`. The two writer ends close from the test side
    /// to signal EOF to the server.
    private struct Harness {
        let server: MCPServer

        let inputWrite: FileHandle
        let outputRead: FileHandle
        let errorRead: FileHandle

        private let outputWrite: FileHandle
        private let errorWrite: FileHandle

        init() {
            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            self.inputWrite = stdinPipe.fileHandleForWriting
            self.outputRead = stdoutPipe.fileHandleForReading
            self.errorRead = stderrPipe.fileHandleForReading
            self.outputWrite = stdoutPipe.fileHandleForWriting
            self.errorWrite = stderrPipe.fileHandleForWriting

            self.server = MCPServer(
                input: stdinPipe.fileHandleForReading,
                output: outputWrite,
                errorOutput: errorWrite
            )
        }

        /// Send a JSON-RPC line (caller need not include the trailing
        /// newline — the harness adds it).
        func send(_ line: String) throws {
            try inputWrite.write(contentsOf: Data((line + "\n").utf8))
        }

        /// Signal EOF on stdin. The server's read loop returns after
        /// draining whatever was already buffered.
        func closeInput() throws {
            try inputWrite.close()
        }

        /// Drain everything the server wrote to stdout, blocking until
        /// the server-side writer is also closed (which happens when
        /// `runToEOF()` completes and tears down its end).
        func readAllStdout() throws -> String {
            try outputWrite.close()
            let data = outputRead.readDataToEndOfFile()
            return String(decoding: data, as: UTF8.self)
        }

        func readAllStderr() throws -> String {
            try errorWrite.close()
            let data = errorRead.readDataToEndOfFile()
            return String(decoding: data, as: UTF8.self)
        }

        /// Run the server to EOF on its own task. Returns once the
        /// loop finishes, at which point stdout/stderr can be drained
        /// without risk of deadlock.
        func runToEOF() async {
            await server.serve()
        }
    }

    // MARK: - Tests

    @Test func dispatchesRegisteredHandlerAndWritesSuccessResponse() async throws {
        let harness = Harness()
        await harness.server.register(method: "echo") { params in
            // Echo the params back as the result — the handler is
            // intentionally trivial; this test is about the wire.
            return params ?? .null
        }

        try harness.send(#"{"jsonrpc":"2.0","id":1,"method":"echo","params":{"hello":"world"}}"#)
        try harness.closeInput()

        await harness.runToEOF()

        let stdout = try harness.readAllStdout()
        #expect(stdout.hasSuffix("\n"), "responses must be \\n-terminated")
        let lines = stdout.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
        #expect(lines.count == 1, "one request → one response line")

        // Decode the response from the wire and assert shape.
        let response = try JSONDecoder().decode(
            JSONRPCResponse.self,
            from: Data(lines[0].utf8)
        )
        #expect(response.id == .int(1))
        #expect(response.error == nil)
        #expect(response.result == .object(["hello": .string("world")]))
    }

    @Test func unknownMethodReturnsMethodNotFound() async throws {
        let harness = Harness()
        // No handlers registered — every method call must come back
        // as -32601.

        try harness.send(#"{"jsonrpc":"2.0","id":42,"method":"nope"}"#)
        try harness.closeInput()

        await harness.runToEOF()

        let stdout = try harness.readAllStdout()
        let response = try JSONDecoder().decode(
            JSONRPCResponse.self,
            from: Data(stdout.trimmingCharacters(in: .newlines).utf8)
        )
        #expect(response.id == .int(42), "id must be preserved on the error response")
        #expect(response.error?.code == -32601)
        #expect(response.error?.message.contains("Method not found") == true)
        #expect(response.result == nil)
    }

    @Test func invalidParamsHandlerThrowsBecomesInvalidParamsError() async throws {
        let harness = Harness()
        await harness.server.register(method: "strict") { _ in
            throw MCPProtocolError.invalidParams("missing required field 'path'")
        }

        try harness.send(#"{"jsonrpc":"2.0","id":"req-1","method":"strict","params":{}}"#)
        try harness.closeInput()

        await harness.runToEOF()

        let stdout = try harness.readAllStdout()
        let response = try JSONDecoder().decode(
            JSONRPCResponse.self,
            from: Data(stdout.trimmingCharacters(in: .newlines).utf8)
        )
        #expect(response.id == .string("req-1"))
        #expect(response.error?.code == -32602)
        #expect(response.error?.message == "missing required field 'path'")
    }

    @Test func malformedJSONLineReturnsParseErrorWithNullId() async throws {
        let harness = Harness()

        // A truly malformed line — unmatched brace.
        try harness.send("{not json")
        try harness.closeInput()

        await harness.runToEOF()

        let stdout = try harness.readAllStdout()
        let line = stdout.trimmingCharacters(in: .newlines)

        // The parse-error response must carry `"id": null` literally,
        // not omit the key. Assert on the raw bytes so we don't lose
        // that detail through a permissive decoder.
        #expect(line.contains(#""id":null"#))
        #expect(line.contains(#""code":-32700"#))
    }

    @Test func notificationDoesNotProduceResponse() async throws {
        let harness = Harness()
        let received = HandlerCallRecorder()
        await harness.server.register(method: "notify") { params in
            await received.record(params)
            return .null  // ignored: response will not be written
        }

        // No `id` field → notification per JSON-RPC 2.0 spec §4.1.
        try harness.send(#"{"jsonrpc":"2.0","method":"notify","params":["x"]}"#)
        try harness.closeInput()

        await harness.runToEOF()

        let stdout = try harness.readAllStdout()
        #expect(stdout.isEmpty, "notifications produce NO response on stdout")

        // The handler must still have executed — the recorder proves
        // notifications aren't silently dropped just because they
        // don't get a reply.
        let calls = await received.calls
        #expect(calls.count == 1)
        #expect(calls.first == .array([.string("x")]))
    }

    @Test func unknownNotificationMethodIsSilentlyDropped() async throws {
        let harness = Harness()
        // Don't register any handler. A notification to an unknown
        // method must produce neither a response (it's a notification)
        // nor a method-not-found error (the spec forbids replying to
        // notifications).

        try harness.send(#"{"jsonrpc":"2.0","method":"never-registered"}"#)
        try harness.closeInput()

        await harness.runToEOF()

        let stdout = try harness.readAllStdout()
        #expect(stdout.isEmpty)
    }

    @Test func multipleRequestsEachProduceOneLine() async throws {
        let harness = Harness()
        await harness.server.register(method: "count") { params in
            // Return params verbatim so we can match request → response.
            return params ?? .null
        }

        try harness.send(#"{"jsonrpc":"2.0","id":1,"method":"count","params":1}"#)
        try harness.send(#"{"jsonrpc":"2.0","id":2,"method":"count","params":2}"#)
        try harness.send(#"{"jsonrpc":"2.0","id":3,"method":"count","params":3}"#)
        try harness.closeInput()

        await harness.runToEOF()

        let stdout = try harness.readAllStdout()
        let lines = stdout.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 3, "three requests → three response lines")

        // Decode each response and check id preservation and ordering.
        let responses = try lines.map { line in
            try JSONDecoder().decode(JSONRPCResponse.self, from: Data(line.utf8))
        }
        #expect(responses.map(\.id) == [.int(1), .int(2), .int(3)])
        #expect(responses.compactMap { $0.result } == [.int(1), .int(2), .int(3)])
    }

    @Test func serverReturnsCleanlyOnEOFWithNoTrailingNewline() async throws {
        // A request without a trailing newline should still get a
        // response if EOF then arrives — otherwise an agent that
        // forgot the framing byte would hang silently.
        let harness = Harness()
        await harness.server.register(method: "ping") { _ in .string("pong") }

        try harness.inputWrite.write(
            contentsOf: Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
        )
        try harness.closeInput()

        await harness.runToEOF()

        let stdout = try harness.readAllStdout()
        let line = stdout.trimmingCharacters(in: .newlines)
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: Data(line.utf8))
        #expect(response.id == .int(1))
        #expect(response.result == .string("pong"))
    }

    @Test func serverExitsImmediatelyOnEmptyInputAtEOF() async throws {
        // No traffic at all — just EOF. The loop must terminate
        // cleanly with no output on either channel.
        let harness = Harness()
        try harness.closeInput()

        await harness.runToEOF()

        let stdout = try harness.readAllStdout()
        let stderr = try harness.readAllStderr()
        #expect(stdout.isEmpty)
        #expect(stderr.isEmpty)
    }
}

/// Actor-backed call recorder mirroring the pattern in
/// `Tests/DictamacCLITests/ModeDispatchTests.swift`. Used to assert
/// notification semantics — the handler MUST run, but the response
/// MUST NOT be written.
actor HandlerCallRecorder {
    private(set) var calls: [JSONValue?] = []
    func record(_ value: JSONValue?) { calls.append(value) }
}
