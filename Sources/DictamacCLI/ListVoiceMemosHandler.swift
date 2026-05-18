import Foundation
import DictamacCore
import DictamacVoiceMemos

/// `--list-voice-memos` handler — the testable seam parallel to
/// ``runResolveAndTranscribe(source:resolver:transcriber:localeIdentifier:wantsJSON:verbose:writeStdout:writeStderr:exit:)``.
///
/// Behavior contract (PLAN.md §4 / §5 / §7 U6):
///
/// 1. Parses `since` via ``DurationString``; defaults to `30d`.
///    Invalid input maps to ``DictamacError/argumentError(_:)`` (exit
///    2) — there is no recovery for a bad `--since` value.
/// 2. Clamps `limit` to `[1, 100]`; defaults to `30`. Out-of-range
///    values are clamped silently rather than rejected — agents
///    routinely pass `0` or `1000` and the resolver should still
///    return something useful.
/// 3. Calls ``VoiceMemosResolver/list(since:limit:)``. Sorts the
///    response reverse-chronologically as a defensive step in case
///    the resolver doesn't.
/// 4. Renders the listings either as columnar plaintext (default —
///    tab-separated `identifier <tab> ISO8601 <tab> durationSeconds
///    <tab> title`) or as a JSON array of ``VoiceMemoListing`` when
///    `wantsJSON` is set. The JSON shape MUST match the MCP
///    `list_voice_memos` return schema verbatim.
/// 5. Writes the rendered output to `writeStdout` (one trailing
///    newline) and calls `exit(0)`. Errors route through
///    `writeStderr` and `exit(error.exitCode)`.
///
/// `writeStdout` / `writeStderr` / `exit` are injectable so tests can
/// drive the handler without touching `FileHandle.standardOutput` or
/// `Darwin.exit(_:)`. Production captures the real handles.
///
/// The `now` parameter exists so tests can pin a deterministic time
/// anchor when validating that `--since 7d` resolves to a specific
/// Date. Production callers pass `Date()` at call time.
public func runListVoiceMemos(
    since: String?,
    limit: Int?,
    resolver: any VoiceMemosResolver,
    now: Date,
    wantsJSON: Bool,
    writeStdout: @Sendable @escaping (String) -> Void = { string in
        FileHandle.standardOutput.write(Data(string.utf8))
    },
    writeStderr: @Sendable @escaping (String) -> Void = { string in
        FileHandle.standardError.write(Data(string.utf8))
    },
    exit: @Sendable @escaping (Int32) -> Void = { code in
        Foundation.exit(code)
    }
) async {
    // 1. Resolve the --since bound. Default 30d, invalid → exit 2.
    let sinceDate: Date
    do {
        let parsed = try DurationString(since ?? "30d")
        sinceDate = parsed.date(relativeTo: now)
    } catch let error as DurationStringError {
        let mapped = DictamacError.argumentError(
            "--since: \(error.description)"
        )
        writeStderr(mapped.formattedStderrLine)
        exit(mapped.exitCode)
        return
    } catch {
        let mapped = DictamacError.argumentError(
            "--since: \(error.localizedDescription)"
        )
        writeStderr(mapped.formattedStderrLine)
        exit(mapped.exitCode)
        return
    }

    // 2. Clamp limit to [1, 100]; default 30.
    let clampedLimit = clamp(limit ?? 30, minimum: 1, maximum: 100)

    // 3. Ask the resolver.
    let memos: [VoiceMemoMetadata]
    do {
        memos = try resolver.list(since: sinceDate, limit: clampedLimit)
    } catch let error as DictamacError {
        writeStderr(error.formattedStderrLine)
        exit(error.exitCode)
        return
    } catch {
        let wrapped = DictamacError.internalFailure(error)
        writeStderr(wrapped.formattedStderrLine)
        exit(wrapped.exitCode)
        return
    }

    // 4. Defensive sort — the resolver is documented to return
    // reverse-chronological, but we don't trust silent contract
    // violations to make it past the CLI surface.
    let sorted = memos.sorted { $0.recordedAt > $1.recordedAt }

    // 5. Render + write.
    let rendered: String
    if wantsJSON {
        do {
            rendered = try renderJSON(sorted)
        } catch {
            // JSON encoding of `[VoiceMemoListing]` is expected to be
            // total because every field is JSON-native; in practice
            // only pathological metadata (e.g. a non-finite Double in
            // `durationSeconds`) can make `JSONEncoder` throw. When it
            // does, surface a real internal failure rather than
            // lying to the caller with `[]` — stdout stays empty,
            // stderr gets the structured error line, exit 1.
            let wrapped = DictamacError.internalFailure(error)
            writeStderr(wrapped.formattedStderrLine)
            exit(wrapped.exitCode)
            return
        }
    } else {
        rendered = renderPlaintext(sorted)
    }
    writeStdout(rendered)
    exit(0)
}

