import AVFoundation
import CoreMedia
import Foundation
import Speech
import DictamacCore

/// Production ``Transcriber`` backed by Apple's macOS 26 ``SpeechAnalyzer``
/// / ``SpeechTranscriber`` API.
///
/// The lifecycle is wrapped here once so the rest of the codebase can
/// depend on the protocol seam. The CLI and MCP transports both consume
/// this through `any Transcriber`, never the concrete type.
///
/// ## Runtime traps (do not deviate without a strong reason)
///
/// The sibling [steno](https://github.com/jwulff/steno) project paid the
/// cost of discovering each of these. They are reproduced here so a future
/// reader doesn't have to.
///
/// 1. **`SpeechAnalyzer.start` and `analyzeSequence` MUST run on
///    `@MainActor`.** Off the main actor, the framework crashes the
///    process with `SIGTRAP` deep inside Apple code. We hop onto the main
///    actor explicitly via `Task { @MainActor in … }.value` before
///    touching the analyzer for any of its lifecycle operations.
/// 2. **The main RunLoop must be alive for results to be delivered.**
///    The CLI entry point uses `ParsableCommand` (not
///    `AsyncParsableCommand`) and calls `dispatchMain()` after kicking
///    off the async transcription in a `Task {}`. This is enforced by the
///    structure of `Sources/dictamac/main.swift`; if a future refactor
///    breaks it, the symptom will be the analyzer never delivering any
///    `result.isFinal == true` events and the process hanging
///    indefinitely.
/// 3. **Ad-hoc signing with the right entitlements is mandatory at
///    runtime.** `swift run` skips signing and crashes immediately;
///    always go through `make run` / `make build`. The entitlements
///    needed are `disable-library-validation` and `allow-jit` —
///    `com.apple.developer.speech-recognition` is a restricted
///    entitlement that AMFI will SIGKILL the binary for.
///
/// ## Result iteration ordering
///
/// `transcriber.results` is consumed by an `async let` that runs
/// concurrently with the analyzer-driving task. Iteration must start
/// before `analyzeSequence` / `finalizeAndFinish` complete, because the
/// analyzer's lifecycle methods can block until consumers drain results.
/// Structured concurrency (`async let`) keeps the two tasks tied to the
/// same scope; if either throws, both unwind cleanly.
public final class DefaultTranscriber: Transcriber {

    /// The `model` string stamped into the JSON transcript schema
    /// (PLAN.md §6). Pinned as a public static let so tests can assert
    /// the exact value without re-typing the literal.
    public static let modelIdentifier = "SpeechAnalyzer/macOS26"

    public init() {}

    public func transcribe(_ request: TranscriptionRequest) async throws -> Transcript {
        let audioURL = try Self.url(from: request.source)
        let audioFile = try Self.openAudioFile(at: audioURL)
        let locale = request.locale

        let speechTranscriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )

        // The Speech framework requires the locale model to be both
        // (a) installed on the host and (b) "reserved" by this process
        // before the analyzer can use it. Without either step, the
        // analyzer hangs forever — the framework writes a
        // "Cannot use modules with unallocated locales" error to the
        // unified log but never throws, so the symptom is a silent hang.
        //
        // Locale-model bootstrap proper (download progress reporting,
        // offline-failure exit code 67, etc.) lives in #15. Here we do
        // the minimum the analyzer needs to make progress:
        //
        //   1. If the model is `.supported` (or `.downloading`),
        //      kick off `downloadAndInstall()` synchronously. This may
        //      take seconds the first time; subsequent runs are
        //      immediate because the model is cached on disk.
        //   2. Reserve the locale so this process is allocated a
        //      slot in the inventory. Released when the analyzer
        //      tears down (or the process exits).
        try await Self.ensureLocaleModelAvailable(for: speechTranscriber, locale: locale)

        let analyzer = SpeechAnalyzer(modules: [speechTranscriber])

