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
///
/// Fixtures are wrapped in a ``Fixture`` value whose ``Fixture/tearDown()``
/// removes the per-test scratch directory. Mirrors the locator tests'
/// pattern so repeated local/CI runs don't accumulate stale
/// `dictamac-cloudrecordings-fixture-*` directories.
@Suite struct CloudRecordingsReaderTests {
    // MARK: - Fixture helpers

    /// Creates a per-test scratch directory under `NSTemporaryDirectory()`
    /// and returns a ``Fixture`` that owns its teardown. Callers `defer`
    /// `fixture.tearDown()` immediately after construction.
    private static func makeFixture() throws -> Fixture {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dictamac-cloudrecordings-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        return Fixture(directory: dir)
    }

    private struct Fixture {
        let directory: URL

        var defaultDatabaseURL: URL {
            directory.appendingPathComponent("CloudRecordings.db")
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Builds a synthetic `CloudRecordings.db` with the columns the
    /// reader expects. `rows` describes the fake recordings to insert
    /// (identifier-by-position only; the `ZCUSTOMLABEL`, `ZDATE`,
    /// `ZDURATION`, `ZPATH` columns receive the supplied values — any
    /// `nil` becomes a SQL `NULL`).
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
            if let title = row.title {
                sqlite3_bind_text(statement, 2, title, -1, transient)
            } else {
                sqlite3_bind_null(statement, 2)
            }
            if let date = row.dateSecondsSinceReference {
                sqlite3_bind_double(statement, 3, date)
            } else {
                sqlite3_bind_null(statement, 3)
            }
            if let duration = row.durationSeconds {
                sqlite3_bind_double(statement, 4, duration)
            } else {
                sqlite3_bind_null(statement, 4)
            }
            if let path = row.assetPath {
                sqlite3_bind_text(statement, 5, path, -1, transient)
            } else {
                sqlite3_bind_null(statement, 5)
            }
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
        let title: String?
        let dateSecondsSinceReference: Double?
        let durationSeconds: Double?
        let assetPath: String?

        init(
            primaryKey: Int64,
            title: String? = "synthetic-row",
            dateSecondsSinceReference: Double? = 0,
            durationSeconds: Double? = 0,
            assetPath: String? = "/tmp/dictamac-synthetic/row.m4a"
        ) {
            self.primaryKey = primaryKey
            self.title = title
            self.dateSecondsSinceReference = dateSecondsSinceReference
            self.durationSeconds = durationSeconds
            self.assetPath = assetPath
        }
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
        let fixture = try Self.makeFixture()
        defer { fixture.tearDown() }
        let dbURL = fixture.defaultDatabaseURL
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

        let reader = DefaultCloudRecordingsReader(databaseURL: dbURL, libraryURL: fixture.directory)
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
        let fixture = try Self.makeFixture()
        defer { fixture.tearDown() }
        let dbURL = fixture.directory.appendingPathComponent("does-not-exist.db")
        let reader = DefaultCloudRecordingsReader(databaseURL: dbURL, libraryURL: fixture.directory)

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
        let fixture = try Self.makeFixture()
        defer { fixture.tearDown() }
        let dbURL = fixture.defaultDatabaseURL
        try Self.writeFixtureDatabase(at: dbURL, rows: [])

        let reader = DefaultCloudRecordingsReader(databaseURL: dbURL, libraryURL: fixture.directory)
        let recordings = try reader.recordings()

        #expect(recordings.isEmpty)
    }

    // MARK: - Schema drift — column renamed

    @Test func schemaDriftRenamedColumnThrowsSchemaUnrecognized() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.tearDown() }
        let dbURL = fixture.defaultDatabaseURL
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

        let reader = DefaultCloudRecordingsReader(databaseURL: dbURL, libraryURL: fixture.directory)

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
        let fixture = try Self.makeFixture()
        defer { fixture.tearDown() }
        let dbURL = fixture.defaultDatabaseURL
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

        let reader = DefaultCloudRecordingsReader(databaseURL: dbURL, libraryURL: fixture.directory)

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

    // MARK: - ZPATH resolution

