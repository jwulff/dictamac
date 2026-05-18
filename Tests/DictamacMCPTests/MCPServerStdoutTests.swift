import Foundation
import Testing
@testable import DictamacMCP

/// Stdout-discipline tests for the MCP transport.
///
/// The single most load-bearing property of an MCP stdio server is
/// that **stdout carries JSON-RPC envelopes and nothing else**. A
/// stray diagnostic write to stdout would corrupt the channel for the
/// agent on the other side. These tests run the server through
/// scenarios that historically tempt implementations to leak (parse
/// errors, internal exceptions, unknown methods, handler throws) and
/// assert every line on stdout decodes as a valid JSON-RPC response.
struct MCPServerStdoutTests {

    /// Run a single scenario: send the given lines, close stdin,
    /// drain stdout, and parse every line as JSON-RPC. Returns the
    /// parsed responses for further per-test assertions.
    private func runScenario(
        register: ((MCPServer) async -> Void)? = nil,
        lines: [String]
    ) async throws -> [JSONRPCResponse] {
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        let server = MCPServer(
            input: stdinPipe.fileHandleForReading,
            output: stdoutPipe.fileHandleForWriting,
            errorOutput: stderrPipe.fileHandleForWriting
        )

        if let register {
            await register(server)
        }

        for line in lines {
            try stdinPipe.fileHandleForWriting.write(
                contentsOf: Data((line + "\n").utf8)
            )
        }
        try stdinPipe.fileHandleForWriting.close()

        await server.serve()

        try stdoutPipe.fileHandleForWriting.close()
        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()

        try stderrPipe.fileHandleForWriting.close()
        // Drain stderr to avoid backpressure on the pipe, but ignore
        // contents here — the dedicated test below asserts emptiness.
        _ = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let outputString = String(decoding: outputData, as: UTF8.self)

        // Every non-empty line MUST parse as a JSON-RPC response.
        // If it doesn't, the channel has been poisoned.
        let lines = outputString
            .split(separator: "\n", omittingEmptySubsequences: true)
        let decoder = JSONDecoder()
        var responses: [JSONRPCResponse] = []
        for line in lines {
            let response = try decoder.decode(
                JSONRPCResponse.self,
                from: Data(line.utf8)
            )
            responses.append(response)
        }
        return responses
    }

    @Test func stdoutContainsOnlyJSONRPCResponsesAcrossMixedTraffic() async throws {
        // A messy session that mixes well-formed requests, an
        // unknown method, a handler that throws invalid-params, and a
        // malformed JSON line. Each scenario tempts an
        // implementation to write something diagnostic to stdout —
        // any such leak would break this test.
        let responses = try await runScenario(
            register: { server in
                await server.register(method: "good") { _ in .string("ok") }
                await server.register(method: "bad") { _ in
                    throw MCPProtocolError.invalidParams("nope")
                }
            },
            lines: [
                #"{"jsonrpc":"2.0","id":1,"method":"good"}"#,
                #"{"jsonrpc":"2.0","id":2,"method":"unknown"}"#,
                #"{"jsonrpc":"2.0","id":3,"method":"bad"}"#,
                #"this line is not json"#,
                #"{"jsonrpc":"2.0","id":4,"method":"good"}"#,
            ]
        )

        // Five envelopes in, five envelopes out — every line parsed.
        #expect(responses.count == 5)
        #expect(responses[0].id == .int(1))
        #expect(responses[0].result == .string("ok"))
        #expect(responses[1].id == .int(2))
        #expect(responses[1].error?.code == -32601)
        #expect(responses[2].id == .int(3))
        #expect(responses[2].error?.code == -32602)
        #expect(responses[3].id == nil)
        #expect(responses[3].error?.code == -32700)
        #expect(responses[4].id == .int(4))
        #expect(responses[4].result == .string("ok"))
    }

    @Test func stderrStaysSilentOnNormalTraffic() async throws {
        // Mirror of the above but assert stderr emptiness explicitly.
        // The server only writes to stderr on transport-level
        // failures (encoding bugs, I/O errors) — none of which the
        // normal happy + protocol-error paths should trigger.
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        let server = MCPServer(
            input: stdinPipe.fileHandleForReading,
            output: stdoutPipe.fileHandleForWriting,
            errorOutput: stderrPipe.fileHandleForWriting
        )
        await server.register(method: "echo") { params in params ?? .null }

        try stdinPipe.fileHandleForWriting.write(
            contentsOf: Data((#"{"jsonrpc":"2.0","id":1,"method":"echo"}"# + "\n").utf8)
        )
        try stdinPipe.fileHandleForWriting.write(
            contentsOf: Data((#"{"jsonrpc":"2.0","method":"echo"}"# + "\n").utf8)  // notification
        )
        try stdinPipe.fileHandleForWriting.write(
            contentsOf: Data((#"{"jsonrpc":"2.0","id":2,"method":"unknown"}"# + "\n").utf8)
        )
        try stdinPipe.fileHandleForWriting.write(
            contentsOf: Data("not json\n".utf8)  // -32700 path
        )
        try stdinPipe.fileHandleForWriting.close()

        await server.serve()

        try stdoutPipe.fileHandleForWriting.close()
        try stderrPipe.fileHandleForWriting.close()
        _ = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        #expect(stderr.isEmpty, "no diagnostic output on the happy + protocol-error paths")
    }
}
