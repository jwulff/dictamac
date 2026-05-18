import Foundation
import SQLite3

// MARK: - Schema warning
//
// Voice Memos `CloudRecordings.db` schema is **private and
// undocumented by Apple**. May change without warning in any macOS
// release. The filesystem fallback (`FilesystemRecordingsScanner`,
// #20) is the resilience plan — callers should fall back when this
// reader throws.
//
// Today (macOS 26) the relevant shape is approximately:
//
//     CREATE TABLE ZCLOUDRECORDING (
//         Z_PK          INTEGER PRIMARY KEY,
//         ZCUSTOMLABEL  TEXT,          -- user-visible title
//         ZDATE         REAL,          -- NSDate (sec since 2001-01-01)
//         ZDURATION     REAL,          -- seconds
//         ZPATH         TEXT           -- absolute or relative asset path
//     )
//
// We `SELECT` every column by name (never by ordinal) and translate
// missing-column / missing-table conditions into
// ``CloudRecordingsError/schemaUnrecognized(reason:)`` so the caller
// can fall back rather than crash. See PLAN.md §9 risk row
// "CloudRecordings.db schema changes in macOS 27".

/// Read-only metadata source for Voice Memos backed by Apple's
/// undocumented `CloudRecordings.db` SQLite database.
///
/// Production callers should treat any throw from this protocol as a
/// signal to fall back to ``FilesystemRecordingsScanner`` (issue #20).
/// The resolver (issue #23) owns the actual fallback orchestration —
/// this protocol just surfaces typed failures.
public protocol CloudRecordingsReader: Sendable {
    /// Returns every `ZCLOUDRECORDING` row as ``VoiceMemoMetadata``.
    ///
    /// - Throws:
    ///   - ``CloudRecordingsError/sqliteUnavailable(reason:)`` when
    ///     the database file does not exist on disk.
    ///   - ``CloudRecordingsError/sqliteOpenFailed(reason:)`` when
    ///     `sqlite3_open_v2` fails for any reason other than missing
    ///     file (permissions, malformed header, lock contention).
    ///   - ``CloudRecordingsError/schemaUnrecognized(reason:)`` when
    ///     the expected table or any expected column is absent — Apple
    ///     has changed the private schema and the caller should fall
    ///     back to the filesystem scanner.
    func recordings() throws -> [VoiceMemoMetadata]
}

/// Production implementation backed by the system `libsqlite3`
/// (`import SQLite3`). No SPM dependency on a third-party SQLite
/// wrapper — this is a ~150-line read-only reader, see issue #17.
///
/// Lifetime: the SQLite handle is opened and closed per ``recordings()``
/// call, scoped by a `defer` block. Holding the handle as a stored
/// property would force ``CloudRecordingsReader`` callers to manage a
/// long-lived database connection across what is meant to be a
/// transient metadata read; the public surface is intentionally
/// stateless.
public final class DefaultCloudRecordingsReader: CloudRecordingsReader {
    /// SQLite stores `NSDate` timestamps as seconds since the Core Data
    /// epoch (`2001-01-01 00:00:00 UTC`). Construct ``Date`` values
    /// using ``Date/init(timeIntervalSinceReferenceDate:)``.
    private static let referenceEpoch = Date(timeIntervalSinceReferenceDate: 0)

    /// The canonical table name the reader expects. If macOS renames
    /// it, ``recordings()`` throws ``CloudRecordingsError/schemaUnrecognized(reason:)``.
    private static let expectedTableName = "ZCLOUDRECORDING"

    /// The canonical column names the reader projects. Selected by
    /// name in the `SELECT` statement; a missing column trips the
    /// SQLite "no such column" error which we translate to
    /// ``CloudRecordingsError/schemaUnrecognized(reason:)``.
    private struct ExpectedColumns {
        static let primaryKey = "Z_PK"
        static let title = "ZCUSTOMLABEL"
        static let date = "ZDATE"
        static let duration = "ZDURATION"
        static let path = "ZPATH"
    }

