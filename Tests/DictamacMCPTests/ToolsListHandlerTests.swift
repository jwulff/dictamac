import Foundation
import Testing
@testable import DictamacMCP

/// Tests for the MCP `tools/list` handler.
///
/// The handler advertises the three transcription tools documented in
/// `docs/PLAN.md` §5. The shape of each tool entry is a JSON Schema —
/// agents key off it to plan tool calls — so spec drift here is the
/// kind of bug that silently breaks agents downstream.
///
/// The drift guard is a snapshot test: the serialized JSON of the full
/// `tools/list` result envelope is captured in
/// `__Snapshots__/tools-list.json` and structurally compared (object
/// equality, not byte-for-byte) against the live response. Any
/// intentional schema change requires updating the snapshot, which
/// shows up in code review.
struct ToolsListHandlerTests {

    // MARK: - Structural assertions

    @Test func toolsListReturnsAllThreeTools() async throws {
        let result = try await ProductionMCPHandlers.toolsList(params: nil)

        guard case .object(let object) = result,
              case .array(let tools) = object["tools"] else {
            Issue.record("tools/list result must be {tools: [...]}; got \(result)")
            return
        }

        let names: [String] = tools.compactMap { tool in
            if case .object(let obj) = tool, case .string(let name) = obj["name"] {
                return name
            }
            return nil
        }
        #expect(names == ["transcribe_file", "transcribe_voice_memo", "list_voice_memos"])
    }

    @Test func eachToolHasNameDescriptionAndInputSchema() async throws {
        let result = try await ProductionMCPHandlers.toolsList(params: nil)

        guard case .object(let object) = result,
              case .array(let tools) = object["tools"] else {
            Issue.record("tools/list result must be {tools: [...]}")
            return
        }

        for tool in tools {
            guard case .object(let obj) = tool else {
                Issue.record("tool entry must be an object; got \(tool)")
                continue
            }
            #expect(obj["name"] != nil, "tool missing 'name'")
            #expect(obj["description"] != nil, "tool missing 'description'")
            #expect(obj["inputSchema"] != nil, "tool missing 'inputSchema'")

            // inputSchema must itself be a JSON Schema object with at
            // least `type: "object"` and a `properties` map.
            guard case .object(let schema) = obj["inputSchema"] else {
                Issue.record("inputSchema must be an object")
                continue
            }
            #expect(schema["type"] == .string("object"))
            #expect(schema["properties"] != nil)
        }
    }

    @Test func transcribeFileSchemaMatchesPlan() async throws {
        let tool = try await toolEntry(named: "transcribe_file")
        guard case .object(let obj) = tool,
              case .object(let schema) = obj["inputSchema"],
              case .object(let properties) = schema["properties"] else {
            Issue.record("transcribe_file schema malformed")
            return
        }

        // Per PLAN.md §5: required={"path"}; format enum=text|json default=text.
        #expect(schema["required"] == .array([.string("path")]))
        #expect(properties["path"] != nil)
        #expect(properties["locale"] != nil)

        guard case .object(let formatSchema) = properties["format"] else {
            Issue.record("format schema malformed")
            return
        }
        #expect(formatSchema["type"] == .string("string"))
        #expect(formatSchema["enum"] == .array([.string("text"), .string("json")]))
        #expect(formatSchema["default"] == .string("text"))
    }

    @Test func transcribeVoiceMemoSchemaMatchesPlan() async throws {
        let tool = try await toolEntry(named: "transcribe_voice_memo")
        guard case .object(let obj) = tool,
              case .object(let schema) = obj["inputSchema"],
              case .object(let properties) = schema["properties"] else {
            Issue.record("transcribe_voice_memo schema malformed")
            return
        }
        #expect(schema["required"] == .array([.string("query")]))
        #expect(properties["query"] != nil)
        #expect(properties["locale"] != nil)
        #expect(properties["format"] != nil)
    }

