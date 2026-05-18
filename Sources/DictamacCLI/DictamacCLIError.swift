import Foundation
import DictamacCore

/// Validation failures produced by the CLI parser shell that wrap
/// `DictamacError.argumentError` so callers can `throw` from inside
/// pure helpers (e.g. `Dictamac.resolveMode()`) without touching the
/// process exit.
///
/// The CLI entry point catches these and routes them through the same
/// stderr-and-exit-2 path that `DictamacError.argumentError` uses, so
/// the agent-facing contract from PLAN.md §4 is preserved.
public enum DictamacCLIError: Error, Equatable, CustomStringConvertible {
    /// Invalid combination of flags / arguments. Maps to exit code 2.
    case argumentError(String)

    public var description: String {
        switch self {
        case .argumentError(let message):
            return message
        }
    }

    /// Bridges to the shared core error type so the CLI entry point's
    /// catch site can use the same exit-code mapping as every other
    /// recoverable failure (`DictamacError.exitCode`).
    public var asDictamacError: DictamacError {
        switch self {
        case .argumentError(let message):
            return .argumentError(message)
        }
    }
}