    private let databaseURL: URL

    /// Root directory used to resolve relative `ZPATH` values into
    /// absolute asset paths. Apple stores some Voice Memos with an
    /// absolute path (`/Users/foo/.../bar.m4a`) and others with a path
    /// relative to the library's `Recordings/` directory (just
    /// `bar.m4a`). Without a base URL, `URL(fileURLWithPath:)` would
    /// resolve the latter against the process working directory, which
    /// violates ``VoiceMemoMetadata/assetPath``'s absolute-path
    /// contract and breaks downstream transcription.
    ///
    /// Callers obtain this URL from
    /// ``VoiceMemosLibraryLocator/locate()`` — the same directory that
    /// contains `CloudRecordings.db` and the `*.m4a` assets.
    private let libraryURL: URL

    public init(databaseURL: URL, libraryURL: URL) {
        self.databaseURL = databaseURL
        self.libraryURL = libraryURL
    }

    public func recordings() throws -> [VoiceMemoMetadata] {
        // Fail fast with a typed signal so the caller can fall back to
        // the filesystem scanner without parsing a generic SQLite
        // error string. `FileManager.default` is unavoidable here —
        // it's not `Sendable`, but we only call a pure stat-style
        // method on it synchronously inside the reader. The reader
        // itself is `Sendable` (no shared mutable state in the class).
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw CloudRecordingsError.sqliteUnavailable(
                reason: "CloudRecordings.db not found at \(databaseURL.path)"
            )
        }

        let handle = try openReadOnly(at: databaseURL)
        defer { sqlite3_close(handle) }

        try assertTableExists(Self.expectedTableName, on: handle)

        let selectSQL = """
        SELECT \(ExpectedColumns.primaryKey),
               \(ExpectedColumns.title),
               \(ExpectedColumns.date),
               \(ExpectedColumns.duration),
               \(ExpectedColumns.path)
        FROM \(Self.expectedTableName)
        """

        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(handle, selectSQL, -1, &statement, nil)
        if prepareResult != SQLITE_OK {
            // Try to identify whether this is schema drift (missing
            // column) versus a generic SQLite error. SQLite reports
            // "no such column: X" verbatim in `sqlite3_errmsg`; we
            // surface that as schema-drift so the caller falls back.
            let message = lastErrorMessage(handle: handle)
            sqlite3_finalize(statement)
            if message.lowercased().contains("no such column")
                || message.lowercased().contains("no such table") {
                throw CloudRecordingsError.schemaUnrecognized(
                    reason: message
                )
            }
            throw CloudRecordingsError.sqliteOpenFailed(
                reason: "prepare failed: \(message)"
            )
        }
        guard let statement else {
            throw CloudRecordingsError.sqliteOpenFailed(
                reason: "prepare returned a nil statement handle"
            )
        }
        defer { sqlite3_finalize(statement) }

        var results: [VoiceMemoMetadata] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE {
                break
            }
            if stepResult != SQLITE_ROW {
                throw CloudRecordingsError.sqliteOpenFailed(
                    reason: "step failed: \(lastErrorMessage(handle: handle))"
                )
            }

            // Column indices match the SELECT order above. SQLite's
            // `sqlite3_column_*` reads by ordinal in the result set,
            // not by table-column ordinal — the SELECT pinned the
            // projection by column name, so this is safe against
            // table-column reordering.
            let primaryKey = sqlite3_column_int64(statement, 0)
            let title = readText(statement, column: 1)
            let date = sqlite3_column_double(statement, 2)
            let duration = sqlite3_column_double(statement, 3)
            let path = readText(statement, column: 4)

            // Treat NULL/empty path as unusable — the resolver can't
            // open an asset with no path, so the row is effectively
            // unrecoverable. We skip rather than throw, matching the
            // "treat SQLite as optimization" guidance: a malformed row
            // shouldn't poison an otherwise good library read.
            guard let path, !path.isEmpty else {
                continue
            }

