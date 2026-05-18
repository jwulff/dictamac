import Foundation
import DictamacCore
import DictamacSpeech

/// Per-mode async handlers, injected at the dispatch seam so tests can
/// assert which mode the parser resolved without standing up the real
/// transcription pipeline or touching `Darwin.exit(_:)`.
///
/// Each handler returns `Void` because the production path terminates
/// the process via `Darwin.exit(_:)` from inside; control never
/// returns. The test path returns normally and lets the test assert
/// what the recorder captured.
public struct ModeHandlers: Sendable {
    public typealias Handler = @Sendable () async -> Void
    public typealias StringHandler = @Sendable (String) async -> Void

    public let file: StringHandler
    public let stdin: Handler
    public let voiceMemo: StringHandler
    public let listVoiceMemos: Handler
    public let mcp: Handler

    public init(
        file: @escaping StringHandler,
        stdin: @escaping Handler,
        voiceMemo: @escaping StringHandler,
        listVoiceMemos: @escaping Handler,
        mcp: @escaping Handler
    ) {
        self.file = file
        self.stdin = stdin
        self.voiceMemo = voiceMemo
        self.listVoiceMemos = listVoiceMemos
        self.mcp = mcp
    }

    /// Production handlers used by `Dictamac.run()`. The file handler
    /// wires through to `DefaultTranscriber`; every other handler
    /// reports a clean "not yet implemented" error pointing at the
    /// epic / issue that owns the real work (see `StubMessages`).
    ///
    /// `locale` / `wantsJSON` / `verbose` are captured here because
    /// they are static per invocation — the dispatcher itself stays
    /// stateless.
    public static func production(
        locale: String,
        wantsJSON: Bool,
        verbose: Bool
    ) -> ModeHandlers {
        ModeHandlers(
            file: { path in
                await runFileTranscription(
                    path: path,
                    localeIdentifier: locale,
                    wantsJSON: wantsJSON,
                    verbose: verbose
                )
            },
            stdin: {
                let error = DictamacError.argumentError(StubMessages.stdinNotImplemented)
                error.exit()
            },
            voiceMemo: { query in
                let error = DictamacError.argumentError(
                    StubMessages.voiceMemoNotImplemented(query: query)
                )
                error.exit()
            },
            listVoiceMemos: {
                let error = DictamacError.argumentError(
                    StubMessages.listVoiceMemosNotImplemented
                )
                error.exit()
            },
            mcp: {
                let error = DictamacError.argumentError(StubMessages.mcpNotImplemented)
                error.exit()
            }
        )
    }
}

/// Routes a resolved ``Mode`` to the matching handler. Trivial by
/// design — keeping it small means tests have a single seam to assert
/// against and `Dictamac.run()` stays free of switch logic.
public func dispatch(mode: Mode, handlers: ModeHandlers) async {
    switch mode {
    case .file(let path):
        await handlers.file(path)
    case .stdin:
        await handlers.stdin()
    case .voiceMemo(let query):
        await handlers.voiceMemo(query)
    case .listVoiceMemos:
        await handlers.listVoiceMemos()
    case .mcp:
        await handlers.mcp()
    }
}

/// The real file-path handler: expands the path, builds a
/// `TranscriptionRequest`, drives `DefaultTranscriber`, writes the
/// rendered transcript to stdout, and exits the process. Mirrors the
/// runTranscription helper that shipped in PR #40 verbatim; the only
/// move is from `Sources/dictamac/main.swift` into the library so the
/// dispatcher can hand work off without `dictamac`-target circular
/// imports.
func runFileTranscription(
    path inputPath: String,
    localeIdentifier: String,
    wantsJSON: Bool,
    verbose: Bool
) async {
    let expanded = (inputPath as NSString).expandingTildeInPath
    let url = URL(fileURLWithPath: expanded).standardizedFileURL

    if verbose {
        StubMessages.writeStderrLine(
            "dictamac: transcribing \(url.path) (locale=\(localeIdentifier), json=\(wantsJSON))",
            to: .standardError
        )
    }

    let request = TranscriptionRequest(
        source: .file(url),
        locale: Locale(identifier: localeIdentifier),
        format: wantsJSON ? .json : .text
    )

    let transcriber = DefaultTranscriber()
    do {
        let transcript = try await transcriber.transcribe(request)
        writeTranscript(transcript, asJSON: wantsJSON)
        Darwin.exit(0)
    } catch let error as DictamacError {
        error.exit()
    } catch {
        DictamacError.internalFailure(error).exit()
    }
}

/// Stdout sink for the rendered transcript. Lives next to the file
/// handler so the stdout-discipline boundary is in one place — every
/// other "write something to the user" path in this file targets
/// stderr.
private func writeTranscript(_ transcript: Transcript, asJSON: Bool) {
    let rendered = asJSON
        ? JSONFormatter.format(transcript)
        : PlaintextFormatter.format(transcript)
    FileHandle.standardOutput.write(Data(rendered.utf8))
}
