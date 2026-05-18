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

    /// Pre-flight bootstrap that guarantees the on-device speech model
    /// is installed and reserved before `SpeechAnalyzer` runs. Replaces
    /// the inline private static `ensureLocaleModelAvailable` that
    /// landed with PR #40; see `LocaleModelChecker.swift` for the
    /// rationale.
    private let localeModelChecker: any LocaleModelChecker

    /// Where the locale-model bootstrap writes its progress lines. In
    /// production this is stderr (per stdout discipline); tests inject
    /// a capture sink. Defaults to ``LocaleModelProgressSink/standardError``
    /// so the common CLI path is one short call.
    private let progressSink: LocaleModelProgressSink

    public init(
        localeModelChecker: any LocaleModelChecker = SpeechAPILocaleModelChecker(),
        progressSink: LocaleModelProgressSink = .standardError
    ) {
        self.localeModelChecker = localeModelChecker
        self.progressSink = progressSink
    }

    public func transcribe(_ request: TranscriptionRequest) async throws -> Transcript {
        let audioURL = try Self.url(from: request.source)
        let audioFile = try Self.openAudioFile(at: audioURL)
        let locale = request.locale

        // Bootstrap the on-device speech model BEFORE constructing the
        // analyzer. The injected `LocaleModelChecker` handles install
        // status, multi-second download progress reporting (to stderr),
        // the `AssetInventory.reserve(locale:)` step that the framework
        // requires (without it `analyzeSequence` hangs forever — see
        // `LocaleModelChecker.swift`), and exit-code-67 failure mapping.
        try await localeModelChecker.ensureModelAvailable(
            for: locale,
            progress: progressSink
        )

        let speechTranscriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )

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
