import Foundation
import Testing
import DictamacCore
@testable import DictamacVoiceMemos

/// Tests for ``DefaultVoiceMemosResolver``.
///
/// Uses test-only mocks (Tests/.../Mocks/) for the library locator,
/// SQLite reader, and filesystem scanner — no real CloudRecordings.db
/// or `~/Library/...` access. `now` is always passed in so date-range
/// queries are deterministic.
@Suite struct DefaultVoiceMemosResolverTests {

    // MARK: - Fixture builders

    /// A fixed reference instant — Tuesday, 2026-05-12 14:30:00 in the
    /// system timezone. Resolved through `Calendar.current` so the
    /// test asserts against the same calendar the production code
    /// uses; this keeps the suite green across DST boundaries.
    private static let now: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 5
        components.day = 12
        components.hour = 14
        components.minute = 30
        components.second = 0
        components.timeZone = TimeZone.current
        return Calendar.current.date(from: components) ?? Date(
            timeIntervalSince1970: 1_778_000_000
        )
    }()

    /// Convenience: build a `VoiceMemoMetadata` with sensible defaults.
    private static func memo(
        identifier: String,
        title: String,
        at recordedAt: Date,
        duration: TimeInterval = 30.0,
        path: String? = nil
    ) -> VoiceMemoMetadata {
        return VoiceMemoMetadata(
            identifier: identifier,
            title: title,
            recordedAt: recordedAt,
            durationSeconds: duration,
            assetPath: URL(fileURLWithPath: path ?? "/tmp/dictamac-test/\(identifier).m4a")
        )
    }

    /// Build a stub locator pointing at a throwaway URL — the real
    /// path is irrelevant because the reader/scanner mocks ignore it.
    private static func stubLocation() -> VoiceMemosLibraryLocation {
        let url = URL(fileURLWithPath: "/tmp/dictamac-test/voice-memos-library")
        return VoiceMemosLibraryLocation(url: url, probedPaths: [url])
    }

    /// Returns midnight (start-of-day in system timezone) for the
    /// calendar day containing `referenceDate`, then offsets by
    /// `hours`. Used to place memos at specific times of day relative
    /// to `now`.
    private static func dateAtHour(_ hours: Double, on referenceDate: Date) -> Date {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: referenceDate)
        return startOfDay.addingTimeInterval(hours * 3600)
    }

    /// Same as `dateAtHour(_:on:)` but offsets the calendar day first.
    private static func dateAtHour(
        _ hours: Double,
        daysOffset days: Int,
        from referenceDate: Date
    ) -> Date {
        let calendar = Calendar.current
        let startOfReferenceDay = calendar.startOfDay(for: referenceDate)
        let offsetDay = calendar.date(
            byAdding: .day,
            value: days,
            to: startOfReferenceDay
        ) ?? startOfReferenceDay.addingTimeInterval(Double(days) * 86_400)
        return offsetDay.addingTimeInterval(hours * 3600)
    }

    /// Build a resolver wired to the supplied mocks. Defaults to a
    /// stub locator pointing at a throwaway URL.
    private static func resolver(
        memos: [VoiceMemoMetadata] = [],
        readerError: CloudRecordingsError? = nil,
        scannerMemos: [VoiceMemoMetadata] = [],
        locator: VoiceMemosLibraryLocator? = nil,
        diagnosticSink: (@Sendable (String) -> Void)? = nil
    ) -> DefaultVoiceMemosResolver {
        let actualLocator = locator
            ?? MockVoiceMemosLibraryLocator(location: stubLocation())
        let reader: MockCloudRecordingsReader = {
            if let readerError {
                return MockCloudRecordingsReader(error: readerError)
            }
            return MockCloudRecordingsReader(memos: memos)
        }()
        let scanner = MockFilesystemRecordingsScanner(memos: scannerMemos)
        return DefaultVoiceMemosResolver(
            locator: actualLocator,
            sqliteReaderFactory: { _, _ in reader },
            filesystemScanner: scanner,
            diagnosticSink: diagnosticSink
        )
    }

    // MARK: - Time anchor: today

    @Test
    func timeAnchorTodayFiltersToTodaysCalendarDay() throws {
        let memos = [
            Self.memo(
                identifier: "1",
                title: "earlier-today",
                at: Self.dateAtHour(9, on: Self.now)
            ),
            Self.memo(
                identifier: "2",
                title: "yesterday-evening",
                at: Self.dateAtHour(20, daysOffset: -1, from: Self.now)
            ),
        ]
        let r = Self.resolver(memos: memos)

        let result = try r.resolve(.timeAnchor(.today), now: Self.now)

        #expect(result.identifier == "1")
    }

    @Test
    func timeAnchorTodayPicksMostRecentWhenMultipleMatch() throws {
        let memos = [
            Self.memo(
                identifier: "early",
                title: "early",
                at: Self.dateAtHour(8, on: Self.now)
            ),
            Self.memo(
                identifier: "late",
                title: "late",
                at: Self.dateAtHour(13, on: Self.now)
            ),
            Self.memo(
                identifier: "mid",
                title: "mid",
                at: Self.dateAtHour(11, on: Self.now)
            ),
        ]
        let r = Self.resolver(memos: memos)

        let result = try r.resolve(.timeAnchor(.today), now: Self.now)

        #expect(result.identifier == "late")
    }

    @Test
    func timeAnchorTodayThrowsWhenNothingMatches() {
        let memos = [
            Self.memo(
                identifier: "old",
                title: "old",
                at: Self.dateAtHour(10, daysOffset: -5, from: Self.now)
            ),
        ]
        let r = Self.resolver(memos: memos)

        do {
            _ = try r.resolve(.timeAnchor(.today), now: Self.now)
            Issue.record("expected DictamacError.voiceMemoNotFound")
        } catch let DictamacError.voiceMemoNotFound(query) {
            #expect(query == "today")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // MARK: - Time anchor: yesterday

    @Test
    func timeAnchorYesterdayFiltersToPreviousDay() throws {
        let memos = [
            Self.memo(
                identifier: "yesterday-1",
                title: "y1",
                at: Self.dateAtHour(10, daysOffset: -1, from: Self.now)
            ),
            Self.memo(
                identifier: "yesterday-2",
                title: "y2",
                at: Self.dateAtHour(18, daysOffset: -1, from: Self.now)
            ),
            Self.memo(
                identifier: "today",
                title: "t",
                at: Self.dateAtHour(8, on: Self.now)
            ),
        ]
        let r = Self.resolver(memos: memos)

        let result = try r.resolve(.timeAnchor(.yesterday), now: Self.now)

        // Both yesterday-* match; recency tie-break gives `yesterday-2`.
        #expect(result.identifier == "yesterday-2")
    }

    // MARK: - Time anchor: this morning

    @Test
    func timeAnchorThisMorningFiltersToTodayBeforeNoon() throws {
        let memos = [
            Self.memo(
                identifier: "morning-early",
                title: "m1",
                at: Self.dateAtHour(7, on: Self.now)
            ),
            Self.memo(
                identifier: "morning-late",
                title: "m2",
                at: Self.dateAtHour(11.5, on: Self.now)
            ),
            // Exactly noon → excluded by half-open [00:00, 12:00).
            Self.memo(
                identifier: "noon",
                title: "noon",
                at: Self.dateAtHour(12, on: Self.now)
            ),
            // Afternoon → excluded.
            Self.memo(
                identifier: "afternoon",
                title: "afternoon",
                at: Self.dateAtHour(14, on: Self.now)
            ),
        ]
        let r = Self.resolver(memos: memos)

        let result = try r.resolve(.timeAnchor(.thisMorning), now: Self.now)

        #expect(result.identifier == "morning-late")
    }

    @Test
    func timeAnchorThisMorningExcludesNoonExactly() {
        let memos = [
            Self.memo(
                identifier: "noon",
                title: "noon",
                at: Self.dateAtHour(12, on: Self.now)
            ),
        ]
        let r = Self.resolver(memos: memos)

        do {
            _ = try r.resolve(.timeAnchor(.thisMorning), now: Self.now)
            Issue.record("expected DictamacError.voiceMemoNotFound — noon excluded")
        } catch DictamacError.voiceMemoNotFound {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // MARK: - ISO date

    @Test
    func isoDateFiltersToThatCalendarDay() throws {
        let targetDay = Self.dateAtHour(0, daysOffset: -3, from: Self.now)
        let memos = [
            Self.memo(
                identifier: "target",
                title: "target",
                at: Self.dateAtHour(15, daysOffset: -3, from: Self.now)
            ),
            Self.memo(
                identifier: "off-by-one",
                title: "off",
                at: Self.dateAtHour(15, daysOffset: -4, from: Self.now)
            ),
        ]
        let r = Self.resolver(memos: memos)

        let result = try r.resolve(.isoDate(targetDay), now: Self.now)

        #expect(result.identifier == "target")
    }

    @Test
    func isoDateMultipleMatchesPicksMostRecent() throws {
        let targetDay = Self.dateAtHour(0, daysOffset: -2, from: Self.now)
        let memos = [
            Self.memo(
                identifier: "earlier",
                title: "earlier",
                at: Self.dateAtHour(8, daysOffset: -2, from: Self.now)
            ),
            Self.memo(
                identifier: "later",
                title: "later",
                at: Self.dateAtHour(20, daysOffset: -2, from: Self.now)
            ),
        ]
        let r = Self.resolver(memos: memos)

        let result = try r.resolve(.isoDate(targetDay), now: Self.now)

        #expect(result.identifier == "later")
    }

    // MARK: - Identifier exact match

    @Test
    func identifierExactMatchWins() throws {
        let memos = [
            Self.memo(
                identifier: "42",
                title: "weekly review",
                at: Self.dateAtHour(10, on: Self.now)
            ),
            Self.memo(
                identifier: "7",
                title: "standup notes",
                at: Self.dateAtHour(11, on: Self.now)
            ),
        ]
        let r = Self.resolver(memos: memos)

        let result = try r.resolve(.identifier("42"), now: Self.now)

        #expect(result.identifier == "42")
    }

    // MARK: - Identifier miss → fuzzy fallback

    @Test
    func identifierMissFallsBackToFuzzyTitleSearch() throws {
        let memos = [
            Self.memo(
                identifier: "100",
                title: "Coffee chat with Alice",
                at: Self.dateAtHour(10, on: Self.now)
            ),
            Self.memo(
                identifier: "200",
                title: "Standup notes",
                at: Self.dateAtHour(11, on: Self.now)
            ),
        ]
        let r = Self.resolver(memos: memos)

        // "alice" is not an identifier in the index → fall back to
        // fuzzy and match the title containing "Alice" case-insensitively.
        let result = try r.resolve(.identifier("Alice"), now: Self.now)

        #expect(result.identifier == "100")
    }

    @Test
    func identifierMissWithNoFuzzyMatchThrows() {
        let memos = [
            Self.memo(
                identifier: "100",
                title: "weekly review",
                at: Self.dateAtHour(10, on: Self.now)
            ),
        ]
        let r = Self.resolver(memos: memos)

        do {
            _ = try r.resolve(.identifier("doesnotexist"), now: Self.now)
            Issue.record("expected DictamacError.voiceMemoNotFound")
        } catch let DictamacError.voiceMemoNotFound(query) {
            #expect(query == "doesnotexist")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // MARK: - Fuzzy title

    @Test
    func fuzzyTitleCaseInsensitiveSubstringMatch() throws {
        let memos = [
            Self.memo(
                identifier: "1",
                title: "Weekly Review",
                at: Self.dateAtHour(10, on: Self.now)
            ),
            Self.memo(
                identifier: "2",
                title: "Standup Notes",
                at: Self.dateAtHour(11, on: Self.now)
            ),
        ]
        let r = Self.resolver(memos: memos)

        let result = try r.resolve(.fuzzyTitle("weekly"), now: Self.now)

        #expect(result.identifier == "1")
    }

    @Test
    func fuzzyTitleMultipleMatchesPicksMostRecent() throws {
        let memos = [
            Self.memo(
                identifier: "1",
                title: "Standup notes — Monday",
                at: Self.dateAtHour(10, daysOffset: -3, from: Self.now)
            ),
            Self.memo(
                identifier: "2",
                title: "Standup recap — Tuesday",
                at: Self.dateAtHour(10, daysOffset: -2, from: Self.now)
            ),
            Self.memo(
                identifier: "3",
                title: "Coffee chat",
                at: Self.dateAtHour(10, daysOffset: -1, from: Self.now)
            ),
        ]
        let r = Self.resolver(memos: memos)

        let result = try r.resolve(.fuzzyTitle("standup"), now: Self.now)

        // Both "Standup" titles match; recency picks Tuesday's recap.
        #expect(result.identifier == "2")
    }

    @Test
    func fuzzyTitleNoMatchThrows() {
        let memos = [
            Self.memo(
                identifier: "1",
                title: "Weekly Review",
                at: Self.dateAtHour(10, on: Self.now)
            ),
        ]
        let r = Self.resolver(memos: memos)

        do {
            _ = try r.resolve(.fuzzyTitle("nope"), now: Self.now)
            Issue.record("expected DictamacError.voiceMemoNotFound")
        } catch let DictamacError.voiceMemoNotFound(query) {
            #expect(query == "nope")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    /// Whitespace normalization per CLAUDE.md: collapse internal
    /// whitespace before substring compare. A needle with stray
    /// internal spaces still finds the canonical title.
    @Test
    func fuzzyTitleCollapsesInternalWhitespace() throws {
        let memos = [
            Self.memo(
                identifier: "1",
                title: "Standup notes",
                at: Self.dateAtHour(10, on: Self.now)
            ),
        ]
        let r = Self.resolver(memos: memos)

        let result = try r.resolve(.fuzzyTitle("standup   notes"), now: Self.now)

        #expect(result.identifier == "1")
    }

    // MARK: - Filesystem fallback on SQLite failure

    @Test
    func sqliteUnavailableFallsBackToFilesystemScanner() throws {
        let scannerMemos = [
            Self.memo(
                identifier: "fs-1",
                title: "filesystem memo",
                at: Self.dateAtHour(10, on: Self.now)
            ),
        ]
        let diagnostics = DiagnosticSink()
        let r = Self.resolver(
            readerError: .sqliteUnavailable(reason: "file missing"),
            scannerMemos: scannerMemos,
            diagnosticSink: diagnostics.callback
        )

        let result = try r.resolve(.timeAnchor(.today), now: Self.now)

        #expect(result.identifier == "fs-1")
        let captured = diagnostics.snapshot()
        #expect(captured.count == 1)
        #expect(captured.first?.contains("CloudRecordings.db unavailable") == true)
    }

    @Test
    func sqliteSchemaDriftFallsBackToFilesystemScanner() throws {
        let scannerMemos = [
            Self.memo(
                identifier: "fs-1",
                title: "filesystem memo",
                at: Self.dateAtHour(10, on: Self.now)
            ),
        ]
        let r = Self.resolver(
            readerError: .schemaUnrecognized(reason: "missing ZDATE column"),
            scannerMemos: scannerMemos
        )

        let result = try r.resolve(.timeAnchor(.today), now: Self.now)

        #expect(result.identifier == "fs-1")
    }

    @Test
    func sqliteOperationFailedAlsoFallsBackToFilesystemScanner() throws {
        let scannerMemos = [
            Self.memo(
                identifier: "fs-1",
                title: "filesystem memo",
                at: Self.dateAtHour(10, on: Self.now)
            ),
        ]
        let r = Self.resolver(
            readerError: .sqliteOperationFailed(
                operation: "sqlite3_step",
                code: 11,
                reason: "database corrupt"
            ),
            scannerMemos: scannerMemos
        )

        let result = try r.resolve(.timeAnchor(.today), now: Self.now)

        #expect(result.identifier == "fs-1")
    }

    // MARK: - Library locator errors propagate

    @Test
    func libraryMissingErrorPropagates() {
        let locator = MockVoiceMemosLibraryLocator(
            error: .voiceMemoLibraryMissing(searched: [
                URL(fileURLWithPath: "/tmp/nope"),
            ])
        )
        let r = DefaultVoiceMemosResolver(
            locator: locator,
            sqliteReaderFactory: { _, _ in
                MockCloudRecordingsReader(memos: [])
            },
            filesystemScanner: MockFilesystemRecordingsScanner()
        )

        do {
            _ = try r.resolve(.timeAnchor(.today), now: Self.now)
            Issue.record("expected DictamacError.voiceMemoLibraryMissing")
        } catch DictamacError.voiceMemoLibraryMissing {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test
    func permissionDeniedErrorPropagates() {
        let locator = MockVoiceMemosLibraryLocator(
            error: .permissionDenied(domain: "Files & Folders", deepLink: nil)
        )
        let r = DefaultVoiceMemosResolver(
            locator: locator,
            sqliteReaderFactory: { _, _ in
                MockCloudRecordingsReader(memos: [])
            },
            filesystemScanner: MockFilesystemRecordingsScanner()
        )

        do {
            _ = try r.resolve(.timeAnchor(.today), now: Self.now)
            Issue.record("expected DictamacError.permissionDenied")
        } catch DictamacError.permissionDenied {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // MARK: - list(since:limit:)

    @Test
    func listReturnsReverseChronologicalAndFiltersBySince() throws {
        let since = Self.dateAtHour(0, daysOffset: -2, from: Self.now)
        let memos = [
            Self.memo(
                identifier: "old",
                title: "old",
                at: Self.dateAtHour(10, daysOffset: -5, from: Self.now)
            ),
            Self.memo(
                identifier: "recent-1",
                title: "r1",
                at: Self.dateAtHour(10, daysOffset: -1, from: Self.now)
            ),
            Self.memo(
                identifier: "recent-2",
                title: "r2",
                at: Self.dateAtHour(11, on: Self.now)
            ),
            Self.memo(
                identifier: "boundary",
                title: "boundary",
                at: since
            ),
        ]
        let r = Self.resolver(memos: memos)

        let result = try r.list(since: since, limit: 100)

        // `recent-2` (today), `recent-1` (-1 day), `boundary` (==since,
        // included by `>=`). `old` filtered out.
        #expect(result.map(\.identifier) == ["recent-2", "recent-1", "boundary"])
    }

    @Test
    func listRespectsLimit() throws {
        let memos = (0..<5).map { i in
            Self.memo(
                identifier: "memo-\(i)",
                title: "title-\(i)",
                at: Self.dateAtHour(Double(i), on: Self.now)
            )
        }
        let r = Self.resolver(memos: memos)

        let result = try r.list(
            since: Self.dateAtHour(0, daysOffset: -10, from: Self.now),
            limit: 2
        )

        // Recency order: memo-4 (latest hour) then memo-3.
        #expect(result.map(\.identifier) == ["memo-4", "memo-3"])
    }

    @Test
    func listWithZeroLimitReturnsEmpty() throws {
        let memos = [
            Self.memo(
                identifier: "1",
                title: "1",
                at: Self.dateAtHour(10, on: Self.now)
            ),
        ]
        let r = Self.resolver(memos: memos)

        let result = try r.list(
            since: Self.dateAtHour(0, daysOffset: -10, from: Self.now),
            limit: 0
        )

        #expect(result.isEmpty)
    }

    @Test
    func listFallsBackToFilesystemScannerOnSqliteFailure() throws {
        let scannerMemos = [
            Self.memo(
                identifier: "fs-1",
                title: "fs1",
                at: Self.dateAtHour(10, on: Self.now)
            ),
        ]
        let r = Self.resolver(
            readerError: .sqliteUnavailable(reason: "missing"),
            scannerMemos: scannerMemos
        )

        let result = try r.list(
            since: Self.dateAtHour(0, daysOffset: -10, from: Self.now),
            limit: 10
        )

        #expect(result.map(\.identifier) == ["fs-1"])
    }
}

// MARK: - Thread-safe diagnostic capture

/// Concurrency-safe sink that accumulates diagnostic messages emitted
/// by the resolver. Mirrors the pattern in
/// `FilesystemRecordingsScannerTests.WarningSink`.
private final class DiagnosticSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var callback: @Sendable (String) -> Void {
        return { [weak self] message in
            self?.lock.lock()
            defer { self?.lock.unlock() }
            self?.storage.append(message)
        }
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
