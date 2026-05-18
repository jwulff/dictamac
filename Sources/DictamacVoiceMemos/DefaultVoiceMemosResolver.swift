import Foundation
import DictamacCore

/// Production implementation of ``VoiceMemosResolver``. Orchestrates
/// the library locator (#14), the SQLite reader (#17), and the
/// filesystem scanner (#20) into a single query-aware resolver.
///
/// ## Source preference
///
/// 1. `VoiceMemosLibraryLocator.locate()` — fails with
///    ``DictamacError/voiceMemoLibraryMissing`` or
///    ``DictamacError/permissionDenied``; both propagate to the caller.
/// 2. `CloudRecordings.db` via the injected ``CloudRecordingsReader``
///    factory — the optimized metadata path.
/// 3. Filesystem fallback via ``FilesystemRecordingsScanner`` — used
///    when the SQLite reader throws any of:
///    - ``CloudRecordingsError/sqliteUnavailable(reason:)`` (no DB file)
///    - ``CloudRecordingsError/schemaUnrecognized(reason:)`` (schema drift)
///    - ``CloudRecordingsError/sqliteOperationFailed`` (mid-write reads,
///      corruption, lock contention — treated the same as missing per
///      the resilience plan in `docs/PLAN.md` §9)
///
/// The fallback is silent unless a ``diagnosticSink`` is provided,
/// which routes the "we fell back" message to `--verbose` stderr.
///
/// ## Tie-break
///
/// All query forms that can match more than one memo (time anchors,
/// ISO date, fuzzy title) resolve to the **most recent** match by
/// ``VoiceMemoMetadata/recordedAt``. Stable tie-break beyond the
/// timestamp itself is not specified — Apple's `ZDATE` is sub-second so
/// collisions in practice are vanishingly rare.
///
/// ## Calendar / timezone
///
/// Date-range queries use `Calendar.current`, which honours the user's
/// system timezone. A memo recorded at 23:30 local on the 11th and a
/// query of `today` on the 12th will not match — by design.
public final class DefaultVoiceMemosResolver: VoiceMemosResolver {

    /// Factory that produces a ``CloudRecordingsReader`` for a given
    /// `(databaseURL, libraryURL)` pair. Injectable so tests can
    /// substitute a mock reader without touching the real
    /// `CloudRecordings.db` file. Production callers wire this to
    /// `DefaultCloudRecordingsReader.init`.
    public typealias CloudRecordingsReaderFactory =
        @Sendable (_ databaseURL: URL, _ libraryURL: URL) -> CloudRecordingsReader

    private let locator: VoiceMemosLibraryLocator
    private let sqliteReaderFactory: CloudRecordingsReaderFactory
    private let filesystemScanner: FilesystemRecordingsScanner
    private let diagnosticSink: (@Sendable (String) -> Void)?

    public init(
        locator: VoiceMemosLibraryLocator,
        sqliteReaderFactory: @escaping CloudRecordingsReaderFactory,
        filesystemScanner: FilesystemRecordingsScanner,
        diagnosticSink: (@Sendable (String) -> Void)? = nil
    ) {
        self.locator = locator
        self.sqliteReaderFactory = sqliteReaderFactory
        self.filesystemScanner = filesystemScanner
        self.diagnosticSink = diagnosticSink
    }

    // MARK: - Public API

    public func resolve(_ query: VoiceMemoQuery, now: Date) throws -> VoiceMemoMetadata {
        let memos = try loadAllMemos()

        switch query {
        case .timeAnchor(let anchor):
            let range = Self.dateRange(for: anchor, now: now)
            return try pickMostRecent(
                memos.filter { range.contains($0.recordedAt) },
                queryLabel: Self.label(for: anchor)
            )

        case .isoDate(let date):
            let range = Self.calendarDayRange(containing: date)
            let isoString = Self.isoDateString(for: date)
            return try pickMostRecent(
                memos.filter { range.contains($0.recordedAt) },
                queryLabel: isoString
            )

        case .identifier(let id):
            // Exact identifier match wins. The SQLite reader stringifies
            // `Z_PK` integer primary keys; the filesystem scanner uses
            // filename stems. Compare verbatim — case sensitivity is
            // preserved here because identifiers are not human-typed
            // titles.
            if let match = memos.first(where: { $0.identifier == id }) {
                return match
            }
            // Identifier miss → fall back to fuzzy-title search using
            // the same input string. Documented in the doc comment so
            // CLI users typing a half-remembered filename still land
            // on something useful instead of a hard miss.
            return try pickMostRecent(
                memos.filter { Self.fuzzyMatches(needle: id, hay: $0.title) },
                queryLabel: id
            )

        case .fuzzyTitle(let needle):
            return try pickMostRecent(
                memos.filter { Self.fuzzyMatches(needle: needle, hay: $0.title) },
                queryLabel: needle
            )
        }
    }

    public func list(since: Date, limit: Int) throws -> [VoiceMemoMetadata] {
        // A non-positive `limit` is meaningless — empty result rather
        // than crashing on an `Array.prefix(0)` (which is fine) or
        // negative input (which `prefix` clamps but is still nonsense).
        guard limit > 0 else { return [] }
        let memos = try loadAllMemos()
        let filtered = memos.filter { $0.recordedAt >= since }
        let sorted = filtered.sorted { $0.recordedAt > $1.recordedAt }
        return Array(sorted.prefix(limit))
    }

