import Foundation
import AVFoundation

/// User-facing description of where audio bytes should come from. The
/// resolver's job is to turn this into a local file URL that
/// ``SpeechAnalyzer`` can read (PLAN.md §7 U4).
public enum AudioSource: Sendable, Equatable {
    /// A path supplied on the CLI or via an MCP `transcribe_file` call.
    /// May be relative or absolute, may contain `~`, may be a symlink.
    case path(String)

    /// Audio bytes piped to stdin (CLI `-` argument or MCP equivalent).
    /// The resolver drains stdin into a uniquely-named temp file under
    /// ``NSTemporaryDirectory()`` and returns that URL inside a
    /// ``ResolvedAudio`` whose `cleanup()` deletes the temp file.
    case stdin
}

/// Sample-rate and channel-count summary captured at resolve time so the
/// CLI's `--verbose` mode can surface format info without reopening the
/// file. Defined as a `Sendable` value type so it can flow through actor
/// boundaries without `AVAudioFormat`'s class-bound concurrency baggage.
public struct ProcessingFormatSummary: Sendable, Equatable {
    public let sampleRate: Double
    public let channelCount: UInt32

    public init(sampleRate: Double, channelCount: UInt32) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    /// Human-readable one-liner for `--verbose` stderr output.
    public var summary: String {
        "sampleRate=\(sampleRate) Hz, channels=\(channelCount)"
    }
}

/// The output of a successful ``AudioFileResolver/resolve(source:)``: a
/// local file URL plus a `cleanup()` hook the caller MUST invoke once
/// transcription finishes (success or failure).
///
/// For the `.path` branch, `cleanup()` is a no-op — we don't own the
/// file. For the `.stdin` branch, `cleanup()` deletes the temp file
/// staged from stdin. Cleanup is **safe to call more than once** and
/// **never throws** — issue #12's contract is that cleanup must not
/// fail the surrounding transcription if the transcript was already
/// produced. Failures route to the resolver's `diagnosticSink` instead.
public struct ResolvedAudio: Sendable {
    /// The local file URL ``SpeechAnalyzer`` will read from.
    public let url: URL

    /// Cleanup closure — idempotent, non-throwing, side-effect-only.
    private let _cleanup: @Sendable () -> Void

    public init(url: URL, cleanup: @escaping @Sendable () -> Void) {
        self.url = url
        self._cleanup = cleanup
    }

    /// Invoke the cleanup hook. Safe to call multiple times.
    public func cleanup() {
        _cleanup()
    }
}

/// Resolves an ``AudioSource`` to a local file URL that
/// ``SpeechAnalyzer`` can read, validating decodability up-front so
/// failures surface as deterministic ``DictamacError`` exit codes.
public protocol AudioFileResolver: Sendable {
    func resolve(source: AudioSource) async throws -> ResolvedAudio
}

/// Production implementation backed by ``AVAudioFile`` for decodability
/// validation.
///
/// The resolver opens the file with `AVAudioFile(forReading:)` to confirm
/// the codec is supported before handing the URL off downstream — this is
/// where exit codes 64 (file not found) and 65 (decode failed) are
/// produced.
///
/// Inject a `formatReporter` closure to receive ``ProcessingFormatSummary``
/// for each successful resolve; the CLI's `--verbose` mode wires one up,
/// and tests use the closure to assert the captured format.
///
/// Inject `stdinProvider` to control which `FileHandle` the `.stdin`
/// branch drains from — production defaults to
/// `FileHandle.standardInput`; tests inject the read end of a `Pipe`.
///
/// `Sendable` conformance is checked: the only stored properties are
/// immutable `let`s of `Optional<@Sendable closure>` or `@Sendable
/// closure` shape, which the compiler can verify on its own — no
/// `@unchecked` required.
public final class DefaultAudioFileResolver: AudioFileResolver {
    public typealias FormatReporter = @Sendable (ProcessingFormatSummary) -> Void
    public typealias StdinProvider = @Sendable () -> FileHandle
    public typealias DiagnosticSink = @Sendable (String) -> Void