    @Test func listVoiceMemosSchemaIncludesLimitConstraints() async throws {
        let tool = try await toolEntry(named: "list_voice_memos")
        guard case .object(let obj) = tool,
              case .object(let schema) = obj["inputSchema"],
              case .object(let properties) = schema["properties"],
              case .object(let limit) = properties["limit"] else {
            Issue.record("list_voice_memos schema malformed")
            return
        }
        #expect(limit["type"] == .string("integer"))
        #expect(limit["minimum"] == .int(1))
        #expect(limit["maximum"] == .int(100))
        #expect(limit["default"] == .int(30))

        // No required fields — both since and limit are optional.
        #expect(schema["required"] == nil)
    }

    // MARK: - Snapshot drift guard

    @Test func toolsListMatchesGoldenSnapshot() async throws {
        // Load the golden snapshot from the test bundle.
        guard let snapshotURL = Bundle.module.url(
            forResource: "tools-list",
            withExtension: "json",
            subdirectory: "__Snapshots__"
        ) else {
            Issue.record("missing __Snapshots__/tools-list.json fixture")
            return
        }
        let snapshotData = try Data(contentsOf: snapshotURL)

        // Round-trip both sides through Codable so we compare
        // structurally (key ordering is irrelevant). The snapshot is
        // the full `result` envelope (`{tools: [...]}`), NOT the outer
        // JSON-RPC response — that envelope is exercised separately by
        // MCPServer-level tests in MCPServerTests.
        let decoder = JSONDecoder()
        let snapshot = try decoder.decode(JSONValue.self, from: snapshotData)

        let live = try await ProductionMCPHandlers.toolsList(params: nil)

        #expect(live == snapshot, """
            tools/list response drifted from __Snapshots__/tools-list.json.
            If this is an intentional spec change, update the snapshot
            file AND docs/PLAN.md §5 to match.
            """)
    }

    @Test func toolsListIgnoresIncomingParams() async throws {
        // The spec doesn't define params for `tools/list`; clients
        // sometimes still send `{}`. Either nil or an empty object
        // must produce identical results.
        let nilResult = try await ProductionMCPHandlers.toolsList(params: nil)
        let emptyResult = try await ProductionMCPHandlers.toolsList(params: .object([:]))
        #expect(nilResult == emptyResult)
    }

    // MARK: - End-to-end through MCPServer

    @Test func toolsListRegisteredOnServerProducesExpectedEnvelope() async throws {
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
            contentsOf: Data((#"{"jsonrpc":"2.0","id":7,"method":"tools/list"}"# + "\n").utf8)
        )
        try stdinPipe.fileHandleForWriting.close()

        await server.serve()

        try stdoutPipe.fileHandleForWriting.close()
        try stderrPipe.fileHandleForWriting.close()
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        #expect(stderr.isEmpty, "tools/list handler must not write to stderr")

        let line = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .newlines)
        let response = try JSONDecoder().decode(
            JSONRPCResponse.self,
            from: Data(line.utf8)
        )
        #expect(response.id == .int(7))
        #expect(response.error == nil)

        // The result must structurally equal the snapshot.
        guard let snapshotURL = Bundle.module.url(
            forResource: "tools-list",
            withExtension: "json",
            subdirectory: "__Snapshots__"
        ) else {
            Issue.record("missing snapshot")
            return
        }
        let snapshot = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(contentsOf: snapshotURL)
        )
        #expect(response.result == snapshot)
    }

    // MARK: - Helpers

    private func toolEntry(named name: String) async throws -> JSONValue {
        let result = try await ProductionMCPHandlers.toolsList(params: nil)
        guard case .object(let object) = result,
              case .array(let tools) = object["tools"] else {
            Issue.record("tools/list result malformed")
            return .null
        }
        for tool in tools {
            if case .object(let obj) = tool,
               case .string(let n) = obj["name"],
               n == name {
                return tool
            }
        }
        Issue.record("no tool named \(name) in tools/list")
        return .null
    }
}
