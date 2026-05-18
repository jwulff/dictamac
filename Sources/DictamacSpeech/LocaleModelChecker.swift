import Foundation

/// Pre-flight bootstrap for the on-device speech model bound to a
/// particular `Locale`.
///
/// The macOS 26 `SpeechAnalyzer` framework requires two things before it
/// can transcribe:
///
/// 1. The locale-specific model must be installed on disk (the OS owns
///    the on-disk cache; first use triggers a download).
/// 2. The locale must be **reserved** by the calling process via
///    `AssetInventory.reserve(locale:)`. Without this, the analyzer
///    hangs forever — the framework writes
///    `"Cannot use modules with unallocated locales"` to the unified
///    log but never throws.
///
/// `LocaleModelChecker` is the seam that captures both steps so the rest
/// of the pipeline can depend on a clean contract:
///
/// - Pre-installed locale → return immediately, no output.
/// - Missing locale, reachable network → download, emit progress lines
///   to the injected ``LocaleModelProgressSink`` (stderr in production),
///   then return.
/// - Missing locale, no network / API error / `.unsupported` status →
///   throw ``DictamacCore/DictamacError/speechAnalyzerUnavailable(reason:)``
///   so the CLI/MCP transports can map to exit code 67 with a helpful
///   manual-install hint.
///
/// The protocol is intentionally narrow — one async, throwing method —
/// so test doubles can simulate any of the above without depending on
/// the real `SpeechTranscriber` / `AssetInventory` types.
public protocol LocaleModelChecker: Sendable {
    /// Verify that the model for `locale` is installed and reserved.
    ///
    /// - Parameters:
    ///   - locale: BCP-47 locale the caller intends to transcribe with.
    ///   - progress: Sink used to surface multi-second download work to
    ///     the operator. Must NOT touch stdout (stdout discipline:
    ///     transcript bytes only). In tests, a capture sink replaces the
    ///     production stderr sink.
    /// - Throws: ``DictamacCore/DictamacError/speechAnalyzerUnavailable(reason:)``
    ///   when the model cannot be made available. The reason string is
    ///   surfaced verbatim on stderr by the CLI error handler.
    func ensureModelAvailable(
        for locale: Locale,
        progress: LocaleModelProgressSink
    ) async throws
}

/// Where ``LocaleModelChecker`` writes its multi-second-wait progress
/// lines. Stderr in production (`FileHandle.standardError`); a capture
/// closure in tests.
///
/// Modelled as a `Sendable` closure so a test can capture into an
/// `actor`-protected buffer without ceremony, and so production can
/// trivially supply `FileHandle.standardError.write(_:)`.
///
/// Each call corresponds to one human-readable status line and SHOULD
/// be terminated with `"\n"` by the caller — the sink writes the bytes
/// verbatim.
public struct LocaleModelProgressSink: Sendable {
    public typealias Write = @Sendable (String) -> Void

    private let write: Write

    public init(_ write: @escaping Write) {
        self.write = write
    }

    /// Emit a single progress line. Callers append the trailing newline.
    public func callAsFunction(_ line: String) {
        write(line)
    }

    /// Production default — writes to `FileHandle.standardError`. UTF-8
    /// encoding failure (effectively impossible for ASCII status lines)
    /// silently no-ops rather than throwing, matching the rest of the
    /// stderr machinery in ``DictamacCore/DictamacError``.
    public static let standardError = LocaleModelProgressSink { line in
        guard let data = line.data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }

    /// Discards all output. Useful as a non-production default; the
    /// production callsite should always pass ``standardError`` (or a
    /// test capture sink) explicitly.
    public static let null = LocaleModelProgressSink { _ in }
}
