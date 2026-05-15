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
    /// Resolution semantics for this case land in #12.
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

/// Resolves an ``AudioSource`` to a local file URL that
/// ``SpeechAnalyzer`` can read, validating decodability up-front so
/// failures surface as deterministic ``DictamacError`` exit codes.
public protocol AudioFileResolver: Sendable {
    func resolve(source: AudioSource) async throws -> URL
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
public final class DefaultAudioFileResolver: AudioFileResolver, @unchecked Sendable {
    public typealias FormatReporter = @Sendable (ProcessingFormatSummary) -> Void

    private let formatReporter: FormatReporter?

    public init(formatReporter: FormatReporter? = nil) {
        self.formatReporter = formatReporter
    }

    public func resolve(source: AudioSource) async throws -> URL {
        switch source {
        case .path(let path):
            return try resolveFile(path: path)
        case .stdin:
            // Stdin resolution lands in #12; refuse cleanly until then so
            // a premature wire-up surfaces as a recognizable error rather
            // than a confusing AVFoundation failure deep in the stack.
            throw DictamacError.audioDecodeFailed(
                URL(fileURLWithPath: "/dev/stdin"),
                underlying: AudioResolverError.stdinNotYetImplemented
            )
        }
    }

    private func resolveFile(path: String) throws -> URL {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DictamacError.fileNotFound(url)
        }

        do {
            let audioFile = try AVAudioFile(forReading: url)
            let format = audioFile.processingFormat
            let summary = ProcessingFormatSummary(
                sampleRate: format.sampleRate,
                channelCount: format.channelCount
            )
            formatReporter?(summary)
            return url
        } catch {
            throw DictamacError.audioDecodeFailed(url, underlying: error)
        }
    }
}

/// Marker errors emitted by the resolver itself (as opposed to errors
/// propagated from ``AVAudioFile``). Carried inside
/// ``DictamacError/audioDecodeFailed(_:underlying:)`` so callers see a
/// uniform decode-failure shape.
public enum AudioResolverError: Error, CustomStringConvertible {
    case stdinNotYetImplemented

    public var description: String {
        switch self {
        case .stdinNotYetImplemented:
            return "stdin audio input is not yet implemented (see issue #12)"
        }
    }
}
