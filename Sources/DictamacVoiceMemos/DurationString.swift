import Foundation

/// Errors thrown by ``DurationString/init(_:)`` when the input cannot
/// be classified as duration shorthand or an ISO date.
///
/// CLI callers map this to ``DictamacError/argumentError(_:)`` (exit
/// code 2). The MCP transport surfaces it as a JSON-RPC `-32602`
/// (invalid params) tool error.
public enum DurationStringError: Error, Equatable, CustomStringConvertible {
    /// The string was empty or whitespace-only.
    case empty

    /// The string did not match any supported form. `input` is the
    /// raw user-supplied text (trimmed of surrounding whitespace) so
    /// the CLI can echo it back verbatim.
    case unrecognized(input: String)

    /// The string matched the ISO date shape but the calendar
    /// rejected it (e.g. month 13, day 99, year out of range).
    case invalidISODate(input: String)

    /// The duration was syntactically valid but semantically zero
    /// (`0d`, `0w`, `0m`). A "since 0 ago" filter would always be
    /// empty, so we reject it up-front rather than silently surfacing
    /// an empty list.
    case zeroDuration(input: String)

    public var description: String {
        switch self {
        case .empty:
            return "duration string is empty"
        case .unrecognized(let input):
            return "unrecognized duration: \"\(input)\" — expected shorthand like 7d / 2w / 1m or an ISO date (YYYY-MM-DD)"
        case .invalidISODate(let input):
            return "invalid ISO date: \"\(input)\""
        case .zeroDuration(let input):
            return "duration must be greater than zero: \"\(input)\""
        }
    }
}

/// A parsed `--since` / `list_voice_memos.since` value.
///
/// Two shapes:
///
/// - **Duration shorthand** — `7d`, `2w`, `1m`. Interpreted as a
///   relative window: `date(relativeTo: now)` returns
///   `now - shorthand`. The `1m` form is approximate — exactly 30
///   days — because `Calendar` arithmetic against a wall-clock month
///   is timezone- and DST-sensitive, and the resolver only needs the
///   filter to be "roughly a month back" rather than calendar-exact.
/// - **ISO date** — `YYYY-MM-DD`. Interpreted as midnight local time
///   on that day. `date(relativeTo:)` ignores its argument and
///   returns the absolute Date.
///
/// Both shapes produce a single Date the resolver uses as the
/// `since` lower bound for ``VoiceMemosResolver/list(since:limit:)``.
public struct DurationString: Hashable, Sendable {

    /// The window expressed in seconds. For ISO-date forms this is
    /// the offset from the unix epoch — meaningless on its own; use
    /// ``date(relativeTo:)`` to get the absolute timestamp.
    public let seconds: TimeInterval

    /// Whether the input was an absolute ISO date. ISO dates ignore
    /// the relative anchor passed to ``date(relativeTo:)``.
    private let absoluteDate: Date?

    public init(_ input: String) throws {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DurationStringError.empty
        }

        // ISO date first — its shape (`YYYY-MM-DD`, 10 chars, two
        // dashes) is unambiguous, so we can branch on it without
        // backtracking.
        if Self.looksLikeISODate(trimmed) {
            guard let date = Self.parseISODate(trimmed) else {
                throw DurationStringError.invalidISODate(input: trimmed)
            }
            self.seconds = date.timeIntervalSince1970
            self.absoluteDate = date
            return
        }

        // Duration shorthand: <digits><unit>. The unit suffix is one
        // of `d`, `w`, `m`. Anything else (no unit, unknown unit,
        // letters before digits, embedded spaces) is unrecognized.
        guard let (magnitude, unit) = Self.parseShorthand(trimmed) else {
            throw DurationStringError.unrecognized(input: trimmed)
        }
        guard magnitude > 0 else {
            throw DurationStringError.zeroDuration(input: trimmed)
        }
        let multiplier: TimeInterval
        switch unit {
        case "d": multiplier = 86_400
        case "w": multiplier = 7 * 86_400
        case "m": multiplier = 30 * 86_400 // ~30 days; see doc note.
        default:
            throw DurationStringError.unrecognized(input: trimmed)
        }
        self.seconds = TimeInterval(magnitude) * multiplier
        self.absoluteDate = nil
    }

    /// Returns the absolute Date the `--since` filter should compare
    /// against.
    ///
    /// - For duration shorthand, this is `relativeTo - seconds`.
    /// - For ISO dates, this is the parsed midnight Date; the
    ///   `relativeTo` argument is ignored.
    public func date(relativeTo: Date) -> Date {
        if let absoluteDate {
            return absoluteDate
        }
        return relativeTo.addingTimeInterval(-seconds)
    }

    // MARK: - Parsing helpers

    private static func looksLikeISODate(_ input: String) -> Bool {
        // Cheap shape check before the calendar work: 10 characters,
        // dashes at positions 4 and 7. Avoids feeding bare `7d` /
        // garbage through the date formatter (which would loudly
        // succeed-but-empty on partial matches).
        guard input.count == 10 else { return false }
        let chars = Array(input)
        guard chars[4] == "-", chars[7] == "-" else { return false }
        // First 4 and last 5 (minus dashes) must be digits.
        for (index, character) in chars.enumerated() where index != 4 && index != 7 {
            if !character.isASCII || !character.isNumber {
                return false
            }
        }
        return true
    }

    private static func parseISODate(_ input: String) -> Date? {
        // Calendar-based parse so we reject impossible dates like
        // 2026-13-99 — `DateFormatter` with a lenient style would
        // silently normalize those. Use a Gregorian calendar pinned
        // to the current timezone (system local) per PLAN.md §7 U6.
        let parts = input.split(separator: "-").map(String.init)
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            return nil
        }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 0
        components.minute = 0
        components.second = 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        // `date(from:)` returns nil on invalid components only when
        // the calendar is strict; nudge it that way by validating
        // after the fact.
        guard let candidate = calendar.date(from: components) else {
            return nil
        }
        let reconstructed = calendar.dateComponents([.year, .month, .day], from: candidate)
        guard reconstructed.year == year,
              reconstructed.month == month,
              reconstructed.day == day else {
            return nil
        }
        return candidate
    }

    private static func parseShorthand(_ input: String) -> (magnitude: Int, unit: Character)? {
        // Trailing unit + leading digits. Walk from the end to peel
        // off the unit, then parse the remainder as an integer.
        guard let lastCharacter = input.last else { return nil }
        let unit = Character(lastCharacter.lowercased())
        guard ["d", "w", "m"].contains(unit) else { return nil }
        let digits = String(input.dropLast())
        guard !digits.isEmpty else { return nil }
        guard let magnitude = Int(digits), magnitude >= 0 else { return nil }
        return (magnitude, unit)
    }
}
