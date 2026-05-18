import Foundation
import Testing
@testable import DictamacMCP
@testable import DictamacCore

/// Tests for the MCP `tools/call` dispatcher (#26).
///
/// Hard rules these tests pin (PLAN.md §5 + §7 U8/U9):
///
/// - Malformed `tools/call` invocations -> JSON-RPC `-32602`
///   (`MCPProtocolError.invalidParams`).
/// - Unknown tool name -> tool-level `isError: true` envelope, NOT
///   JSON-RPC `-32601`.
/// - Every ``DictamacError`` -> `isError: true` envelope whose text
///   matches the CLI's stderr line verbatim (parity).
/// - The MCP transport never writes a non-JSON-RPC byte to stdout
///   while executing a `tools/call`.
struct ToolsCallTests {

    // MARK: - Fixture helpers

    /// Build a handler with stub deps that return a canned transcript.
    private func makeHandler(
        transcript: Transcript = TranscriptFixture.canned(),
        transcriberError: (any Error)? = nil,
        resolverError: (any Error)? = nil,
        resolvedURL: URL = URL(fileURLWithPath: "/tmp/dictamac-test.m4a")
    ) -> (MCPToolsCallHandler, MockTranscriber, MockAudioFileResolver) {
        let transcriber = MockTranscriber(
            transcriptToReturn: transcript,
            errorToThrow: transcriberError
        )
        let resolver = MockAudioFileResolver(
            resolvedURL: resolvedURL,
            errorToThrow: resolverError
        )
        let handler = MCPToolsCallHandler(
            transcriber: transcriber,
            audioResolver: resolver
        )
        return (handler, transcriber, resolver)
    }

    /// Decode a tool-call envelope into its `(isError, [text...])`
    /// shape so individual assertions stay readable.
    private func unwrapEnvelope(
        _ result: JSONValue
    ) -> (isError: Bool, texts: [String])? {
        guard case .object(let object) = result,
              case .array(let content) = object["content"] else {
            return nil
        }
        let isError: Bool
        if case .bool(let value) = object["isError"] ?? .null {
            isError = value
        } else {
            isError = false
        }
        var texts: [String] = []
        for item in content {
            guard case .object(let dict) = item,
                  case .string("text") = dict["type"] ?? .null,
                  case .string(let text) = dict["text"] ?? .null else {
                return nil
            }
            texts.append(text)
        }
        return (isError, texts)
    }

    // MARK: - transcribe_file happy paths

    @Test func transcribeFileReturnsPlaintextContentByDefault() async throws {
        let transcript = TranscriptFixture.canned(
            text: "Hello, world, this is a test."
        )
        let (handler, transcriber, resolver) = makeHandler(transcript: transcript)

        let result = try await handler.handle(params: .object([
            "name": .string("transcribe_file"),
            "arguments": .object([
                "path": .string("/absolute/path/to/audio.m4a"),
            ]),
        ]))

        guard let envelope = unwrapEnvelope(result) else {
            Issue.record("malformed tool-call envelope: \(result)")
            return
        }
        #expect(envelope.isError == false)
        #expect(envelope.texts == ["Hello, world, this is a test.\n"])

        // Side effects: the resolver saw the path, the transcriber saw
        // the resolved URL, the resolver's cleanup hook ran.
        let sources = await resolver.receivedSources
        #expect(sources == [.path("/absolute/path/to/audio.m4a")])
        let requests = await transcriber.receivedRequests
        #expect(requests.count == 1)
        guard case .file(let url) = requests.first?.source else {
            Issue.record("transcriber received non-.file source")
            return
        }
        #expect(url.path == "/tmp/dictamac-test.m4a")
        #expect(requests.first?.format == .text)
    }

    @Test func transcribeFileReturnsJSONContentWhenFormatIsJson() async throws {
        let transcript = TranscriptFixture.canned(text: "x")
        let (handler, _, _) = makeHandler(transcript: transcript)

        let result = try await handler.handle(params: .object([
            "name": .string("transcribe_file"),
            "arguments": .object([
                "path": .string("/absolute/path/to/audio.m4a"),
                "format": .string("json"),
            ]),
        ]))

        guard let envelope = unwrapEnvelope(result),
              let text = envelope.texts.first else {
            Issue.record("envelope missing or wrong shape: \(result)")
            return
        }
        #expect(envelope.isError == false)
        // JSON content text should contain the v1 schema shape.
        #expect(text.contains("\"version\""))
        #expect(text.contains("\"fullText\""))
        #expect(text.contains("\"segments\""))
    }

