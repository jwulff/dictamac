import Foundation
import SQLite3
import Testing
@testable import DictamacVoiceMemos

/// Tests for ``DefaultCloudRecordingsReader``.
///
/// Each test synthesizes a fresh tiny SQLite database in
/// `NSTemporaryDirectory()`, writes a handful of fake rows (no PII —
/// this is a public repo, see CLAUDE.md "Public Open Source Project"),
/// and exercises the reader against that fixture. The reader itself
/// only opens databases read-only, so the fixture creation lives in
/// these tests rather than alongside production code.
///
/// Why synthesize at test time instead of committing a binary fixture?
/// Two reasons: (1) the fixture builder doubles as living documentation
/// of the schema we assume; (2) we can scaffold schema-drift variants
/// (renamed columns, missing tables) without committing multiple
/// `.db` blobs to git.
@Suite struct CloudRecordingsReaderTests {
    // MARK: - Fixture helpers

    /// Returns a temp directory unique to this test plus a `.db` file
    /// path inside it. The directory is created on disk; the database
    /// file is NOT — callers decide whether to populate it.
    private static func makeFixtureDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dictamac-cloudrecordings-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        return dir
    }

    /// SQLite stores `NSDate` timestamps as seconds since
    /// `2001-01-01 00:00:00 UTC` (the Core Data epoch). Tests construct
    /// fixture rows using this offset so the reader's date conversion
    /// can be asserted against round-trippable values.
    private static let coreDataReferenceDate = Date(timeIntervalSinceReferenceDate: 0)

    /// Builds a synthetic `CloudRecordings.db` with the columns the
    /// reader expects. `rows` describes the fake recordings to insert
    /// (identifier-by-position only; the `ZCUSTOMLABEL`, `ZDATE`,
    /// `ZDURATION`, `ZPATH` columns receive the supplied values).
    ///
    /// Returns the URL of the freshly-written database.
    @discardableResult
    private static func writeFixtureDatabase(
        at url: URL,
        rows: [FixtureRow],
        tableName: String = "ZCLOUDRECORDING",
        columnNames: FixtureColumnNames = .canonical
    ) throws -> URL {
        var handle: OpaquePointer?
        let openResult = sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            nil
        )
        guard openResult == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw FixtureError.openFailed
        }
        defer { sqlite3_close(handle) }

        let createSQL = """
        CREATE TABLE \(tableName) (
            Z_PK INTEGER PRIMARY KEY,
            \(columnNames.title) TEXT,
            \(columnNames.date) REAL,
            \(columnNames.duration) REAL,
            \(columnNames.path) TEXT
        )
        """
        try execute(createSQL, on: handle)

        for row in rows {
            let insertSQL = """
            INSERT INTO \(tableName)
                (Z_PK, \(columnNames.title), \(columnNames.date), \(columnNames.duration), \(columnNames.path))
            VALUES (?, ?, ?, ?, ?)
            """
            var statement: OpaquePointer?
            let prepResult = sqlite3_prepare_v2(handle, insertSQL, -1, &statement, nil)
            guard prepResult == SQLITE_OK, let statement else {
                throw FixtureError.prepareFailed
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, row.primaryKey)
            // SQLITE_TRANSIENT tells SQLite to copy the string buffer
            // rather than retain a pointer that may dangle; -1 lets
            // SQLite compute string length via strlen.
            let transient = unsafeBitCast(
                OpaquePointer(bitPattern: -1),
                to: sqlite3_destructor_type.self
            )
            sqlite3_bind_text(statement, 2, row.title, -1, transient)
            sqlite3_bind_double(statement, 3, row.dateSecondsSinceReference)
            sqlite3_bind_double(statement, 4, row.durationSeconds)
            sqlite3_bind_text(statement, 5, row.assetPath, -1, transient)
            let stepResult = sqlite3_step(statement)
            guard stepResult == SQLITE_DONE else {
                throw FixtureError.insertFailed
            }
        }

        return url
    }

    private static func execute(_ sql: String, on handle: OpaquePointer) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        if result != SQLITE_OK {
            sqlite3_free(errorPointer)
            throw FixtureError.execFailed
        }
    }

    private struct FixtureRow {
        let primaryKey: Int64
        let title: String
        let dateSecondsSinceReference: Double
        let durationSeconds: Double
        let assetPath: String
    }

    private struct FixtureColumnNames {
        let title: String
        let date: String
        let duration: String
        let path: String

        static let canonical = FixtureColumnNames(
            title: "ZCUSTOMLABEL",
            date: "ZDATE",
            duration: "ZDURATION",
            path: "ZPATH"
        )
    }

    private enum FixtureError: Error {
        case openFailed
        case prepareFailed
        case insertFailed
        case execFailed
    }

    // MARK: - Happy path

    @Test func recordingsReturnsAllRowsFromSyntheticDatabase() throws {
        let dir = try Self.makeFixtureDirectory()
        let dbURL = dir.appendingPathComponent("CloudRecordings.db")
        let rows: [FixtureRow] = [
            FixtureRow(
                primaryKey: 1,
                title: "test-recording-alpha",
                dateSecondsSinceReference: 100,
                durationSeconds: 12.5,
                assetPath: "/tmp/dictamac-synthetic/alpha.m4a"
            ),
            FixtureRow(
                primaryKey: 2,
                title: "test-recording-bravo",
                dateSecondsSinceReference: 200,
                durationSeconds: 7.25,
                assetPath: "/tmp/dictamac-synthetic/bravo.m4a"
            ),
            FixtureRow(
                primaryKey: 3,
                title: "test-recording-charlie",
                dateSecondsSinceReference: 300,
                durationSeconds: 0,
                assetPath: "/tmp/dictamac-synthetic/charlie.m4a"
            ),
        ]
        try Self.writeFixtureDatabase(at: dbURL, rows: rows)

        let reader = DefaultCloudRecordingsReader(databaseURL: dbURL)
        let recordings = try reader.recordings()

        #expect(recordings.count == 3)

        let alpha = try #require(recordings.first { $0.identifier == "1" })
        #expect(alpha.title == "test-recording-alpha")
        #expect(alpha.recordedAt == Date(timeIntervalSinceReferenceDate: 100))
        #expect(alpha.durationSeconds == 12.5)
        #expect(alpha.assetPath == URL(fileURLWithPath: "/tmp/dictamac-synthetic/alpha.m4a"))

        let bravo = try #require(recordings.first { $0.identifier == "2" })
        #expect(bravo.title == "test-recording-bravo")
        #expect(bravo.recordedAt == Date(timeIntervalSinceReferenceDate: 200))
        #expect(bravo.durationSeconds == 7.25)

        let charlie = try #require(recordings.first { $0.identifier == "3" })
        #expect(charlie.title == "test-recording-charlie")
        #expect(charlie.durationSeconds == 0)
    }

    // MARK: - Missing file

    @Test func missingDatabaseThrowsSqliteUnavailable() throws {
        let dir = try Self.makeFixtureDirectory()
        let dbURL = dir.appendingPathComponent("does-not-exist.db")
        let reader = DefaultCloudRecordingsReader(databaseURL: dbURL)

        #expect(throws: CloudRecordingsError.self) {
            try reader.recordings()
        }

        do {
            _ = try reader.recordings()
            Issue.record("Expected throw")
        } catch let error as CloudRecordingsError {
            guard case .sqliteUnavailable = error else {
                Issue.record("Expected .sqliteUnavailable, got \(error)")
                return
            }
        }
    }

    // MARK: - Empty database (table exists, no rows)

    @Test func emptyDatabaseReturnsEmptyArrayNotError() throws {
        let dir = try Self.makeFixtureDirectory()
        let dbURL = dir.appendingPathComponent("CloudRecordings.db")
        try Self.writeFixtureDatabase(at: dbURL, rows: [])

        let reader = DefaultCloudRecordingsReader(databaseURL: dbURL)
        let recordings = try reader.recordings()

        #expect(recordings.isEmpty)
    }

    // MARK: - Schema drift — column renamed

    @Test func schemaDriftRenamedColumnThrowsSchemaUnrecognized() throws {
        let dir = try Self.makeFixtureDirectory()
        let dbURL = dir.appendingPathComponent("CloudRecordings.db")
        let drifted = FixtureColumnNames(
            title: "ZCUSTOMLABEL",
            date: "ZRECORDEDAT", // renamed from ZDATE — simulates macOS 27 schema drift
            duration: "ZDURATION",
            path: "ZPATH"
        )
        try Self.writeFixtureDatabase(
            at: dbURL,
            rows: [
                FixtureRow(
                    primaryKey: 1,
                    title: "test-recording-alpha",
                    dateSecondsSinceReference: 0,
                    durationSeconds: 1,
                    assetPath: "/tmp/x.m4a"
                ),
            ],
            columnNames: drifted
        )

        let reader = DefaultCloudRecordingsReader(databaseURL: dbURL)

        do {
            _ = try reader.recordings()
            Issue.record("Expected throw for schema drift")
        } catch let error as CloudRecordingsError {
            guard case .schemaUnrecognized = error else {
                Issue.record("Expected .schemaUnrecognized, got \(error)")
                return
            }
        }
    }

    // MARK: - Schema drift — table renamed

    @Test func schemaDriftRenamedTableThrowsSchemaUnrecognized() throws {
        let dir = try Self.makeFixtureDirectory()
        let dbURL = dir.appendingPathComponent("CloudRecordings.db")
        try Self.writeFixtureDatabase(
            at: dbURL,
            rows: [
                FixtureRow(
                    primaryKey: 1,
                    title: "test-recording-alpha",
                    dateSecondsSinceReference: 0,
                    durationSeconds: 1,
                    assetPath: "/tmp/x.m4a"
                ),
            ],
            tableName: "ZRECORDING" // renamed from ZCLOUDRECORDING
        )

        let reader = DefaultCloudRecordingsReader(databaseURL: dbURL)

        do {
            _ = try reader.recordings()
            Issue.record("Expected throw for table rename")
        } catch let error as CloudRecordingsError {
            guard case .schemaUnrecognized = error else {
                Issue.record("Expected .schemaUnrecognized, got \(error)")
                return
            }
        }
    }

    // MARK: - Error rendering

    @Test func errorDescriptionsAreHumanReadable() {
        let unavailable = CloudRecordingsError.sqliteUnavailable(
            reason: "file not at /tmp/x.db"
        )
        #expect(unavailable.description.contains("file not at /tmp/x.db"))

        let openFailed = CloudRecordingsError.sqliteOpenFailed(
            reason: "permission denied"
        )
        #expect(openFailed.description.contains("permission denied"))

        let schema = CloudRecordingsError.schemaUnrecognized(
            reason: "missing column ZDATE"
        )
        #expect(schema.description.contains("missing column ZDATE"))
    }
}
