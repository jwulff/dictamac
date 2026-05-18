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
struct Dictamac: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dictamac",
        abstract: "Transcribe audio via Apple's on-device SpeechAnalyzer.",
        version: "0.0.0-dev"
    )

    @Argument(help: "Path to a local audio file to transcribe.")
    var path: String?

    @Option(name: .long, help: "BCP-47 locale for transcription (default: en-US).")
    var locale: String = "en-US"

    @Flag(name: .long, help: "Emit the JSON transcript instead of plaintext.")
    var json: Bool = false

    func run() throws {
        guard let inputPath = path else {
            // No subcommand surface yet — print the banner and exit. The
            // full CLI parser ships under #13 (track:cli); this is the
            // minimum needed to verify the SpeechAnalyzer integration
            // end-to-end (issue #19).
            let banner = "dictamac v0.0.0-dev — see https://github.com/jwulff/dictamac\n"
            FileHandle.standardError.write(Data(banner.utf8))
            return
        }

        // Kick off the async pipeline on a Task; never block the calling
        // thread. The Task is responsible for calling `exit()` itself
        // once it has produced output (or failed) — we never return
        // from `dispatchMain()` below.
        Task {
            await Self.runTranscription(
                path: inputPath,
                localeIdentifier: locale,
                wantsJSON: json
            )
        }

        // Park the process on the main RunLoop / dispatch queue.
        // `SpeechAnalyzer` needs this to deliver results. The Task above
        // calls `exit(_:)` to terminate; this call never returns.
        dispatchMain()
    }

    /// Drives the actual transcription. Always terminates the process
    /// via `exit(_:)`; on success exits 0, on failure exits with the
    /// `DictamacError.exitCode` mapping (or 1 for unclassified failures).
    private static func runTranscription(
        path inputPath: String,
        localeIdentifier: String,
        wantsJSON: Bool
    ) async {
        let expanded = (inputPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL

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
            FileHandle.standardError.write(Data("dictamac: \(error)\n".utf8))
            Darwin.exit(error.exitCode)
        } catch {
            FileHandle.standardError.write(Data("dictamac: \(error.localizedDescription)\n".utf8))
            Darwin.exit(1)
        }
    }

    private static func writeTranscript(_ transcript: Transcript, asJSON: Bool) {
        let rendered = asJSON
            ? JSONFormatter.format(transcript)
            : PlaintextFormatter.format(transcript)
        FileHandle.standardOutput.write(Data(rendered.utf8))
    }
}

Dictamac.main()