    private let formatReporter: FormatReporter?
    private let stdinProvider: StdinProvider
    private let diagnosticSink: DiagnosticSink
    private let tempFileObserver: (@Sendable (URL) -> Void)?

    /// - Parameters:
    ///   - formatReporter: called once per successful resolve with the
    ///     audio's processing format (sample rate + channel count).
    ///   - stdinProvider: closure returning the `FileHandle` to drain on
    ///     `.stdin`. Defaults to `FileHandle.standardInput`. Tests
    ///     inject the read end of a `Pipe`.
    ///   - diagnosticSink: closure that receives stderr-bound
    ///     diagnostic messages (e.g. cleanup failures). Defaults to
    ///     writing to `FileHandle.standardError`. stdout discipline
    ///     (PLAN.md §4) means these messages must NEVER go to stdout.
    ///   - tempFileObserver: test-only hook; called with the URL of any
    ///     temp file the resolver creates so leak-detection tests can
    ///     verify cleanup. Not part of the public production API.
    public init(
        formatReporter: FormatReporter? = nil,
        stdinProvider: @escaping StdinProvider = { FileHandle.standardInput },
        diagnosticSink: @escaping DiagnosticSink = { message in
            FileHandle.standardError.write(Data(message.utf8))
        },
        tempFileObserver: (@Sendable (URL) -> Void)? = nil
    ) {
        self.formatReporter = formatReporter
        self.stdinProvider = stdinProvider
        self.diagnosticSink = diagnosticSink
        self.tempFileObserver = tempFileObserver
    }

    public func resolve(source: AudioSource) async throws -> ResolvedAudio {
        switch source {
        case .path(let path):
            return try resolveFile(path: path)
        case .stdin:
            return try resolveStdin()
        }
    }

    private func resolveFile(path: String) throws -> ResolvedAudio {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DictamacError.fileNotFound(url)
        }

