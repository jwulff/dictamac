import Testing
import Foundation
@testable import DictamacVoiceMemos

/// Tests for ``DurationString`` — the shared parser used by
/// `--list-voice-memos --since` and the MCP `list_voice_memos.since`
/// input. Accepts duration shorthand (`7d`, `2w`, `1m`) or ISO date
/// (`YYYY-MM-DD`). Invalid input throws.
struct DurationStringTests {

    // MARK: - Duration shorthand

    @Test func parses7DaysAsShortDurationShorthand() throws {
        let parsed = try DurationString("7d")
        #expect(parsed.seconds == 7 * 86_400)
    }

    @Test func parses2WeeksAsShortDurationShorthand() throws {
        let parsed = try DurationString("2w")
        #expect(parsed.seconds == 14 * 86_400)
    }

    @Test func parses1MonthAsApproximatelyThirtyDays() throws {
        let parsed = try DurationString("1m")
        #expect(parsed.seconds == 30 * 86_400)
    }

    @Test func parsesMultiDigitDurations() throws {
        let parsed = try DurationString("30d")
        #expect(parsed.seconds == 30 * 86_400)
    }

    @Test func trimsLeadingAndTrailingWhitespace() throws {
        let parsed = try DurationString("  7d  ")
        #expect(parsed.seconds == 7 * 86_400)
    }

    // MARK: - ISO date

    @Test func parsesAbsoluteISODate() throws {
        let parsed = try DurationString("2026-05-12")
        // Synthesize the same Date the parser should have produced —
        // midnight local time on that day.
        let calendar = Calendar(identifier: .gregorian)
        var components = DateComponents()
        components.year = 2026
        components.month = 5
        components.day = 12
        let expected = calendar.date(from: components)
        let returned = parsed.date(relativeTo: Date())
        #expect(returned == expected)
    }

    // MARK: - Relative date math

    @Test func sevenDaysRelativeToReferenceSubtractsSevenDays() throws {
        let parsed = try DurationString("7d")
        let reference = Date(timeIntervalSince1970: 1_715_000_000) // arbitrary anchor
        let result = parsed.date(relativeTo: reference)
        #expect(result == reference.addingTimeInterval(-7 * 86_400))
    }

    @Test func twoWeeksRelativeToReferenceSubtractsFourteenDays() throws {
        let parsed = try DurationString("2w")
        let reference = Date(timeIntervalSince1970: 1_715_000_000)
        let result = parsed.date(relativeTo: reference)
        #expect(result == reference.addingTimeInterval(-14 * 86_400))
    }

    @Test func oneMonthRelativeToReferenceSubtractsThirtyDays() throws {
        let parsed = try DurationString("1m")
        let reference = Date(timeIntervalSince1970: 1_715_000_000)
        let result = parsed.date(relativeTo: reference)
        #expect(result == reference.addingTimeInterval(-30 * 86_400))
    }

    @Test func isoDateIgnoresRelativeAnchor() throws {
        let parsed = try DurationString("2026-05-12")
        let resultA = parsed.date(relativeTo: Date(timeIntervalSince1970: 0))
        let resultB = parsed.date(relativeTo: Date())
        #expect(resultA == resultB)
    }

    // MARK: - Garbage / invalid input

    @Test func emptyStringThrows() {
        #expect(throws: DurationStringError.self) {
            _ = try DurationString("")
        }
    }

    @Test func whitespaceOnlyStringThrows() {
        #expect(throws: DurationStringError.self) {
            _ = try DurationString("   ")
        }
    }

    @Test func bareNumberThrows() {
        #expect(throws: DurationStringError.self) {
            _ = try DurationString("7")
        }
    }

    @Test func unknownSuffixThrows() {
        #expect(throws: DurationStringError.self) {
            _ = try DurationString("7y")
        }
    }

    @Test func nonsensicalGarbageThrows() {
        #expect(throws: DurationStringError.self) {
            _ = try DurationString("garbage")
        }
    }

    @Test func malformedISODateThrows() {
        // Looks like ISO but the day is invalid.
        #expect(throws: DurationStringError.self) {
            _ = try DurationString("2026-13-99")
        }
    }

    @Test func partialISODateThrows() {
        #expect(throws: DurationStringError.self) {
            _ = try DurationString("2026-05")
        }
    }

    @Test func zeroDurationThrows() {
        // 0d / 0w / 0m don't make sense — a "since 0 days ago" filter
        // would always match nothing. Surface as an arg error.
        #expect(throws: DurationStringError.self) {
            _ = try DurationString("0d")
        }
    }
}