    // MARK: - Library loading + fallback

    /// Locates the library and loads every memo via the SQLite reader,
    /// falling back to the filesystem scanner on any
    /// ``CloudRecordingsError``. Library-locator errors
    /// (``DictamacError/voiceMemoLibraryMissing``,
    /// ``DictamacError/permissionDenied``) propagate unchanged — the
    /// caller maps them to CLI exit codes.
    private func loadAllMemos() throws -> [VoiceMemoMetadata] {
        let location = try locator.locate()
        let libraryURL = location.url
        let databaseURL = libraryURL.appendingPathComponent("CloudRecordings.db")

        let reader = sqliteReaderFactory(databaseURL, libraryURL)
        do {
            return try reader.recordings()
        } catch let error as CloudRecordingsError {
            // Every typed CloudRecordings failure is a fallback signal.
            // `sqliteUnavailable` and `schemaUnrecognized` are the
            // documented falls; `sqliteOperationFailed` is treated the
            // same — a corrupt or mid-write DB is operationally
            // indistinguishable from "missing" for our purposes (see
            // `docs/PLAN.md` §9). Surface a diagnostic so `--verbose`
            // users can see why the optimized path didn't fire.
            diagnosticSink?(
                "voice-memos-resolver: CloudRecordings.db unavailable (\(error)); falling back to filesystem scanner"
            )
            return try filesystemScanner.scan(libraryURL: libraryURL)
        }
    }

    // MARK: - Date-range helpers

    /// `[start, end)` for a calendar day containing `date` in the
    /// system timezone. Half-open so `recordedAt == nextDayStart` is
    /// excluded — matches the standard "day" semantics.
    private static func calendarDayRange(containing date: Date) -> Range<Date> {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        // `byAdding: .day, value: 1` correctly handles DST transitions
        // (24h boundary collapses to 23/25h that day). Falling back to
        // a 24h `addingTimeInterval` would be off-by-one twice a year.
        let nextDay = calendar.date(
            byAdding: .day,
            value: 1,
            to: startOfDay
        ) ?? startOfDay.addingTimeInterval(86_400)
        return startOfDay..<nextDay
    }

    /// Date range for one of the three time anchors.
    private static func dateRange(for anchor: TimeAnchor, now: Date) -> Range<Date> {
        let calendar = Calendar.current
        switch anchor {
        case .today:
            return calendarDayRange(containing: now)
        case .yesterday:
            let today = calendarDayRange(containing: now)
            let yesterdayStart = calendar.date(
                byAdding: .day,
                value: -1,
                to: today.lowerBound
            ) ?? today.lowerBound.addingTimeInterval(-86_400)
            return yesterdayStart..<today.lowerBound
        case .thisMorning:
            // [today 00:00, today 12:00). Half-open: a memo recorded at
            // exactly noon falls into the afternoon, not the morning.
            let today = calendarDayRange(containing: now)
            let noon = calendar.date(
                byAdding: .hour,
                value: 12,
                to: today.lowerBound
            ) ?? today.lowerBound.addingTimeInterval(12 * 3600)
            return today.lowerBound..<noon
        }
    }

    // MARK: - Match helpers

    /// Returns the most recent matching memo by `recordedAt`, or throws
    /// ``DictamacError/voiceMemoNotFound`` when the candidate list is
    /// empty.
    private func pickMostRecent(
        _ candidates: [VoiceMemoMetadata],
        queryLabel: String
    ) throws -> VoiceMemoMetadata {
        guard let best = candidates.max(by: { $0.recordedAt < $1.recordedAt }) else {
            throw DictamacError.voiceMemoNotFound(query: queryLabel)
        }
        return best
    }

    /// Case-insensitive substring match with whitespace normalization on
    /// both sides. Per the issue brief: trim, lowercase, collapse
    /// internal whitespace before substring compare.
    private static func fuzzyMatches(needle: String, hay: String) -> Bool {
        let normalizedNeedle = normalize(needle)
        let normalizedHay = normalize(hay)
        if normalizedNeedle.isEmpty { return false }
        return normalizedHay.contains(normalizedNeedle)
    }

    /// Trim outer whitespace, lowercase, and collapse runs of internal
    /// whitespace to a single space. Mirrors the contract in CLAUDE.md
    /// "trim + lowercase + collapse internal whitespace per CLAUDE.md".
    private static func normalize(_ string: String) -> String {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        // Split on any whitespace run; filter empties (handles leading
        // whitespace post-trim defensively) and rejoin with single
        // spaces. Equivalent to a regex `\s+` collapse without the
        // regex machinery.
        let parts = lowered.split(
            whereSeparator: { $0.isWhitespace || $0.isNewline }
        )
        return parts.joined(separator: " ")
    }

    /// Human-readable label for an anchor, used in
    /// ``DictamacError/voiceMemoNotFound`` messages.
    private static func label(for anchor: TimeAnchor) -> String {
        switch anchor {
        case .today: return "today"
        case .yesterday: return "yesterday"
        case .thisMorning: return "this morning"
        }
    }

    /// `yyyy-MM-dd` in the system timezone, for `voiceMemoNotFound`
    /// query labels. Independent of the `Locale` so the message shape
    /// stays predictable across users.
    private static func isoDateString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}