/// Clamps `value` into the inclusive range `[minimum, maximum]`.
///
/// Not a method on `Int` because the project policy avoids extending
/// stdlib types in libraries — keep utility helpers local to the file
/// that needs them.
private func clamp(_ value: Int, minimum: Int, maximum: Int) -> Int {
    if value < minimum { return minimum }
    if value > maximum { return maximum }
    return value
}

/// Columnar plaintext output: one line per memo, tab-separated
/// columns in the order
/// `identifier <tab> recordedAt-ISO8601 <tab> durationSeconds <tab>
/// title`. Trailing newline after each line; empty result is the
/// empty string.
///
/// Tab-separated rather than space- or pipe-separated so agents and
/// users can pipe the output into `awk -F'\t'` without escaping the
/// delimiter inside titles. Titles that contain literal tabs or
/// newlines are sanitized via ``sanitizeTitle(_:)`` so the rows stay
/// parseable.
private func renderPlaintext(_ memos: [VoiceMemoMetadata]) -> String {
    guard !memos.isEmpty else { return "" }
    let formatter = ISO8601DateFormatter()
    var lines: [String] = []
    lines.reserveCapacity(memos.count)
    for memo in memos {
        let recordedAt = formatter.string(from: memo.recordedAt)
        let duration = formatDuration(memo.durationSeconds)
        let title = sanitizeTitle(memo.title)
        lines.append("\(memo.identifier)\t\(recordedAt)\t\(duration)\t\(title)")
    }
    return lines.joined(separator: "\n") + "\n"
}

/// JSON array of ``VoiceMemoListing`` matching the MCP
/// `list_voice_memos` schema. Sorted keys + ISO8601 dates so
/// snapshot-style assertions stay stable across encoder upgrades.
///
/// Throws when the encoder rejects the payload. Previously this
/// helper swallowed encoder failures and returned `"[]\n"`, which
/// quietly lied to callers ("zero memos") about a real internal
/// fault. The handler now treats the throw as
/// ``DictamacError/internalFailure(_:)`` and exits 1 instead.
private func renderJSON(_ memos: [VoiceMemoMetadata]) throws -> String {
    let listings = memos.map(VoiceMemoListing.init(from:))
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(listings)
    let body = String(data: data, encoding: .utf8) ?? "[]"
    return body + "\n"
}

/// Formats duration as a `%.3f` string trimmed of trailing zeros so
/// integers render as `60` and fractional values as `60.5`. Keeps the
/// plaintext column compact for agents piping through `awk`.
///
/// Locale-pinned to POSIX (`en_US_POSIX`) so the decimal separator is
/// always `.` regardless of the user's system locale. Without an
/// explicit locale, `String(format:)` on a `de_DE` / `fr_FR` host emits
/// a comma decimal separator, which breaks the tab-separated machine-
/// parseable plaintext contract (PLAN.md §4 — `awk -F'\t'` consumers
/// would see `60,5` and either truncate or fail downstream parsing).
internal func formatDuration(_ seconds: TimeInterval) -> String {
    // Use a fixed format then strip trailing zeros / trailing dot.
    let formatted = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), seconds)
    var result = formatted
    while result.contains(".") && (result.hasSuffix("0") || result.hasSuffix(".")) {
        let last = result.removeLast()
        if last == "." { break }
    }
    return result
}

/// Strips tabs and newlines from titles so the columnar plaintext
/// output stays parseable. Each removed character becomes a single
/// ASCII space; consecutive whitespace is left as-is (the resolver's
/// caller can collapse if it wants).
private func sanitizeTitle(_ title: String) -> String {
    var sanitized = title
    sanitized = sanitized.replacingOccurrences(of: "\t", with: " ")
    sanitized = sanitized.replacingOccurrences(of: "\n", with: " ")
    sanitized = sanitized.replacingOccurrences(of: "\r", with: " ")
    return sanitized
}