        // Result iteration concurrent with the analyzer pipeline. The
        // for-await loop below must be live before `analyzeSequence`
        // finishes, hence the `async let` shape: the analyze/finalize
        // task is detached but bound to this scope, while we drain the
        // results sequence here on the calling task.
        async let analyzed: CMTime? = Self.runAnalyzerLifecycle(
            analyzer: analyzer,
            audioFile: audioFile
        )

        var segments: [TranscriptSegment] = []
        do {
            for try await result in speechTranscriber.results {
                guard result.isFinal else { continue }
                segments.append(Self.makeSegment(from: result))
            }
        } catch {
            // If results iteration fails, still await the lifecycle to
            // surface its (likely related) error and avoid leaking the
            // structured-concurrency child task.
            _ = try? await analyzed
            throw error
        }

        let analyzedEnd = try await analyzed

        let durationSeconds = Self.durationSeconds(
            analyzedEnd: analyzedEnd,
            file: audioFile,
            segments: segments
        )

        let localeIdentifier = locale.identifier(.bcp47)
        let resolvedLocale = localeIdentifier.isEmpty ? locale.identifier : localeIdentifier

        return Transcript(
            segments: segments,
            locale: resolvedLocale,
            durationSeconds: durationSeconds,
            model: Self.modelIdentifier,
            source: .file(path: audioURL.path)
        )
    }

    // MARK: - Source resolution

    private static func url(from source: TranscriptionRequest.Source) throws -> URL {
        switch source {
        case .file(let url), .stdin(let url):
            // Both shapes carry a local file URL by construction
            // (`AudioFileResolver` validates the path; the stdin
            // resolver, when it lands in #12, will have already drained
            // bytes to a temp file). The transcriber doesn't care which
            // it is — both behave identically from here on down.
            return url
        }
    }

    private static func openAudioFile(at url: URL) throws -> AVAudioFile {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DictamacError.fileNotFound(url)
        }
        do {
            return try AVAudioFile(forReading: url)
        } catch {
            throw DictamacError.audioDecodeFailed(url, underlying: error)
        }
    }

    // MARK: - Locale model availability

    /// Minimum locale-model bootstrap the analyzer needs to make
    /// progress. Full progress reporting and the offline-failure exit
    /// code 67 path lands under issue #15.
    private static func ensureLocaleModelAvailable(
        for transcriber: SpeechTranscriber,
        locale: Locale
    ) async throws {
        let status = await AssetInventory.status(forModules: [transcriber])
        switch status {
        case .installed:
            break
        case .supported, .downloading:
            if let installRequest = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await installRequest.downloadAndInstall()
            }
        case .unsupported:
            // The host doesn't ship a model for this locale. Surface a
            // distinct error so callers can map it (#15 will give this
            // its own DictamacError case + exit code 67).
            throw DictamacError.audioDecodeFailed(
                URL(fileURLWithPath: "/dev/null"),
                underlying: SpeechSetupError.localeUnsupported(locale.identifier)
            )
        @unknown default:
            // A future Status case appears — treat conservatively as
            // unsupported rather than blocking on an unknown state.
            throw DictamacError.audioDecodeFailed(
                URL(fileURLWithPath: "/dev/null"),
                underlying: SpeechSetupError.localeUnsupported(locale.identifier)
            )
        }

        // Reserving is idempotent for already-reserved locales; do it
        // unconditionally so a process that previously released the
        // reservation re-acquires it cleanly. `try` because reserve can
        // fail when the per-process cap is exceeded.
        _ = try await AssetInventory.reserve(locale: locale)
    }

    // MARK: - Analyzer lifecycle on @MainActor

    /// Hop onto `@MainActor` to drive the analyzer lifecycle. This is the
    /// hard requirement called out in the type-level doc-comment — never
    /// inline this call directly off the main actor, even if a future
    /// refactor makes it tempting.
    private static func runAnalyzerLifecycle(
        analyzer: SpeechAnalyzer,
        audioFile: AVAudioFile
    ) async throws -> CMTime? {
        try await Task { @MainActor in
            // `analyzeSequence(from:)` feeds the analyzer with the file's
            // contents end-to-end and handles format conversion
            // internally. It returns the last `CMTime` consumed
            // (typically the duration of the clip).
            let lastTime = try await analyzer.analyzeSequence(from: audioFile)
            // Drain any remaining results and tear the analyzer down
            // through the end of the input we just fed it.
            //
            // **Why the end-of-input variant, not `(through: .positiveInfinity)`.**
            // The PLAN.md §7 U5 sketch uses
            // `finalizeAndFinish(through: .greatestFiniteMagnitude)`,
            // but in practice (verified on macOS 26.3) the
            // `(through:)` variant with any time later than the input
            // hangs forever — the framework appears to wait for input
            // it will never receive. `finalizeAndFinishThroughEndOfInput()`
            // returns promptly once the analyzer has emitted its final
            // results for the file we already passed via
            // `analyzeSequence(from:)`. The steno daemon's `stop()` path
            // uses the same variant for the live-streaming case.
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            return lastTime
        }.value
    }

    // MARK: - Result → TranscriptSegment

    /// Map a single `SpeechTranscriber.Result` into our
    /// transport-independent `TranscriptSegment`.
    ///
    /// Every optional is handled explicitly — no force unwraps. The
    /// per-segment `range: CMTimeRange` is the canonical source of
    /// `startSeconds` / `endSeconds`; if the CMTime values aren't valid
    /// for any reason, we fall back to 0 rather than crashing.
    private static func makeSegment(from result: SpeechTranscriber.Result) -> TranscriptSegment {
        let range = result.range
        let start = Self.seconds(from: range.start)
        let end = Self.seconds(from: range.end)
        let text = String(result.text.characters)
        return TranscriptSegment(
            startSeconds: start,
            endSeconds: end,
            text: text,
            confidence: nil // SpeechTranscriber.Result does not expose
                            // a per-segment confidence scalar in the
                            // macOS 26 public API; treat as absent
                            // (matches PLAN.md §6 "absence is unknown").
        )
    }

    /// Convert a `CMTime` to seconds with explicit fallbacks for the
    /// non-numeric / indefinite cases. Returns 0 for invalid times so
    /// the segment still lands in the transcript with sensible defaults
    /// rather than a NaN poisoning downstream JSON.
    private static func seconds(from time: CMTime) -> Double {
        guard time.isNumeric else { return 0 }
        let raw = time.seconds
        guard raw.isFinite else { return 0 }
        return raw
    }

    // MARK: - Duration

    /// Best available duration for the clip. Prefer the value the
    /// analyzer reports it consumed; fall back to the file's frame count
    /// over its sample rate; fall back to the last segment's
    /// `endSeconds`; final fallback `0`. Every fallback is explicit so
    /// the chain matches the "no force unwraps" rule.
    private static func durationSeconds(
        analyzedEnd: CMTime?,
        file: AVAudioFile,
        segments: [TranscriptSegment]
    ) -> Double {
        if let analyzedEnd, analyzedEnd.isNumeric {
            let value = analyzedEnd.seconds
            if value.isFinite, value > 0 {
                return value
            }
        }
        let frameCount = Double(file.length)
        let sampleRate = file.processingFormat.sampleRate
        if sampleRate > 0, frameCount > 0 {
            return frameCount / sampleRate
        }
        if let last = segments.last {
            return last.endSeconds
        }
        return 0
    }
}

/// Marker errors emitted by the SpeechAnalyzer bootstrap path.
///
/// Lives here (not in `DictamacCore`) because the locale-model bootstrap
/// is a `DictamacSpeech` concern; once #15 lands, the `localeUnsupported`
/// case gets its own `DictamacError` case + exit code 67, and this
/// marker disappears.
public enum SpeechSetupError: Error, LocalizedError, CustomStringConvertible {
    case localeUnsupported(String)

    public var description: String {
        switch self {
        case .localeUnsupported(let identifier):
            return "SpeechAnalyzer reports no on-device model available for locale '\(identifier)' (see issue #15)"
        }
    }

    public var errorDescription: String? { description }
}