            let identifier = String(primaryKey)
            let fallbackTitle = URL(fileURLWithPath: path)
                .deletingPathExtension()
                .lastPathComponent
            let resolvedTitle = (title?.isEmpty == false) ? (title ?? fallbackTitle) : fallbackTitle

            let recordedAt = Date(timeIntervalSinceReferenceDate: date)
            // Apple stores `ZPATH` as either an absolute path
            // (`/Users/.../bar.m4a`) or a path relative to the library's
            // `Recordings/` directory (just `bar.m4a`). Absolute paths
            // pass through unchanged; relative paths are joined onto
            // `libraryURL` so the resulting `assetPath` always honours
            // ``VoiceMemoMetadata/assetPath``'s absolute-path contract.
            let assetURL: URL
            if path.hasPrefix("/") {
                assetURL = URL(fileURLWithPath: path)
            } else {
                assetURL = libraryURL.appendingPathComponent(path)
            }

            results.append(
                VoiceMemoMetadata(
                    identifier: identifier,
                    title: resolvedTitle,
                    recordedAt: recordedAt,
                    durationSeconds: duration,
                    assetPath: assetURL
                )
            )
        }

        return results
    }

    // MARK: - SQLite helpers

    private func openReadOnly(at url: URL) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let openResult = sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_READONLY,
            nil
        )
        guard openResult == SQLITE_OK, let handle else {
            let message = handle.map { lastErrorMessage(handle: $0) }
                ?? "sqlite3_open_v2 returned \(openResult)"
            sqlite3_close(handle)
            throw CloudRecordingsError.sqliteOpenFailed(reason: message)
        }
        return handle
    }

    /// Confirms that the expected table exists via `sqlite_master`,
    /// translating absence into ``CloudRecordingsError/schemaUnrecognized(reason:)``.
    ///
    /// Probing here (in addition to letting `sqlite3_prepare_v2` fail
    /// with "no such table") lets us emit a precise, caller-friendly
    /// message even when SQLite's diagnostic for a missing table is
    /// quirky on some platform builds.
    private func assertTableExists(_ name: String, on handle: OpaquePointer) throws {
        let sql = "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?"
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw CloudRecordingsError.sqliteOpenFailed(
                reason: "sqlite_master probe failed: \(lastErrorMessage(handle: handle))"
            )
        }
        defer { sqlite3_finalize(statement) }

        // SQLITE_TRANSIENT — copy the string buffer immediately rather
        // than retain a pointer that could dangle. -1 lets SQLite
        // compute strlen.
        let transient = unsafeBitCast(
            OpaquePointer(bitPattern: -1),
            to: sqlite3_destructor_type.self
        )
        let bindResult = sqlite3_bind_text(statement, 1, name, -1, transient)
        guard bindResult == SQLITE_OK else {
            throw CloudRecordingsError.sqliteOpenFailed(
                reason: "sqlite3_bind_text failed: \(lastErrorMessage(handle: handle))"
            )
        }

        let stepResult = sqlite3_step(statement)
        if stepResult == SQLITE_DONE {
            throw CloudRecordingsError.schemaUnrecognized(
                reason: "expected table \(name) not found in CloudRecordings.db"
            )
        }
        if stepResult != SQLITE_ROW {
            throw CloudRecordingsError.sqliteOpenFailed(
                reason: "sqlite_master step failed: \(lastErrorMessage(handle: handle))"
            )
        }
    }

    private func readText(_ statement: OpaquePointer?, column: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, column) else {
            return nil
        }
        return String(cString: cString)
    }

    private func lastErrorMessage(handle: OpaquePointer) -> String {
        guard let raw = sqlite3_errmsg(handle) else {
            return "unknown SQLite error"
        }
        return String(cString: raw)
    }
}