    /// Apple stores some `ZPATH` rows as bare filenames relative to the
    /// `Recordings/` library directory rather than absolute paths. The
    /// reader must join those onto its injected `libraryURL` so the
    /// resulting `assetPath` is absolute and points at the right file —
    /// `URL(fileURLWithPath:)` alone would resolve a relative string
    /// against the process working directory, which breaks downstream
    /// transcription. Regression for the Copilot review on PR #48.
    @Test func relativeZPathIsResolvedAgainstLibraryURL() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.tearDown() }
        let dbURL = fixture.defaultDatabaseURL
        try Self.writeFixtureDatabase(
            at: dbURL,
            rows: [
                FixtureRow(
                    primaryKey: 42,
                    title: "relative-recording",
                    dateSecondsSinceReference: 100,
                    durationSeconds: 1.5,
                    assetPath: "my-recording.m4a"
                ),
            ]
        )

        let reader = DefaultCloudRecordingsReader(databaseURL: dbURL, libraryURL: fixture.directory)
        let recordings = try reader.recordings()

        let memo = try #require(recordings.first { $0.identifier == "42" })
        #expect(memo.assetPath == fixture.directory.appendingPathComponent("my-recording.m4a"))
    }

    /// `ZPATH` values that start with `/` are already absolute and must
    /// pass through unchanged. Joining them onto `libraryURL` would
    /// produce a doubled-up nonsense path like
    /// `<library>/private/tmp/something.m4a`. Regression for the Copilot
    /// review on PR #48.
    @Test func absoluteZPathIsReturnedUnchanged() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.tearDown() }
        let dbURL = fixture.defaultDatabaseURL
        let absolutePath = "/tmp/dictamac-synthetic/absolute-recording.m4a"
        try Self.writeFixtureDatabase(
            at: dbURL,
            rows: [
                FixtureRow(
                    primaryKey: 7,
                    title: "absolute-recording",
                    dateSecondsSinceReference: 100,
                    durationSeconds: 1.5,
                    assetPath: absolutePath
                ),
            ]
        )

        let reader = DefaultCloudRecordingsReader(databaseURL: dbURL, libraryURL: fixture.directory)
        let recordings = try reader.recordings()

        let memo = try #require(recordings.first { $0.identifier == "7" })
        #expect(memo.assetPath == URL(fileURLWithPath: absolutePath))
        // Negative assertion — guard against the "double-prefix" bug
        // (joining absolute paths onto libraryURL).
        #expect(!memo.assetPath.path.contains(fixture.directory.path))
    }

    // MARK: - Row skipping for unusable / NULL columns

    /// A row whose `ZPATH` is the empty string is unusable (no asset to
    /// open) and must be skipped, not surfaced as a memo with an empty
    /// `assetPath`. The reader's documented behavior — pin it.
    @Test func rowWithEmptyZPathIsSkipped() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.tearDown() }
        let dbURL = fixture.defaultDatabaseURL
        try Self.writeFixtureDatabase(
            at: dbURL,
            rows: [
                FixtureRow(
                    primaryKey: 1,
                    title: "well-formed",
                    dateSecondsSinceReference: 100,
                    durationSeconds: 1,
                    assetPath: "/tmp/dictamac-synthetic/good.m4a"
                ),
                FixtureRow(
                    primaryKey: 2,
                    title: "empty-path",
                    dateSecondsSinceReference: 200,
                    durationSeconds: 2,
                    assetPath: ""
                ),
            ]
        )

        let reader = DefaultCloudRecordingsReader(databaseURL: dbURL, libraryURL: fixture.directory)
        let recordings = try reader.recordings()

        #expect(recordings.count == 1)
        #expect(recordings.first?.identifier == "1")
    }

    /// A row whose `ZPATH` is `NULL` should be skipped for the same
    /// reason as the empty-string case.
    @Test func rowWithNullZPathIsSkipped() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.tearDown() }
        let dbURL = fixture.defaultDatabaseURL
        try Self.writeFixtureDatabase(
            at: dbURL,
            rows: [
                FixtureRow(
                    primaryKey: 1,
                    title: "well-formed",
                    dateSecondsSinceReference: 100,
                    durationSeconds: 1,
                    assetPath: "/tmp/dictamac-synthetic/good.m4a"
                ),
                FixtureRow(
                    primaryKey: 2,
                    title: "null-path",
                    dateSecondsSinceReference: 200,
                    durationSeconds: 2,
                    assetPath: nil
                ),
            ]
        )

        let reader = DefaultCloudRecordingsReader(databaseURL: dbURL, libraryURL: fixture.directory)
        let recordings = try reader.recordings()

        #expect(recordings.count == 1)
        #expect(recordings.first?.identifier == "1")
    }

    /// `sqlite3_column_double` returns `0.0` for NULL columns with no
    /// way to distinguish that from a real zero. A NULL `ZDATE` would
    /// silently report the row as recorded at the Core Data epoch
    /// (~2001-01-01), poisoning recency ordering and date queries. The
    /// reader checks `sqlite3_column_type` and skips such rows.
    @Test func rowWithNullZDateIsSkipped() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.tearDown() }
        let dbURL = fixture.defaultDatabaseURL
        try Self.writeFixtureDatabase(
            at: dbURL,
            rows: [
                FixtureRow(
                    primaryKey: 1,
                    title: "well-formed",
                    dateSecondsSinceReference: 100,
                    durationSeconds: 1,
                    assetPath: "/tmp/dictamac-synthetic/good.m4a"
                ),
                FixtureRow(
                    primaryKey: 2,
                    title: "null-date",
                    dateSecondsSinceReference: nil,
                    durationSeconds: 2,
                    assetPath: "/tmp/dictamac-synthetic/missing-date.m4a"
                ),
            ]
        )

        let reader = DefaultCloudRecordingsReader(databaseURL: dbURL, libraryURL: fixture.directory)
        let recordings = try reader.recordings()

        #expect(recordings.count == 1)
        #expect(recordings.first?.identifier == "1")
    }

    /// Mirror of the NULL-date case: a NULL `ZDURATION` would silently
    /// report a zero-length memo. Skip rather than fabricate metadata.
    @Test func rowWithNullZDurationIsSkipped() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.tearDown() }
        let dbURL = fixture.defaultDatabaseURL
        try Self.writeFixtureDatabase(
            at: dbURL,
            rows: [
                FixtureRow(
                    primaryKey: 1,
                    title: "well-formed",
                    dateSecondsSinceReference: 100,
                    durationSeconds: 1,
                    assetPath: "/tmp/dictamac-synthetic/good.m4a"
                ),
                FixtureRow(
                    primaryKey: 2,
                    title: "null-duration",
                    dateSecondsSinceReference: 200,
                    durationSeconds: nil,
                    assetPath: "/tmp/dictamac-synthetic/missing-duration.m4a"
                ),
            ]
        )

        let reader = DefaultCloudRecordingsReader(databaseURL: dbURL, libraryURL: fixture.directory)
        let recordings = try reader.recordings()

        #expect(recordings.count == 1)
        #expect(recordings.first?.identifier == "1")
    }

    // MARK: - Title fallback to filename stem

    /// When `ZCUSTOMLABEL` is NULL, the reader falls back to the
    /// filename stem (path minus extension and parent directory). Pins
    /// the user-visible behavior described in the reader's docstring.
    @Test func titleFallsBackToFilenameStemWhenZCustomLabelIsNull() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.tearDown() }
        let dbURL = fixture.defaultDatabaseURL
        try Self.writeFixtureDatabase(
            at: dbURL,
            rows: [
                FixtureRow(
                    primaryKey: 1,
                    title: nil,
                    dateSecondsSinceReference: 100,
                    durationSeconds: 1.5,
                    assetPath: "/tmp/dictamac-synthetic/null-label-stem.m4a"
                ),
            ]
        )

        let reader = DefaultCloudRecordingsReader(databaseURL: dbURL, libraryURL: fixture.directory)
        let recordings = try reader.recordings()

        let memo = try #require(recordings.first { $0.identifier == "1" })
        #expect(memo.title == "null-label-stem")
    }

    /// Same behavior when `ZCUSTOMLABEL` is the empty string rather than
    /// NULL — both are treated as "no user title".
    @Test func titleFallsBackToFilenameStemWhenZCustomLabelIsEmpty() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.tearDown() }
        let dbURL = fixture.defaultDatabaseURL
        try Self.writeFixtureDatabase(
            at: dbURL,
            rows: [
                FixtureRow(
                    primaryKey: 1,
                    title: "",
                    dateSecondsSinceReference: 100,
                    durationSeconds: 1.5,
                    assetPath: "/tmp/dictamac-synthetic/empty-label-stem.m4a"
                ),
            ]
        )

        let reader = DefaultCloudRecordingsReader(databaseURL: dbURL, libraryURL: fixture.directory)
        let recordings = try reader.recordings()

        let memo = try #require(recordings.first { $0.identifier == "1" })
        #expect(memo.title == "empty-label-stem")
    }

    // MARK: - Operation failure exercised end-to-end

    /// Points the reader at a path that exists but is not a SQLite
    /// database. `sqlite3_open_v2` may accept the file handle (it does
    /// little validation up front), but `sqlite_master` probing or
    /// prepare will fail with a `SQLITE_NOTADB`-class error. Either way
    /// the failure must surface as
    /// ``CloudRecordingsError/sqliteOperationFailed(operation:code:reason:)``
    /// so the resolver knows to attempt the filesystem fallback. Pins
    /// the fallback signal end-to-end.
    @Test func garbageBytesAtDatabaseURLThrowsSqliteOperationFailed() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.tearDown() }
        let dbURL = fixture.defaultDatabaseURL
        // 128 bytes of non-SQLite content. SQLite's file magic starts
        // with "SQLite format 3\0"; this deliberately doesn't.
        let garbage = Data(repeating: 0xAB, count: 128)
        try garbage.write(to: dbURL)

        let reader = DefaultCloudRecordingsReader(databaseURL: dbURL, libraryURL: fixture.directory)

        do {
            _ = try reader.recordings()
            Issue.record("Expected throw for non-SQLite file at database URL")
        } catch let error as CloudRecordingsError {
            guard case .sqliteOperationFailed = error else {
                Issue.record("Expected .sqliteOperationFailed, got \(error)")
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

        let operationFailed = CloudRecordingsError.sqliteOperationFailed(
            operation: "sqlite3_prepare_v2",
            code: 1,
            reason: "permission denied"
        )
        #expect(operationFailed.description.contains("sqlite3_prepare_v2"))
        #expect(operationFailed.description.contains("permission denied"))
        #expect(operationFailed.description.contains("1"))

        let schema = CloudRecordingsError.schemaUnrecognized(
            reason: "missing column ZDATE"
        )
        #expect(schema.description.contains("missing column ZDATE"))
    }
}
