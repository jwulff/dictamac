import Foundation

/// Typed failures from ``CloudRecordingsReader``.
///
/// These errors are CALLER-FACING SIGNALS for the resolver (issue #23)
/// to decide when to fall back to the filesystem scanner (issue #20).
/// They are deliberately NOT instances of ``DictamacError`` — the
/// resolver wraps them into a user-facing ``DictamacError`` only if the
/// filesystem fallback also fails. Surfacing
/// ``CloudRecordingsError/sqliteUnavailable`` directly to the user
/// would conflate "Voice Memos has never been opened on this Mac" with
/// "the optimized metadata path didn't fire" — the latter is silent
/// behavior, not an error.
public enum CloudRecordingsError: Error, CustomStringConvertible {
    /// The `CloudRecordings.db` file does not exist on disk. Expected
    /// on fresh installs or after a library reset; the caller should
    /// fall back to the filesystem scanner without surfacing a
    /// user-visible error.
    case sqliteUnavailable(reason: String)

    /// `sqlite3_open_v2` succeeded in finding the file but failed to
    /// open it (corrupt header, lock contention, kernel-level
    /// permission denial that slipped past TCC, etc.). The caller
    /// should still attempt the filesystem fallback — the database
    /// may have been mid-write when we tried to read it.
    case sqliteOpenFailed(reason: String)

    /// A required table or column is missing from the schema — Apple
    /// has changed `CloudRecordings.db`'s private structure. The
    /// caller MUST fall back to the filesystem scanner; this is the
    /// load-bearing signal for the resilience plan documented in
    /// PLAN.md §9 ("CloudRecordings.db schema changes in macOS 27").
    case schemaUnrecognized(reason: String)

    public var description: String {
        switch self {
        case .sqliteUnavailable(let reason):
            return "CloudRecordings SQLite unavailable: \(reason)"
        case .sqliteOpenFailed(let reason):
            return "CloudRecordings SQLite open failed: \(reason)"
        case .schemaUnrecognized(let reason):
            return "CloudRecordings SQLite schema unrecognized: \(reason)"
        }
    }
}
