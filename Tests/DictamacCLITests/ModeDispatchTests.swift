import Testing
import Foundation
@testable import DictamacCLI
@testable import DictamacCore

/// Tests that the mode-dispatch shell calls the right handler for each
/// resolved mode. The dispatch boundary is the seam between parser
/// validation and actual work — every mode owns its own handler, and
/// the dispatcher just routes.
///
/// The file-path handler is the only one wired to real work in this
/// issue (#13); --mcp / --voice-memo / --list-voice-memos / stdin are
/// stubs that record they were called and report a "not yet
/// implemented" error.
struct ModeDispatchTests {

    @Test func fileModeDispatchesToFileHandler() async {
        let recorder = HandlerRecorder()
        let handlers = ModeHandlers(
            file: { path in await recorder.recordFile(path) },
            stdin: { await recorder.recordStdin() },
            voiceMemo: { q in await recorder.recordVoiceMemo(q) },
            listVoiceMemos: { since, limit in
                await recorder.recordListVoiceMemos(since: since, limit: limit)
            },
            mcp: { await recorder.recordMCP() }
        )

        await dispatch(mode: .file(path: "/tmp/audio.m4a"), handlers: handlers)
        let calls = await recorder.calls
        #expect(calls == ["file:/tmp/audio.m4a"])
    }

    @Test func stdinModeDispatchesToStdinHandler() async {
        let recorder = HandlerRecorder()
        let handlers = ModeHandlers(
            file: { _ in await recorder.recordFile("should-not-be-called") },
            stdin: { await recorder.recordStdin() },
            voiceMemo: { _ in await recorder.recordVoiceMemo("nope") },
            listVoiceMemos: { since, limit in
                await recorder.recordListVoiceMemos(since: since, limit: limit)
            },
            mcp: { await recorder.recordMCP() }
        )

        await dispatch(mode: .stdin, handlers: handlers)
        let calls = await recorder.calls
        #expect(calls == ["stdin"])
    }

    @Test func voiceMemoModeDispatchesToVoiceMemoHandler() async {
        let recorder = HandlerRecorder()
        let handlers = ModeHandlers(
            file: { _ in await recorder.recordFile("nope") },
            stdin: { await recorder.recordStdin() },
            voiceMemo: { q in await recorder.recordVoiceMemo(q) },
            listVoiceMemos: { since, limit in
                await recorder.recordListVoiceMemos(since: since, limit: limit)
            },
            mcp: { await recorder.recordMCP() }
        )

        await dispatch(mode: .voiceMemo(query: "yesterday"), handlers: handlers)
        let calls = await recorder.calls
        #expect(calls == ["voiceMemo:yesterday"])
    }

    @Test func listVoiceMemosModeDispatchesToListHandler() async {
        let recorder = HandlerRecorder()
        let handlers = ModeHandlers(
            file: { _ in await recorder.recordFile("nope") },
            stdin: { await recorder.recordStdin() },
            voiceMemo: { _ in await recorder.recordVoiceMemo("nope") },
            listVoiceMemos: { since, limit in
                await recorder.recordListVoiceMemos(since: since, limit: limit)
            },
            mcp: { await recorder.recordMCP() }
        )

        await dispatch(mode: .listVoiceMemos(since: nil, limit: nil), handlers: handlers)
        let calls = await recorder.calls
        #expect(calls == ["listVoiceMemos:since=nil,limit=nil"])
    }

    @Test func listVoiceMemosModePassesSinceAndLimitToHandler() async {
        let recorder = HandlerRecorder()
        let handlers = ModeHandlers(
            file: { _ in await recorder.recordFile("nope") },
            stdin: { await recorder.recordStdin() },
            voiceMemo: { _ in await recorder.recordVoiceMemo("nope") },
            listVoiceMemos: { since, limit in
                await recorder.recordListVoiceMemos(since: since, limit: limit)
            },
            mcp: { await recorder.recordMCP() }
        )

        await dispatch(
            mode: .listVoiceMemos(since: "7d", limit: 5),
            handlers: handlers
        )
        let calls = await recorder.calls
        #expect(calls == ["listVoiceMemos:since=7d,limit=5"])
    }

    @Test func mcpModeDispatchesToMCPHandler() async {
        let recorder = HandlerRecorder()
        let handlers = ModeHandlers(
            file: { _ in await recorder.recordFile("nope") },
            stdin: { await recorder.recordStdin() },
            voiceMemo: { _ in await recorder.recordVoiceMemo("nope") },
            listVoiceMemos: { since, limit in
                await recorder.recordListVoiceMemos(since: since, limit: limit)
            },
            mcp: { await recorder.recordMCP() }
        )

        await dispatch(mode: .mcp, handlers: handlers)
        let calls = await recorder.calls
        #expect(calls == ["mcp"])
    }
}

/// Records handler invocations in arrival order so tests can assert
/// which path the dispatcher took. Actor-isolated state keeps the
/// recorder safe for concurrent use even though the dispatcher
/// currently calls one handler per run.
actor HandlerRecorder {
    private(set) var calls: [String] = []

    func recordFile(_ path: String) { calls.append("file:\(path)") }
    func recordStdin() { calls.append("stdin") }
    func recordVoiceMemo(_ query: String) { calls.append("voiceMemo:\(query)") }
    func recordListVoiceMemos(since: String?, limit: Int?) {
        calls.append(
            "listVoiceMemos:since=\(since ?? "nil"),limit=\(limit.map(String.init) ?? "nil")"
        )
    }
    func recordMCP() { calls.append("mcp") }
}
