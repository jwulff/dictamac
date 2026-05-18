import Foundation
import Testing
@testable import DictamacVoiceMemos

/// Tests for ``VoiceMemoQuery.parse(_:)``.
///
/// The parser is a pure function — no IO, no system state — so the
/// tests are plain `#expect` assertions on returned cases. Whitespace
/// trimming, case folding, and the strict shape probes (ISO date,
/// UUID, all-digits) are exercised explicitly because each governs a
/// branch the resolver downstream depends on.
struct VoiceMemoQueryTests {

    // MARK: - Time-anchor keywords

    @Test
    func parsesTodayKeyword() {
        #expect(VoiceMemoQuery.parse("today") == .timeAnchor(.today))
    }

    @Test
    func parsesYesterdayKeyword() {
        #expect(VoiceMemoQuery.parse("yesterday") == .timeAnchor(.yesterday))
    }

    @Test
    func parsesThisMorningKeyword() {
        #expect(VoiceMemoQuery.parse("this morning") == .timeAnchor(.thisMorning))
    }

    /// Case-folding: time anchors are matched on the lowercased form,
    /// so any case variant resolves to the same anchor.
    @Test
    func timeAnchorMatchingIsCaseInsensitive() {
        #expect(VoiceMemoQuery.parse("Today") == .timeAnchor(.today))
        #expect(VoiceMemoQuery.parse("YESTERDAY") == .timeAnchor(.yesterday))
        #expect(VoiceMemoQuery.parse("This Morning") == .timeAnchor(.thisMorning))
    }

    /// Surrounding whitespace is trimmed before classification —
    /// the CLI quoting layer can leave stray spaces, and we don't
    /// want `"today "` to fall through to fuzzy.
    @Test
    func timeAnchorMatchingTrimsSurroundingWhitespace() {
        #expect(VoiceMemoQuery.parse("  today  ") == .timeAnchor(.today))
        #expect(VoiceMemoQuery.parse("\tthis morning\n") == .timeAnchor(.thisMorning))
    }

    // MARK: - ISO date

    @Test
    func parsesISODate() {
        let result = VoiceMemoQuery.parse("2026-05-12")
        guard case .isoDate(let date) = result else {
            Issue.record("expected .isoDate, got \(result)")
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        #expect(formatter.string(from: date) == "2026-05-12")
    }

    /// ISO-date shape is **anchored** — a string that starts with a
    /// date but continues falls through to fuzzy, because we don't
    /// know which date the user meant.
    @Test
    func isoDateShapeIsAnchored() {
        let result = VoiceMemoQuery.parse("2026-05-12-extra")
        if case .isoDate = result {
            Issue.record("expected fuzzy fallback for '2026-05-12-extra'")
        }
    }

    // MARK: - Identifier shape: UUID

    @Test
    func parsesUUIDIdentifier() {
        let uuid = "F47AC10B-58CC-4372-A567-0E02B2C3D479"
        #expect(VoiceMemoQuery.parse(uuid) == .identifier(uuid))
    }

    @Test
    func parsesLowercaseUUIDIdentifier() {
        let uuid = "f47ac10b-58cc-4372-a567-0e02b2c3d479"
        #expect(VoiceMemoQuery.parse(uuid) == .identifier(uuid))
    }

    // MARK: - Identifier shape: all-digits primary key

    @Test
    func parsesAllDigitsIdentifier() {
        // Matches `CloudRecordings.db`'s `Z_PK` stringified values.
        #expect(VoiceMemoQuery.parse("42") == .identifier("42"))
        #expect(VoiceMemoQuery.parse("9007") == .identifier("9007"))
    }

    // MARK: - Fuzzy fallback

    @Test
    func arbitraryStringFallsBackToFuzzy() {
        #expect(VoiceMemoQuery.parse("Standup notes") == .fuzzyTitle("Standup notes"))
        #expect(VoiceMemoQuery.parse("memo-alpha") == .fuzzyTitle("memo-alpha"))
    }

    /// Whitespace is trimmed before falling through to fuzzy, so the
    /// payload the resolver sees has clean edges to normalize further.
    @Test
    func fuzzyFallbackPreservesTrimmedInternalShape() {
        #expect(VoiceMemoQuery.parse("  weekly review  ") == .fuzzyTitle("weekly review"))
    }
}
