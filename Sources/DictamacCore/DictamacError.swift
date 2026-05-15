import Foundation

/// Recoverable failure classes produced by the dictamac pipeline.
///
/// Each case maps deterministically to a stable CLI exit code (PLAN.md
/// §4) so AI agents can react to failures programmatically instead of
/// parsing stderr text. Tests assert the numeric values; the codes are
/// part of the public contract.
///
/// This enum starts narrow — only the cases needed for whichever
/// pipeline stages have shipped — and grows one case per landed
/// feature issue. Adding a new case is not a breaking change; renaming
/// or removing one is.
public enum DictamacError: Error, CustomStringConvertible {
    /// No file exists at the supplied audio path.
    case fileNotFound(URL)

    /// The file exists but `AVAudioFile(forReading:)` could not open or
    /// decode it (unsupported codec, corrupt container, permission
    /// denied at the kernel level, etc.). The underlying error is
    /// preserved verbatim for stderr diagnostics.
    case audioDecodeFailed(URL, underlying: any Error)

    public var description: String {
        switch self {
        case .fileNotFound(let url):
            return "No audio file found at \(url.path)"
        case .audioDecodeFailed(let url, let underlying):
            return "Failed to decode audio file at \(url.path): \(Self.message(for: underlying))"
        }
    }

    /// Best-effort human-readable text for an underlying error.
    ///
    /// `Error.localizedDescription` bridges to `LocalizedError.errorDescription`
    /// when available, but falls back to a useless
    /// "The operation couldn't be completed. (... error N.)" message for
    /// plain Swift errors. This chain prefers
    /// `LocalizedError.errorDescription`, then any `CustomStringConvertible`
    /// description, then `String(describing:)` — so error types like
    /// `AudioResolverError` (which conforms to both `LocalizedError` and
    /// `CustomStringConvertible`) and AVFoundation's NSError-bridged
    /// failures both surface useful text.
    private static func message(for error: any Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription {
            return localized
        }
        if let convertible = error as? CustomStringConvertible {
            return convertible.description
        }
        return String(describing: error)
    }

    /// Stable POSIX-style exit code, mapped per PLAN.md §4.
    /// These values are part of the agent-facing contract.
    public var exitCode: Int32 {
        switch self {
        case .fileNotFound: return 64
        case .audioDecodeFailed: return 65
        }
    }
}
