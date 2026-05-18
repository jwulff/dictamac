import Foundation
import DictamacCore
import DictamacMCP
import DictamacSpeech
import DictamacVoiceMemos

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
    public typealias ListVoiceMemosHandler = @Sendable (
        _ since: String?,
        _ limit: Int?
    ) async -> Void

    public let file: StringHandler
    public let stdin: Handler
    public let voiceMemo: StringHandler
    public let listVoiceMemos: ListVoiceMemosHandler
    public let mcp: Handler

    public init(
        file: @escaping StringHandler,
        stdin: @escaping Handler,
        voiceMemo: @escaping StringHandler,
        listVoiceMemos: @escaping ListVoiceMemosHandler,
        mcp: @escaping Handler
    ) {
        self.file = file
        self.stdin = stdin
        self.voiceMemo = voiceMemo
        self.listVoiceMemos = listVoiceMemos
        self.mcp = mcp
    }

    /// Production handlers used by `Dictamac.run()`. The file and stdin
    /// handlers route through the shared
    /// ``runResolveAndTranscribe(source:resolver:transcriber:localeIdentifier:wantsJSON:verbose:writeStdout:writeStderr:exit:)``
    /// helper so the only difference between them is which
    /// ``AudioSource`` they pass — fileNotFound (exit 64) and
    /// audioDecodeFailed (exit 65) are produced by the resolver layer
    /// for both. Every other handler reports a clean "not yet
    /// implemented" error pointing at the epic / issue that owns the
    /// real work (see `StubMessages`).
    ///
    /// `locale` / `wantsJSON` / `verbose` are captured here because
    /// they are static per invocation — the dispatcher itself stays
    /// stateless.
    public static func production(
        locale: String,
        wantsJSON: Bool,
        verbose: Bool,
        voiceMemosResolverFactory: @Sendable @escaping () -> (any VoiceMemosResolver)
            = {
                DefaultVoiceMemosResolver(
                    locator: DefaultVoiceMemosLibraryLocator(),
                    sqliteReaderFactory: { databaseURL, libraryURL in
                        DefaultCloudRecordingsReader(
                            databaseURL: databaseURL,
                            libraryURL: libraryURL
                        )
                    },
                    filesystemScanner: DefaultFilesystemRecordingsScanner()
                )
            }
    ) -> ModeHandlers {
        // One resolver + one transcriber shared across the file and
        // stdin handlers — both intakes flow through the same seam
        // (PLAN.md §7 U3 / U4). Constructed once per invocation so the
        // closures capture a single, immutable instance.
        let resolver = DefaultAudioFileResolver()
        let transcriber = DefaultTranscriber()

        return ModeHandlers(
            file: { path in
                await runResolveAndTranscribe(
                    source: .path(path),
                    resolver: resolver,
                    transcriber: transcriber,
                    localeIdentifier: locale,
                    wantsJSON: wantsJSON,
                    verbose: verbose
                )
            },
            stdin: {
                await runResolveAndTranscribe(
                    source: .stdin,
                    resolver: resolver,
                    transcriber: transcriber,
                    localeIdentifier: locale,
                    wantsJSON: wantsJSON,
                    verbose: verbose
                )
            },
            voiceMemo: { query in
                let error = DictamacError.argumentError(
                    StubMessages.voiceMemoNotImplemented(query: query)
                )
                error.exit()
            },
            listVoiceMemos: { since, limit in
                // Real handler — see `ListVoiceMemosHandler.swift`.
                // The voice-memos resolver is supplied via the factory
                // closure so a test override can swap the implementation
                // without touching this dispatch site. The default
                // factory constructs a `DefaultVoiceMemosResolver` wiring
                // the library locator, CloudRecordings SQLite reader,
                // and filesystem scanner together.
                let voiceMemosResolver = voiceMemosResolverFactory()
                await runListVoiceMemos(
                    since: since,
                    limit: limit,
                    resolver: voiceMemosResolver,
                    now: Date(),
                    wantsJSON: wantsJSON
                )
            },
            mcp: {
                // Build an MCP server bound to the process's standard
                // handles and register the production handler set.
                // The `initialize` + `tools/list` handlers came from
                // #22; #26 adds `tools/call` via the overload that
                // accepts the shared ``Transcriber`` +
                // ``AudioFileResolver`` so the MCP transport rides
                // the same core the CLI does.
                //
                // The server runs to EOF on stdin; once the loop
                // returns we exit 0 to match the CLI's success
                // contract. Errors thrown by individual handlers are
                // surfaced as JSON-RPC error responses (malformed
                // requests) or `isError: true` tool envelopes
                // (`DictamacError`s) inside the loop, never as
                // process-exit failures.
                let server = MCPServer()
                await ProductionMCPHandlers.register(
                    on: server,
                    transcriber: transcriber,
                    audioResolver: resolver
                )
                await server.serve()
                Darwin.exit(0)
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
    case .listVoiceMemos(let since, let limit):
        await handlers.listVoiceMemos(since, limit)
    case .mcp:
        await handlers.mcp()
    }
}

/// Shared file + stdin pipeline: resolve the audio source, transcribe,
/// render, write to stdout, exit. Errors from any stage are mapped via
/// ``DictamacError`` so the exit code matches the PLAN.md §4 contract
/// regardless of which transport invoked the handler.
///
/// Both the file-path and stdin handlers in
/// ``ModeHandlers/production(locale:wantsJSON:verbose:)`` call this
/// helper; the only difference is the ``AudioSource`` they pass. This
/// is the architectural intent from issue #27: file-not-found (exit 64)
/// and decode-failed/empty-stdin (exit 65) are produced uniformly at
/// the resolver layer rather than once per handler.
///
/// `writeStdout` / `writeStderr` / `exit` are injectable for tests:
/// production captures `FileHandle.standardOutput`,
/// `FileHandle.standardError`, and `Darwin.exit(_:)`; tests inject
/// recorders so they can assert what the production path would have
/// written and which exit code it would have used.
///
/// ## A note on double-validation
///
/// The resolver opens the audio file with `AVAudioFile(forReading:)`
/// to validate decodability up-front. ``DefaultTranscriber`` then opens
/// it again inside the transcription pipeline. The two opens are
/// independent: the resolver fail-fast catches structural errors
/// (missing file, unsupported container) before we spin up
/// ``SpeechAnalyzer``; the transcriber's open is what
/// ``SpeechAnalyzer/analyzeSequence(from:)`` consumes. The redundancy
/// is intentional and small — collapsing them would require a custom
/// "pre-opened audio file" wire format through
/// ``TranscriptionRequest``, and the cost of a second open on the same
/// file is negligible compared to the speech-model bootstrap. See the
/// changes file for this PR for the full rationale.
public func runResolveAndTranscribe(
    source: AudioSource,
    resolver: any AudioFileResolver,
    transcriber: any Transcriber,
    localeIdentifier: String,
    wantsJSON: Bool,
    verbose: Bool,
    writeStdout: @Sendable @escaping (String) -> Void = { string in
        FileHandle.standardOutput.write(Data(string.utf8))
    },
    writeStderr: @Sendable @escaping (String) -> Void = { string in
        FileHandle.standardError.write(Data(string.utf8))
    },
    exit: @Sendable @escaping (Int32) -> Void = { code in
        Darwin.exit(code)
    }
) async {
    // The `exit` closure is `Void`-returning so tests can capture the
    // exit code without terminating the test process. In production
    // the closure is `Darwin.exit(_:)` which truly is `Never`; control
    // never returns past the first call. We therefore `return`
    // explicitly after every `exit(...)` so the test path also stops
    // cleanly (no fall-through into the success branch).

    // Resolve first. fileNotFound (exit 64) and audioDecodeFailed
    // (exit 65) — including empty-stdin — all originate here.
    let resolved: ResolvedAudio
    do {
        resolved = try await resolver.resolve(source: source)
    } catch let error as DictamacError {
        writeStderr(error.formattedStderrLine)
        exit(error.exitCode)
        return
    } catch {
        let wrapped = DictamacError.internalFailure(error)
        writeStderr(wrapped.formattedStderrLine)
        exit(wrapped.exitCode)
        return
    }

    if verbose {
        let summary: String
        switch source {
        case .path:
            summary = "transcribing \(resolved.url.path)"
        case .stdin:
            summary = "transcribing stdin (staged at \(resolved.url.path))"
        }
        writeStderr(
            "dictamac: \(summary) (locale=\(localeIdentifier), json=\(wantsJSON))\n"
        )
    }

    let requestSource: TranscriptionRequest.Source
    switch source {
    case .path:
        requestSource = .file(resolved.url)
    case .stdin:
        requestSource = .stdin(resolved.url)
    }

    let request = TranscriptionRequest(
        source: requestSource,
        locale: Locale(identifier: localeIdentifier),
        format: wantsJSON ? .json : .text
    )

    let transcript: Transcript
    do {
        transcript = try await transcriber.transcribe(request)
    } catch let error as DictamacError {
        resolved.cleanup()
        writeStderr(error.formattedStderrLine)
        exit(error.exitCode)
        return
    } catch {
        resolved.cleanup()
        let wrapped = DictamacError.internalFailure(error)
        writeStderr(wrapped.formattedStderrLine)
        exit(wrapped.exitCode)
        return
    }

    // Success path: render, write stdout, clean up the resolver's
    // staged bytes (no-op for `.path`), exit 0.
    let rendered = wantsJSON
        ? JSONFormatter.format(transcript)
        : PlaintextFormatter.format(transcript)
    writeStdout(rendered)
    resolved.cleanup()
    exit(0)
}
