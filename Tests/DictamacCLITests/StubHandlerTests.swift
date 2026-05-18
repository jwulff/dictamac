import Testing
import Foundation
@testable import DictamacCLI
@testable import DictamacCore

/// Tests for the not-yet-implemented stub handlers. Each stub writes
/// an explanatory message to a caller-supplied stderr handle and
/// exits with the right code. Both pieces are asserted here without
/// touching the real `FileHandle.standardError` or process exit.
struct StubHandlerTests {

    // The `--voice-memo` stub was removed in #56 when the real CLI
    // handler landed alongside the MCP `transcribe_voice_memo` wiring
    // from #54. End-to-end coverage now lives in
    // `VoiceMemoHandlerTests.swift`.

    // MARK: - MCP stub points at epic #5

    @Test func mcpStubMessageMentionsEpic5() {
        let message = StubMessages.mcpNotImplemented
        #expect(message.contains("#5"))
    }

    // MARK: - Stub handlers write to provided stderr handle

    @Test func stubMessagesWriterTargetsProvidedHandle() throws {
        // Smoke-test the shared writer helper through one of the
        // remaining stub messages; the dispatcher-level stdin path is
        // exercised in `ResolverWiringTests` now that #27 has wired it.
        let pipe = Pipe()
        StubMessages.writeStderrLine(StubMessages.mcpNotImplemented, to: pipe.fileHandleForWriting)
        try pipe.fileHandleForWriting.close()
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(text.contains("MCP") || text.contains("mcp"))
        #expect(text.hasSuffix("\n"))
    }
}
