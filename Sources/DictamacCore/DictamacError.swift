import Foundation

/// Recoverable failure classes produced by the dictamac pipeline.
///
/// Each case maps deterministically to a stable CLI exit code (PLAN.md
/// §4) so AI agents can react to failures programmatically instead of
/// parsing stderr text. Tests assert the numeric values; the codes are
/// part of the public contract.
///
/// The same enum is consumed by the future MCP transport to construct
/// `{isError: true, content: [...]}` tool responses — behavior parity
/// between CLI and MCP for the same failure is a hard requirement
/// (PLAN.md §7 U9). Centralizing the mapping here prevents the two
/// transports from drifting.
///
/// Adding a new case is non-breaking; renaming or removing one is.
public enum DictamacError: Error, CustomStringConvertible {
    /// Bad argv shape, conflicting flags, or any other CLI-input
    /// validation failure. Exit code 2 — matches the conventional
    /// "usage error" code used by `getopt`-style tools.
    case argumentError(String)

    /// No file exists at the supplied audio path.
    case fileNotFound(URL)

    /// The file exists but `AVAudioFile(forReading:)` could not open or
    /// decode it (unsupported codec, corrupt container, permission
    /// denied at the kernel level, etc.). The underlying error is
    /// preserved verbatim for stderr diagnostics.
    case audioDecodeFailed(URL, underlying: any Error)

    /// A Voice Memos lookup (by fuzzy title, time anchor, ISO date, or
    /// identifier) returned no match.
    case voiceMemoNotFound(query: String)

    /// `SpeechAnalyzer` is unavailable for this run — typically the
    /// locale model is not yet installed and the network is
    /// unreachable, or the host is running an unsupported macOS
    /// version. The reason string is surfaced verbatim on stderr.
    case speechAnalyzerUnavailable(reason: String)

    /// A required TCC permission (e.g. Speech Recognition, Files &
    /// Folders for the Voice Memos library) is missing. When
    /// `deepLink` is supplied, its absolute string is embedded in the
    /// stderr message so terminals that linkify
    /// `x-apple.systempreferences:` URLs let the user grant the
    /// permission in one click.
    case permissionDenied(domain: String, deepLink: URL?)

    /// None of the known Voice Memos library locations exist on this
    /// host. `searched` lists the paths probed so the user can confirm
    /// whether Voice Memos has ever been opened on this Mac, or
    /// whether iCloud sync has migrated the library elsewhere.
    case voiceMemoLibraryMissing(searched: [URL])

    /// Catch-all for unexpected throws that escape a more specific
    /// classification. Prefer a dedicated case when adding new
    /// pipeline stages; this exists so callers never have to choose
    /// between losing diagnostic detail and inventing a meaningless
    /// case ad-hoc.
    case internalFailure(any Error)

    public var description: String {
        switch self {
        case .argumentError(let message):
            return "Argument error: \(message)"
        case .fileNotFound(let url):
            return "No audio file found at \(url.path)"
        case .audioDecodeFailed(let url, let underlying):
            return "Failed to decode audio file at \(url.path): \(Self.message(for: underlying))"
        case .voiceMemoNotFound(let query):
            return "No Voice Memo matched query: \(query)"
        case .speechAnalyzerUnavailable(let reason):
            return "SpeechAnalyzer is unavailable: \(reason)"
        case .permissionDenied(let domain, let deepLink):
            if let deepLink {
                return "Permission denied for \(domain). Grant access in System Settings: \(deepLink.absoluteString)"
            }
            return "Permission denied for \(domain)."
        case .voiceMemoLibraryMissing(let searched):
            if searched.isEmpty {
                return "Voice Memos library not found at any known path."
            }
            let pathList = searched.map(\.path).joined(separator: ", ")
            return "Voice Memos library not found at any known path. Searched: \(pathList)"
        case .internalFailure(let underlying):
            return "Internal failure: \(Self.message(for: underlying))"
        }
    }

    /// Best-effort human-readable text for an underlying error.
    ///
    /// `Error.localizedDescription` bridges to `LocalizedError.errorDescription`
    /// when available, but falls back to a useless
    /// "The operation couldn't be completed. (... error N.)" message for
    /// plain Swift errors. This chain prefers
    /// `LocalizedError.errorDescription`, then `String(describing:)` —
    /// so error types like `AudioResolverError` (which conforms to
    /// `LocalizedError`) surface their custom message, while everything
    /// else falls back to Swift's default reflection output instead of
    /// the unhelpful `NSError`-bridged localized text.
    ///
    /// We deliberately do NOT branch on `CustomStringConvertible`: every
    /// Swift value conforms to it via the implicit bridge, so an
    /// `if let convertible = error as? CustomStringConvertible` always
    /// succeeds and would short-circuit `String(describing:)`
    /// unnecessarily (and the compiler emits a warning to that effect).
    /// `String(describing:)` already routes through
    /// `CustomStringConvertible` when present.
    private static func message(for error: any Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription {
            return localized
        }
        return String(describing: error)
    }

    /// Stable POSIX-style exit code, mapped per PLAN.md §4.
    /// These values are part of the agent-facing contract — tests pin
    /// them and the CLI surface promises them across versions.
    public var exitCode: Int32 {
        switch self {
        case .argumentError: return 2
        case .fileNotFound: return 64
        case .audioDecodeFailed: return 65
        case .voiceMemoNotFound: return 66
        case .speechAnalyzerUnavailable: return 67
        case .permissionDenied: return 73
        case .voiceMemoLibraryMissing: return 74
        case .internalFailure: return 1
        }
    }

    // MARK: - stderr emission

    /// The exact byte sequence the CLI writes to stderr for this
    /// error — ``description`` plus a single trailing `"\n"`.
    ///
    /// Exposed as a property so tests can assert the surface without
    /// poking a file handle; production callers should prefer
    /// ``writeStderrLine(to:)`` or ``exit(_:)``.
    public var formattedStderrLine: String {
        description + "\n"
    }

    /// Writes ``formattedStderrLine`` to the given file handle.
    ///
    /// Defaults to `FileHandle.standardError` so the common CLI path
    /// is one short call. Tests inject a `Pipe().fileHandleForWriting`
    /// to capture the bytes without touching the real stderr.
    ///
    /// Encoding failure (effectively impossible for UTF-8 of
    /// `description`) silently no-ops rather than throwing — the
    /// caller is about to call ``exit(_:)`` anyway and surfacing a
    /// throw would only complicate the unconditional cleanup path.
    public func writeStderrLine(to handle: FileHandle = .standardError) {
        guard let data = formattedStderrLine.data(using: .utf8) else { return }
        handle.write(data)
    }

    /// Writes the error to stderr and terminates the process with the
    /// mapped exit code. The CLI root command's error handler is the
    /// canonical caller. Never returns.
    ///
    /// Stdout discipline (CLAUDE.md / PLAN.md §4): this helper uses
    /// `FileHandle.standardError` explicitly — never `print`, which
    /// defaults to stdout and would poison the transcript channel.
    public func exit() -> Never {
        writeStderrLine()
        Foundation.exit(exitCode)
    }
}
