import Foundation

/// Time anchor for date-relative Voice Memo queries.
///
/// `today` and `yesterday` cover the full calendar day in system
/// timezone; `thisMorning` covers `[00:00, 12:00)` of today.
public enum TimeAnchor: Hashable, Sendable {
    case today
    case yesterday
    case thisMorning
}

/// Parsed user query for selecting a Voice Memo.
///
/// Constructed via `VoiceMemoQuery.parse(_:)` which classifies the
/// input into one of these cases. Used by both the CLI
/// `--voice-memo <query>` flag and the MCP `transcribe_voice_memo`
/// tool input — same semantics, one parser.
public enum VoiceMemoQuery: Hashable, Sendable {
    case timeAnchor(TimeAnchor)
    case isoDate(Date)
    case identifier(String)
    case fuzzyTitle(String)

    /// Parses an input string into a `VoiceMemoQuery`.
    ///
    /// Classification order (first match wins):
    /// 1. Trimmed lowercase exact match against time-anchor keywords
    ///    (`today`, `yesterday`, `this morning`).
    /// 2. ISO date (`YYYY-MM-DD`).
    /// 3. Identifier shape (UUID-like or all-digits primary key).
    /// 4. Fuzzy title fallback (everything else).
    public static func parse(_ input: String) -> VoiceMemoQuery {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()

        // 1. Time-anchor keywords (case-insensitive, whitespace-trimmed).
        switch lowered {
        case "today": return .timeAnchor(.today)
        case "yesterday": return .timeAnchor(.yesterday)
        case "this morning": return .timeAnchor(.thisMorning)
        default: break
        }

        // 2. ISO date (YYYY-MM-DD) — strict shape match.
        if Self.isoDateRegex.firstMatch(in: trimmed) != nil {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = TimeZone.current
            formatter.locale = Locale(identifier: "en_US_POSIX")
            if let date = formatter.date(from: trimmed) {
                return .isoDate(date)
            }
        }

        // 3. Identifier shape — UUID-style (8-4-4-4-12 hex) or all digits.
        //    SQLite primary keys from `CloudRecordings.db` are integer
        //    `Z_PK` values, stringified; the filesystem fallback uses
        //    filename stems which can include arbitrary characters, so
        //    those rely on the fuzzy fallback instead. The resolver
        //    additionally falls back to fuzzy when an identifier query
        //    misses — see `DefaultVoiceMemosResolver.resolve(_:now:)`.
        if Self.uuidRegex.firstMatch(in: trimmed) != nil
            || Self.digitsRegex.firstMatch(in: trimmed) != nil {
            return .identifier(trimmed)
        }

        // 4. Fuzzy title fallback — preserve the trimmed string so
        //    substring matching has the natural case the user typed.
        return .fuzzyTitle(trimmed)
    }

    // MARK: - Shape probes

    /// `YYYY-MM-DD` with all-digit year/month/day. Anchored so e.g.
    /// `2026-05-12-extra` does not pass — that would be a fuzzy title
    /// that happens to start with a date.
    private static let isoDateRegex = ShapeRegex(
        pattern: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$"
    )

    /// Canonical UUID shape: `8-4-4-4-12` hex characters (case-insensitive).
    /// Anchored — anything else falls through to fuzzy.
    private static let uuidRegex = ShapeRegex(
        pattern: "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
    )

    /// All-digits identifier (e.g. SQLite `Z_PK` stringified).
    /// Anchored — anything with letters or punctuation falls through.
    private static let digitsRegex = ShapeRegex(
        pattern: "^[0-9]+$"
    )
}

/// Resolves a `VoiceMemoQuery` to a specific `VoiceMemoMetadata`, or
/// lists memos by date filter. Consumed by both the CLI
/// `--voice-memo` / `--list-voice-memos` modes and the MCP
/// `transcribe_voice_memo` / `list_voice_memos` tools.
public protocol VoiceMemosResolver: Sendable {
    /// Resolve a query to exactly one Voice Memo. When multiple memos
    /// match, returns the most recent by `recordedAt`. Throws
    /// `DictamacError.voiceMemoNotFound` when nothing matches.
    func resolve(_ query: VoiceMemoQuery, now: Date) throws -> VoiceMemoMetadata

    /// List memos with `recordedAt >= since`, capped to `limit` entries,
    /// in reverse-chronological order. Used by `--list-voice-memos` and
    /// the `list_voice_memos` MCP tool.
    func list(since: Date, limit: Int) throws -> [VoiceMemoMetadata]
}

// MARK: - Anchor-pattern shape probe
//
// `NSRegularExpression` is the most portable way to check anchored
// patterns from a Swift module that targets pure Foundation. We wrap
// it in a small `Sendable` value so the static-let probes above don't
// trip the strict-concurrency global-actor checker — `NSRegularExpression`
// is documented as thread-safe for read-only matching but is not
// `Sendable`-conformant by default.
private struct ShapeRegex: @unchecked Sendable {
    private let regex: NSRegularExpression?

    init(pattern: String) {
        self.regex = try? NSRegularExpression(pattern: pattern, options: [])
    }

    func firstMatch(in string: String) -> NSTextCheckingResult? {
        guard let regex else { return nil }
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        return regex.firstMatch(in: string, options: [], range: range)
    }
}
