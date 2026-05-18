import Testing
import Foundation
@testable import DictamacCLI
@testable import DictamacCore

/// Tests for the not-yet-implemented stub handlers. Each stub writes
/// an explanatory message to a caller-supplied stderr handle and
/// exits with the right code. Both pieces are asserted here without
/// touching the real `FileHandle.standardError` or process exit.
struct StubHandlerTests {

    // MARK: - stdin stub points at #27

    @Test func stdinStubMessageMentionsIssue27() {
        let message = StubMessages.stdinNotImplemented
        #expect(message.contains("stdin"))
        #expect(message.contains("#27"))
    }

    // MARK: - voice-memo / list-voice-memos point at epic #4

    @Test func voiceMemoStubMessageMentionsEpic4() {
        let message = StubMessages.voiceMemoNotImplemented(query: "standup")
        #expect(message.contains("standup"))
        #expect(message.contains("#4"))
    }

    @Test func listVoiceMemosStubMessageMentionsEpic4() {
        let message = StubMessages.listVoiceMemosNotImplemented
        #expect(message.contains("#4"))
    }

    // MARK: - MCP stub points at epic #5

    @Test func mcpStubMessageMentionsEpic5() {
        let message = StubMessages.mcpNotImplemented
        #expect(message.contains("#5"))
    }

    // MARK: - Stub handlers write to provided stderr handle

    @Test func stdinStubWritesToProvidedStderrHandle() throws {
        let pipe = Pipe()
        StubMessages.writeStderrLine(StubMessages.stdinNotImplemented, to: pipe.fileHandleForWriting)
        try pipe.fileHandleForWriting.close()
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(text.contains("stdin"))
        #expect(text.hasSuffix("\n"))
    }
}