        do {
            let audioFile = try AVAudioFile(forReading: url)
            reportFormat(of: audioFile)
            // .path branch: the caller-supplied file is not ours to
            // delete. cleanup() is a no-op.
            return ResolvedAudio(url: url, cleanup: {})
        } catch {
            throw DictamacError.audioDecodeFailed(url, underlying: error)
        }
    }

    private func resolveStdin() throws -> ResolvedAudio {
        // Stage stdin into a unique temp file. We commit to a path
        // BEFORE the AVAudioFile validation so that, on failure, we
        // delete the bytes we just wrote rather than leaking them in
        // /tmp. The `.m4a` extension is documented as the assumed
        // container (PLAN.md §7 U4); a wrong container surfaces as the
        // standard exit-65 decode error.
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dictamac-stdin-\(UUID().uuidString).m4a")
        tempFileObserver?(tempURL)

        // Drain stdin. `readToEnd()` returns nil on immediate EOF (the
        // FileHandle docs are ambiguous, but empirically: nil for no
        // bytes available, empty Data for closed-with-zero-bytes). Treat
        // both as "empty stdin" — neither yields a valid audio file.
        let bytes: Data
        do {
            bytes = try stdinProvider().readToEnd() ?? Data()
        } catch {
            throw DictamacError.audioDecodeFailed(
                tempURL,
                underlying: AudioResolverError.stdinReadFailed(underlying: error)
            )
        }

        guard !bytes.isEmpty else {
            throw DictamacError.audioDecodeFailed(
                tempURL,
                underlying: AudioResolverError.stdinEmpty
            )
        }

        do {
            try bytes.write(to: tempURL, options: .atomic)
        } catch {
            throw DictamacError.audioDecodeFailed(
                tempURL,
                underlying: AudioResolverError.tempFileWriteFailed(underlying: error)
            )
        }

        do {
            let audioFile = try AVAudioFile(forReading: tempURL)
            reportFormat(of: audioFile)
        } catch {
            // Validation failed — delete the bytes we staged before
            // surfacing the decode error so we don't leak temp files
            // on the error path.
            removeTempFile(at: tempURL)
            throw DictamacError.audioDecodeFailed(tempURL, underlying: error)
        }

        // Success: hand the URL back with a cleanup that the caller
        // invokes after transcription. Capture diagnosticSink locally so
        // the closure stays @Sendable without retaining self.
        let sink = self.diagnosticSink
        let cleanupURL = tempURL
        let cleanedFlag = AtomicFlag()
        return ResolvedAudio(url: tempURL, cleanup: {
            // Idempotent: first call removes; subsequent calls no-op.
            guard cleanedFlag.compareAndSet() else { return }
            Self.removeTempFile(at: cleanupURL, diagnosticSink: sink)
        })
    }

    private func reportFormat(of audioFile: AVAudioFile) {
        guard let formatReporter else { return }
        let format = audioFile.processingFormat
        let summary = ProcessingFormatSummary(
            sampleRate: format.sampleRate,
            channelCount: format.channelCount
        )
        formatReporter(summary)
    }

    /// Removes the staged temp file; never throws. Cleanup failures route
    /// to the resolver's `diagnosticSink` (stderr by default) per the
    /// issue #12 contract: cleanup must NOT fail the surrounding
    /// transcription if the transcript was already produced.
    private func removeTempFile(at url: URL) {
        Self.removeTempFile(at: url, diagnosticSink: diagnosticSink)
    }

    private static func removeTempFile(at url: URL, diagnosticSink: DiagnosticSink) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile, CocoaError.fileReadNoSuchFile {
            // Already gone — fine, this is the expected idempotent path.
            return
        } catch {
            // Surface as a stderr-bound diagnostic; do not throw.
            diagnosticSink(
                "dictamac: warning: failed to remove stdin temp file at "
                + "\(url.path): \(error.localizedDescription)\n"
            )
        }
    }

}

/// One-shot atomic flag used to make ``ResolvedAudio/cleanup()``
/// idempotent under concurrent or duplicate invocations.
private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false

    /// Returns `true` on the first call, `false` on every subsequent
    /// call. Caller performs the side effect only when this returns
    /// `true`.
    func compareAndSet() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if set { return false }
        set = true
        return true
    }
}

/// Marker errors emitted by the resolver itself (as opposed to errors
/// propagated from ``AVAudioFile``). Carried inside
/// ``DictamacError/audioDecodeFailed(_:underlying:)`` so callers see a
/// uniform decode-failure shape.
///
/// Conforms to `LocalizedError` so the `localizedDescription` bridge
/// surfaces the marker text instead of the generic
/// "The operation couldn't be completed" NSError message — callers that
/// hand this error up via ``DictamacError`` rely on that bridge to keep
/// the specific failure reason visible.
public enum AudioResolverError: Error, LocalizedError, CustomStringConvertible {
    /// `FileHandle.readToEnd()` returned nil or an empty `Data` — the
    /// caller piped no bytes (e.g. `: | dictamac -`). This is exit 65.
    case stdinEmpty

    /// `FileHandle.readToEnd()` itself threw, e.g. the pipe was severed
    /// mid-read. The original error is preserved for stderr.
    case stdinReadFailed(underlying: any Error)

    /// `Data.write(to:)` failed when staging stdin into the temp file —
    /// usually a permissions or disk-space issue.
    case tempFileWriteFailed(underlying: any Error)

    public var description: String {
        switch self {
        case .stdinEmpty:
            return "stdin was empty — no bytes were piped in"
        case .stdinReadFailed(let underlying):
            return "failed to read audio bytes from stdin: \(underlying.localizedDescription)"
        case .tempFileWriteFailed(let underlying):
            return "failed to stage stdin bytes to a temp file: \(underlying.localizedDescription)"
        }
    }

    public var errorDescription: String? { description }
}