    @Test func transcribeFileForwardsLocaleArgument() async throws {
        let (handler, transcriber, _) = makeHandler()

        _ = try await handler.handle(params: .object([
            "name": .string("transcribe_file"),
            "arguments": .object([
                "path": .string("/absolute/path/to/audio.m4a"),
                "locale": .string("fr-FR"),
            ]),
        ]))

        let requests = await transcriber.receivedRequests
        #expect(requests.first?.locale.identifier == "fr-FR")
    }

    // MARK: - transcribe_file -32602 paths

    @Test func transcribeFileMissingPathRaisesInvalidParams() async throws {
        let (handler, _, _) = makeHandler()
        await #expect(throws: MCPProtocolError.self) {
            _ = try await handler.handle(params: .object([
                "name": .string("transcribe_file"),
                "arguments": .object([:]),
            ]))
        }
    }

    @Test func transcribeFileWrongPathTypeRaisesInvalidParams() async throws {
        let (handler, _, _) = makeHandler()
        await #expect(throws: MCPProtocolError.self) {
            _ = try await handler.handle(params: .object([
                "name": .string("transcribe_file"),
                "arguments": .object([
                    "path": .int(42),
                ]),
            ]))
        }
    }

    @Test func transcribeFileRelativePathRaisesInvalidParams() async throws {
        let (handler, _, _) = makeHandler()
        await #expect(throws: MCPProtocolError.self) {
            _ = try await handler.handle(params: .object([
                "name": .string("transcribe_file"),
                "arguments": .object([
                    "path": .string("relative/audio.m4a"),
                ]),
            ]))
        }
    }

    @Test func transcribeFileInvalidFormatEnumRaisesInvalidParams() async throws {
        let (handler, _, _) = makeHandler()
        await #expect(throws: MCPProtocolError.self) {
            _ = try await handler.handle(params: .object([
                "name": .string("transcribe_file"),
                "arguments": .object([
                    "path": .string("/abs/audio.m4a"),
                    "format": .string("yaml"),
                ]),
            ]))
        }
    }

    // MARK: - tools/call envelope -32602 paths

    @Test func toolsCallMissingNameRaisesInvalidParams() async throws {
        let (handler, _, _) = makeHandler()
        await #expect(throws: MCPProtocolError.self) {
            _ = try await handler.handle(params: .object([
                "arguments": .object([:]),
            ]))
        }
    }

    @Test func toolsCallNonObjectParamsRaisesInvalidParams() async throws {
        let (handler, _, _) = makeHandler()
        await #expect(throws: MCPProtocolError.self) {
            _ = try await handler.handle(params: .string("not an object"))
        }
    }

    @Test func toolsCallNilParamsRaisesInvalidParams() async throws {
        let (handler, _, _) = makeHandler()
        await #expect(throws: MCPProtocolError.self) {
            _ = try await handler.handle(params: nil)
        }
    }

    // MARK: - Unknown tool name -> isError, NOT -32601

    @Test func unknownToolNameReturnsErrorEnvelopeNotJsonRpcError() async throws {
        let (handler, _, _) = makeHandler()
        let result = try await handler.handle(params: .object([
            "name": .string("not_a_tool"),
            "arguments": .object([:]),
        ]))

        guard let envelope = unwrapEnvelope(result) else {
            Issue.record("unknown tool name must produce an isError envelope; got \(result)")
            return
        }
        #expect(envelope.isError == true)
        // The message should name the unknown tool.
        #expect(envelope.texts.first?.contains("not_a_tool") == true)
    }

    // MARK: - DictamacError -> isError envelope (parity)

    @Test func resolverFileNotFoundProducesIsErrorEnvelope() async throws {
        let missingURL = URL(fileURLWithPath: "/does/not/exist.m4a")
        let (handler, _, _) = makeHandler(
            resolverError: DictamacError.fileNotFound(missingURL)
        )

        let result = try await handler.handle(params: .object([
            "name": .string("transcribe_file"),
            "arguments": .object([
                "path": .string("/does/not/exist.m4a"),
            ]),
        ]))

        guard let envelope = unwrapEnvelope(result) else {
            Issue.record("expected envelope; got \(result)")
            return
        }
        #expect(envelope.isError == true)
        // The text must match the CLI stderr message verbatim (minus
        // the trailing newline). PLAN.md §7 U9 parity requirement.
        let expected = DictamacError.fileNotFound(missingURL).description
        #expect(envelope.texts == [expected])
    }

    @Test func transcriberSpeechAnalyzerUnavailableProducesIsErrorEnvelope() async throws {
        let underlying = DictamacError.speechAnalyzerUnavailable(
            reason: "locale model not installed"
        )
        let (handler, _, _) = makeHandler(transcriberError: underlying)

        let result = try await handler.handle(params: .object([
            "name": .string("transcribe_file"),
            "arguments": .object([
                "path": .string("/abs/audio.m4a"),
            ]),
        ]))

        guard let envelope = unwrapEnvelope(result) else {
            Issue.record("expected envelope; got \(result)")
            return
        }
        #expect(envelope.isError == true)
        #expect(envelope.texts == [underlying.description])
    }

    // MARK: - DictamacError <-> CLI stderr text parity

    /// Representative ``DictamacError`` cases from PLAN.md §7 U9.
    /// `DictamacError` is not `CaseIterable` (it carries associated
    /// values), so we enumerate the documented variants by hand here.
    /// The parity test then iterates over the list — the test fails
    /// loudly if anyone adds a new variant without thinking about the
    /// CLI/MCP text contract.
    static let representativeErrors: [DictamacError] = [
        .argumentError("bad flag"),
        .fileNotFound(URL(fileURLWithPath: "/missing.m4a")),
        .audioDecodeFailed(
            URL(fileURLWithPath: "/corrupt.m4a"),
            underlying: AudioResolverError.stdinEmpty
        ),
        .voiceMemoNotFound(query: "yesterday standup"),
        .speechAnalyzerUnavailable(reason: "locale model missing"),
        .permissionDenied(
            domain: "Speech Recognition",
            deepLink: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
        ),
        .voiceMemoLibraryMissing(searched: [
            URL(fileURLWithPath: "/Users/test/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/"),
        ]),
        .internalFailure(AudioResolverError.stdinEmpty),
    ]

    @Test func mcpToolErrorMessagesMatchCliStderrForEveryRepresentativeCase() {
        for error in Self.representativeErrors {
            let cliLine = error.formattedStderrLine
                .trimmingCharacters(in: .newlines)
            let mcpText = error.mcpToolErrorText
            #expect(
                cliLine == mcpText,
                "CLI/MCP text parity broken for \(error): CLI=\(cliLine) MCP=\(mcpText)"
            )
        }
    }

    @Test func eachRepresentativeErrorProducesAnIsErrorEnvelopeWithMatchingText() async throws {
        for error in Self.representativeErrors {
            let (handler, _, _) = makeHandler(resolverError: error)

            let result = try await handler.handle(params: .object([
                "name": .string("transcribe_file"),
                "arguments": .object([
                    "path": .string("/abs/audio.m4a"),
                ]),
            ]))

            guard let envelope = unwrapEnvelope(result) else {
                Issue.record("expected envelope for \(error); got \(result)")
                continue
            }
            #expect(envelope.isError == true)
            #expect(envelope.texts == [error.description])
        }
    }

    // MARK: - Stub paths for the two voice-memo tools

    @Test func transcribeVoiceMemoReturnsStubIsErrorEnvelopeForNow() async throws {
        let (handler, _, _) = makeHandler()
        let result = try await handler.handle(params: .object([
            "name": .string("transcribe_voice_memo"),
            "arguments": .object([
                "query": .string("yesterday"),
            ]),
        ]))

        guard let envelope = unwrapEnvelope(result) else {
            Issue.record("expected stub envelope; got \(result)")
            return
        }
        #expect(envelope.isError == true)
        // Stub must point at the follow-up issue so a future reader
        // (or agent) can find the wiring work.
        #expect(envelope.texts.first?.contains("#50") == true
                || envelope.texts.first?.contains("issues/50") == true)
    }

    @Test func transcribeVoiceMemoMissingQueryRaisesInvalidParams() async throws {
        let (handler, _, _) = makeHandler()
        await #expect(throws: MCPProtocolError.self) {
            _ = try await handler.handle(params: .object([
                "name": .string("transcribe_voice_memo"),
                "arguments": .object([:]),
            ]))
        }
    }

    @Test func transcribeVoiceMemoEmptyQueryRaisesInvalidParams() async throws {
        let (handler, _, _) = makeHandler()
        await #expect(throws: MCPProtocolError.self) {
            _ = try await handler.handle(params: .object([
                "name": .string("transcribe_voice_memo"),
                "arguments": .object([
                    "query": .string(""),
                ]),
            ]))
        }
    }

    @Test func listVoiceMemosReturnsStubIsErrorEnvelopeWithDefaults() async throws {
        let (handler, _, _) = makeHandler()
        let result = try await handler.handle(params: .object([
            "name": .string("list_voice_memos"),
            "arguments": .object([:]),
        ]))

        guard let envelope = unwrapEnvelope(result) else {
            Issue.record("expected stub envelope; got \(result)")
            return
        }
        #expect(envelope.isError == true)
        #expect(envelope.texts.first?.contains("issues/50") == true
                || envelope.texts.first?.contains("#50") == true)
    }

    @Test func listVoiceMemosWrongLimitTypeRaisesInvalidParams() async throws {
        let (handler, _, _) = makeHandler()
        await #expect(throws: MCPProtocolError.self) {
            _ = try await handler.handle(params: .object([
                "name": .string("list_voice_memos"),
                "arguments": .object([
                    "limit": .string("ten"),
                ]),
            ]))
        }
    }

    @Test func listVoiceMemosWrongSinceTypeRaisesInvalidParams() async throws {
        let (handler, _, _) = makeHandler()
        await #expect(throws: MCPProtocolError.self) {
            _ = try await handler.handle(params: .object([
                "name": .string("list_voice_memos"),
                "arguments": .object([
                    "since": .int(7),
                ]),
            ]))
        }
    }

    // MARK: - End-to-end through MCPServer (stdout discipline)

    @Test func stdoutContainsOnlyJSONRPCResponsesDuringToolsCall() async throws {
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        let server = MCPServer(
            input: stdinPipe.fileHandleForReading,
            output: stdoutPipe.fileHandleForWriting,
            errorOutput: stderrPipe.fileHandleForWriting
        )
        let transcript = TranscriptFixture.canned(text: "ok")
        let transcriber = MockTranscriber(transcriptToReturn: transcript)
        let resolver = MockAudioFileResolver()
        await ProductionMCPHandlers.register(
            on: server,
            transcriber: transcriber,
            audioResolver: resolver
        )

        let lines: [String] = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"transcribe_file","arguments":{"path":"/abs/audio.m4a"}}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"nope","arguments":{}}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"transcribe_file","arguments":{}}}"#,
        ]
        for line in lines {
            try stdinPipe.fileHandleForWriting.write(
                contentsOf: Data((line + "\n").utf8)
            )
        }
        try stdinPipe.fileHandleForWriting.close()

        await server.serve()

        try stdoutPipe.fileHandleForWriting.close()
        try stderrPipe.fileHandleForWriting.close()
        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        // Stdout discipline: every line is a JSON-RPC envelope. If a
        // diagnostic (e.g. locale-model warning) had leaked through,
        // the decode would fail and this test would surface it.
        let stdoutString = String(decoding: outputData, as: UTF8.self)
        let stdoutLines = stdoutString
            .split(separator: "\n", omittingEmptySubsequences: true)
        let decoder = JSONDecoder()
        var responses: [JSONRPCResponse] = []
        for stdoutLine in stdoutLines {
            let response = try decoder.decode(
                JSONRPCResponse.self,
                from: Data(stdoutLine.utf8)
            )
            responses.append(response)
        }
        #expect(responses.count == 4)

        // initialize: success.
        #expect(responses[0].id == .int(1))
        #expect(responses[0].error == nil)

        // tools/call transcribe_file happy: success envelope.
        #expect(responses[1].id == .int(2))
        #expect(responses[1].error == nil)
        if case .object(let result) = responses[1].result {
            #expect(result["isError"] == nil)
        }

        // tools/call unknown tool: tool-level isError envelope (NOT
        // a JSON-RPC error).
        #expect(responses[2].id == .int(3))
        #expect(responses[2].error == nil)
        if case .object(let result) = responses[2].result {
            #expect(result["isError"] == .bool(true))
        }

        // tools/call missing required param: JSON-RPC -32602.
        #expect(responses[3].id == .int(4))
        #expect(responses[3].error?.code == -32602)

        // stderr discipline: no diagnostic leaks during tool calls.
        if !stderrData.isEmpty {
            let leaked = String(decoding: stderrData, as: UTF8.self)
            Issue.record(Comment(rawValue: "tools/call leaked to stderr: \(leaked)"))
        }
        #expect(stderrData.isEmpty)
    }
}
