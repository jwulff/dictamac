import ArgumentParser
import Darwin
import Foundation
import DictamacCore
import DictamacSpeech

/// Top-level CLI command.
///
/// **Concurrency shape (do not change without reading the rationale).**
///
/// `dictamac` uses `ParsableCommand` (NOT `AsyncParsableCommand`) and
/// hands off all real work to a `Task {}`, then parks the process on
/// `dispatchMain()`. The combination is required because:
///
/// - `SpeechAnalyzer` only delivers transcription results when the
///   main RunLoop is alive. `AsyncParsableCommand` runs `run()` on a
///   task that, after returning, lets the runtime tear down the
///   process before results are pumped — the analyzer hangs silently
///   or crashes with `SIGTRAP`.
/// - `dispatchMain()` keeps the main thread serving the dispatch queue
///   indefinitely; the only way out is `exit(_:)` from inside our
///   async work, which is exactly what we do once a transcript is
///   printed (or an error has been written to stderr).
///
/// The sibling [steno](https://github.com/jwulff/steno) project pays
/// the same cost. See `CLAUDE.md` "macOS 26 Speech API Notes" and
/// `docs/PLAN.md` §7 U5 for the full rationale.
public struct Dictamac: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "dictamac",
        abstract: "Transcribe audio via Apple's on-device SpeechAnalyzer.",
        discussion: """
        Reads audio from a file, stdin (`-`), or a Voice Memo lookup and
        writes the transcript to stdout. Diagnostics and errors go to
        stderr; the stdout channel is reserved for transcript content
        so the output is safely pipeable.
        """,
        // Read from the embedded Info.plist via `DictamacVersion.current`
        // so the CLI's `--version` output, the MCP `initialize`
        // response's `serverInfo.version`, and the bundle's
        // `CFBundleShortVersionString` cannot drift apart. See
        // `Sources/DictamacCore/DictamacVersion.swift` for the lookup
        // contract and test-bundle fallback.
        version: DictamacVersion.current
    )

    // MARK: - Positional input

    @Argument(help: ArgumentHelp(
        "Path to a local audio file to transcribe, or '-' to read from stdin.",
        valueName: "path-or-dash"
    ))
    public var path: String?

    // MARK: - Locale / output format

    @Option(name: .long, help: "BCP-47 locale for transcription (default: en-US).")
    public var locale: String = "en-US"

    @Flag(name: .long, help: "Emit the JSON transcript instead of plaintext.")
    public var json: Bool = false

    // MARK: - Voice Memos modes

    @Option(
        name: .customLong("voice-memo"),
        help: ArgumentHelp(
            "Find and transcribe a Voice Memo by title, date, or identifier.",
            valueName: "query"
        )
    )
    public var voiceMemo: String?

    @Flag(
        name: .customLong("list-voice-memos"),
        help: "List Voice Memos in reverse chronological order."
    )
    public var listVoiceMemos: Bool = false

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Restrict --list-voice-memos to a recent window (e.g. 7d, 2w, 1m, or ISO date).",
            valueName: "duration"
        )
    )
    public var since: String?

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Maximum number of Voice Memos to list (default: 30).",
            valueName: "n"
        )
    )
    public var limit: Int?

    // MARK: - MCP mode

    @Flag(name: .customLong("mcp"), help: "Run as an MCP JSON-RPC stdio server.")
    public var mcp: Bool = false

    // MARK: - Diagnostics

    @Flag(name: .long, help: "Write per-step timing and progress to stderr.")
    public var verbose: Bool = false

    public init() {}

    // MARK: - Mode resolution / mutual exclusivity

    /// Resolves the parsed flags into a single ``Mode`` value or
    /// throws ``DictamacCLIError`` if the combination is invalid.
    ///
    /// The mutual-exclusivity rules (PLAN.md §7 U3) are:
    ///
    /// - `--mcp` is a top-level mode; it cannot combine with any
    ///   content flag (`path`, `-`, `--voice-memo`,
    ///   `--list-voice-memos`, `--since`, `--limit`).
    /// - `--list-voice-memos` is a top-level mode; no audio input is
    ///   expected and `--voice-memo` cannot be combined with it.
    ///   `--since` and `--limit` ONLY apply here.
    /// - Outside those modes, exactly one input source is required:
    ///   positional `path`, `-` (stdin marker), or `--voice-memo`.
    ///
    /// Pure function — no I/O, no process exit — so the parser tests
    /// can drive every branch from argv strings without touching the
    /// real stderr or terminating the test runner.
    public func resolveMode() throws -> Mode {
        // `--mcp` and `--list-voice-memos` are top-level modes; they
        // are mutually exclusive with each other and with every
        // content flag.
        if mcp && listVoiceMemos {
            throw DictamacCLIError.argumentError(
                "--mcp and --list-voice-memos are mutually exclusive modes."
            )
        }

        // `--since` / `--limit` are only valid with `--list-voice-memos`.
        if !listVoiceMemos {
            if since != nil {
                throw DictamacCLIError.argumentError(
                    "--since is only valid with --list-voice-memos."
                )
            }
            if limit != nil {
                throw DictamacCLIError.argumentError(
                    "--limit is only valid with --list-voice-memos."
                )
            }
        }

        if mcp {
            if path != nil || voiceMemo != nil {
                throw DictamacCLIError.argumentError(
                    "--mcp does not accept audio input flags or arguments."
                )
            }
            return .mcp
        }

        if listVoiceMemos {
            if path != nil || voiceMemo != nil {
                throw DictamacCLIError.argumentError(
                    "--list-voice-memos does not accept audio input flags or arguments."
                )
            }
            return .listVoiceMemos(since: since, limit: limit)
        }

        // Content modes — exactly one input source required.
        let hasPath = path != nil
        let hasVoiceMemo = voiceMemo != nil

        if hasPath && hasVoiceMemo {
            throw DictamacCLIError.argumentError(
                "Specify either a path argument or --voice-memo, not both."
            )
        }

        if let voiceMemo {
            return .voiceMemo(query: voiceMemo)
        }

        if let path {
            if path == "-" {
                return .stdin
            }
            return .file(path: path)
        }

        throw DictamacCLIError.argumentError(
            "Missing input. Provide an audio file path, '-' for stdin, --voice-memo <query>, --list-voice-memos, or --mcp."
        )
    }

    // MARK: - Entry point

    /// Detects mode, hands off to the right async handler, and parks
    /// the process on `dispatchMain()` (see the concurrency-shape
    /// note above). Validation failures route through
    /// `DictamacError.exit()` so they share the exit-code 2 contract
    /// with every other argument-parsing error.
    public func run() throws {
        let mode: Mode
        do {
            mode = try resolveMode()
        } catch let error as DictamacCLIError {
            error.asDictamacError.exit()
        }

        let handlers = ModeHandlers.production(
            locale: locale,
            wantsJSON: json,
            verbose: verbose
        )

        // Kick off the async pipeline on a Task; never block the
        // calling thread. The Task is responsible for calling
        // `exit()` itself once it has produced output (or failed) —
        // we never return from `dispatchMain()` below.
        Task {
            await dispatch(mode: mode, handlers: handlers)
        }

        // Park the process on the main RunLoop / dispatch queue.
        // `SpeechAnalyzer` needs this to deliver results. The Task
        // above calls `Darwin.exit(_:)` to terminate; this call never
        // returns.
        dispatchMain()
    }
}
