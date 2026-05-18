import Foundation
import Testing
@testable import DictamacMCP
@testable import DictamacCore

/// Tests for the MCP `initialize` handler — the first method any
/// client calls in the handshake.
///
/// The handler returns three load-bearing things:
///
/// 1. **Server identity** (`name`, `version`, `vendor`) — pins the
///    binary's contract with the client.
/// 2. **Capabilities** — ONLY `tools: {}`. No resources, no prompts, no
///    sampling. These tests assert *negative space* (i.e. the absence
///    of the other capability keys) explicitly so a future agent that
///    bolts on a `resources` capability has to update the assertions.
/// 3. **`protocolVersion`** — pinned to the ``mcpProtocolVersion``
///    constant. A separate drift test asserts the literal string value
///    so updating the constant is a deliberate, reviewable act.
struct InitializeHandlerTests {

    // MARK: - Pinned version (drift guard)

    @Test func pinnedProtocolVersionMatchesExpectedConstant() {
        // The single most important property of the handshake: the
        // version string is pinned in *one* place. Bumping it requires
        // editing this assertion as well, which makes the bump
        // deliberate.
        #expect(mcpProtocolVersion == "2025-06-18")
    }

    // MARK: - Result envelope

    @Test func initializeResultIncludesPinnedProtocolVersion() async throws {
        let result = try await ProductionMCPHandlers.initialize(params: nil)

        guard case .object(let object) = result else {
            Issue.record("initialize result must be a JSON object; got \(result)")
            return
        }
        #expect(object["protocolVersion"] == .string(mcpProtocolVersion))
    }

    @Test func initializeResultDeclaresOnlyToolsCapability() async throws {
        let result = try await ProductionMCPHandlers.initialize(params: nil)

        guard case .object(let object) = result,
              case .object(let capabilities) = object["capabilities"] else {
            Issue.record("initialize result missing capabilities object")
            return
        }

        // The MCP capability surface is enumerated explicitly to keep
        // this server honest. `tools` is the ONLY key. Any future agent
        // adding a `resources` / `prompts` / `sampling` capability must
        // update both the handler and this test deliberately.
        #expect(capabilities.keys.sorted() == ["tools"])
        #expect(capabilities["tools"] == .object([:]))
        #expect(capabilities["resources"] == nil)
        #expect(capabilities["prompts"] == nil)
        #expect(capabilities["sampling"] == nil)
        #expect(capabilities["logging"] == nil)
    }

    @Test func initializeResultIncludesServerIdentity() async throws {
        let result = try await ProductionMCPHandlers.initialize(params: nil)

        guard case .object(let object) = result,
              case .object(let serverInfo) = object["serverInfo"] else {
            Issue.record("initialize result missing serverInfo object")
            return
        }
        #expect(serverInfo["name"] == .string("dictamac"))
        // Version comes from the embedded Info.plist via
        // `DictamacVersion.current`; asserting against the constant
        // (rather than a literal) keeps this test future-proof across
        // version bumps. See `Sources/DictamacCore/DictamacVersion.swift`.
        #expect(serverInfo["version"] == .string(DictamacVersion.current))
        #expect(serverInfo["vendor"] == .string("jwulff"))
    }

    @Test func initializeIgnoresIncomingParams() async throws {
        // The client's `initialize` params can carry the client's own
        // protocolVersion + capabilities. We don't negotiate today —
        // the handler returns its own pinned identity regardless.
        // Verifying this means the same handler can be wired to either
        // an `.absent` or a populated params object without crashing.
        let clientInfo: [String: JSONValue] = [
            "name": .string("test-client"),
            "version": .string("0.1.0"),
        ]
        let paramsDict: [String: JSONValue] = [
            "protocolVersion": .string("1999-01-01"),
            "capabilities": .object([:]),
            "clientInfo": .object(clientInfo),
        ]
        let result = try await ProductionMCPHandlers.initialize(
            params: .object(paramsDict)
        )

        guard case .object(let object) = result else {
            Issue.record("initialize result must be a JSON object")
            return
        }
        #expect(object["protocolVersion"] == .string(mcpProtocolVersion))
    }

    // MARK: - End-to-end through MCPServer

    @Test func initializeRegisteredOnServerProducesExpectedEnvelope() async throws {
        // The handler is exercised through the actual transport so we
        // know wire-side serialization (sortedKeys, withoutEscapingSlashes,
        // `\n` framing) is exercised too.
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        let server = MCPServer(
            input: stdinPipe.fileHandleForReading,
            output: stdoutPipe.fileHandleForWriting,
            errorOutput: stderrPipe.fileHandleForWriting
        )
        await ProductionMCPHandlers.register(on: server)

        try stdinPipe.fileHandleForWriting.write(
            contentsOf: Data((#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"# + "\n").utf8)
        )
        try stdinPipe.fileHandleForWriting.close()

        await server.serve()

        try stdoutPipe.fileHandleForWriting.close()
        try stderrPipe.fileHandleForWriting.close()
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        #expect(stderr.isEmpty, "initialize handler must not write to stderr")

        let line = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .newlines)
        let response = try JSONDecoder().decode(
            JSONRPCResponse.self,
            from: Data(line.utf8)
        )
        #expect(response.id == .int(1))
        #expect(response.error == nil)

        guard case .object(let result) = response.result else {
            Issue.record("initialize result must be an object")
            return
        }
        #expect(result["protocolVersion"] == .string(mcpProtocolVersion))
        #expect(result["capabilities"] == .object(["tools": .object([:])]))
        #expect(result["serverInfo"] == .object([
            "name": .string("dictamac"),
            "version": .string(DictamacVersion.current),
            "vendor": .string("jwulff"),
        ]))
    }

    @Test func notificationsInitializedIsAcceptedAsNoOp() async throws {
        // After the initialize round-trip a well-behaved client sends
        // `notifications/initialized` (no id). The transport's
        // notification handling from #18 must keep working with our
        // handlers registered — the notification produces no response
        // on stdout and no diagnostic on stderr.
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        let server = MCPServer(
            input: stdinPipe.fileHandleForReading,
            output: stdoutPipe.fileHandleForWriting,
            errorOutput: stderrPipe.fileHandleForWriting
        )
        await ProductionMCPHandlers.register(on: server)

        // initialize, then notifications/initialized as a notification
        // (no id), then close.
        try stdinPipe.fileHandleForWriting.write(
            contentsOf: Data((#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"# + "\n").utf8)
        )
        try stdinPipe.fileHandleForWriting.write(
            contentsOf: Data((#"{"jsonrpc":"2.0","method":"notifications/initialized"}"# + "\n").utf8)
        )
        try stdinPipe.fileHandleForWriting.close()

        await server.serve()

        try stdoutPipe.fileHandleForWriting.close()
        try stderrPipe.fileHandleForWriting.close()
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        #expect(stderr.isEmpty)
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 1, "only the initialize response should hit stdout; the notification produces none")
    }
}
