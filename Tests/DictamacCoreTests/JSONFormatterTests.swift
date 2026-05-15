import Testing
import Foundation
@testable import DictamacCore

struct JSONFormatterTests {

    // MARK: - Snapshot coverage of every §6 schema shape

    @Test func fileSourceWithFullConfidence() throws {
        let transcript = Transcript(
            segments: [
                .init(startSeconds: 0, endSeconds: 3.2, text: "Hello world.", confidence: 0.94),
                .init(startSeconds: 3.2, endSeconds: 7.1, text: "Second segment.", confidence: 0.88),
            ],
            locale: "en-US",
            durationSeconds: 7.1,
            model: "SpeechAnalyzer/macOS26",
            source: .file(path: "/tmp/audio.m4a")
        )
        try assertSnapshot(JSONFormatter.format(transcript), named: "file-source-with-confidence")
    }

    @Test func fileSourceMixedConfidence() throws {
        // Per PLAN.md §6: when SpeechAnalyzer doesn't report confidence,
        // the `confidence` key is OMITTED entirely from the segment — not
        // encoded as null. This snapshot captures both segment shapes in
        // a single payload so a regression to `"confidence": null` is
        // immediately visible in the diff.
        let transcript = Transcript(
            segments: [
                .init(startSeconds: 0, endSeconds: 2, text: "with confidence", confidence: 0.92),
                .init(startSeconds: 2, endSeconds: 4, text: "without confidence", confidence: nil),
            ],
            locale: "en-US",
            durationSeconds: 4,
            model: "SpeechAnalyzer/macOS26",
            source: .file(path: "/tmp/audio.m4a")
        )
        try assertSnapshot(JSONFormatter.format(transcript), named: "file-source-mixed-confidence")
    }

    @Test func voiceMemoSource() throws {
        let transcript = Transcript(
            segments: [
                .init(startSeconds: 0, endSeconds: 5, text: "Standup notes.", confidence: 0.9),
            ],
            locale: "en-US",
            durationSeconds: 5,
            model: "SpeechAnalyzer/macOS26",
            source: .voiceMemo(identifier: "VM-2026-05-15-001", title: "Yesterday's Standup")
        )
        try assertSnapshot(JSONFormatter.format(transcript), named: "voice-memo-source")
    }

    @Test func emptySegments() throws {
        let transcript = Transcript(
            segments: [],
            locale: "en-US",
            durationSeconds: 0,
            model: "SpeechAnalyzer/macOS26",
            source: .file(path: "/tmp/empty.m4a")
        )
        try assertSnapshot(JSONFormatter.format(transcript), named: "empty-segments")
    }

    @Test func unicodeText() throws {
        // Acceptance criterion: verify Unicode is preserved (don't assume
        // — JSONEncoder defaults vary across Foundation versions for
        // non-ASCII content. The snapshot is the source of truth.).
        let transcript = Transcript(
            segments: [
                .init(startSeconds: 0, endSeconds: 1, text: "こんにちは世界", confidence: 0.91),
                .init(startSeconds: 1, endSeconds: 2, text: "café — naïveté", confidence: nil),
                .init(startSeconds: 2, endSeconds: 3, text: "emoji 🎙️ test", confidence: 0.87),
            ],
            locale: "ja-JP",
            durationSeconds: 3,
            model: "SpeechAnalyzer/macOS26",
            source: .file(path: "/tmp/unicode.m4a")
        )
        try assertSnapshot(JSONFormatter.format(transcript), named: "unicode-text")
    }

    // MARK: - Structural guarantees (independent of snapshot bytes)

    @Test func outputEndsWithSingleTrailingNewline() {
        let transcript = makeTranscript()
        let output = JSONFormatter.format(transcript)
        #expect(output.hasSuffix("\n"))
        #expect(output.hasSuffix("\n\n") == false)
    }

    @Test func outputIsValidJSONAndRoundTrips() throws {
        let transcript = makeTranscript()
        let output = JSONFormatter.format(transcript)
        let data = output.data(using: .utf8)!
        // Strip trailing newline; JSONDecoder tolerates either way.
        let decoded = try JSONDecoder().decode(Transcript.self, from: data)
        #expect(decoded.locale == transcript.locale)
        #expect(decoded.segments == transcript.segments)
    }

    @Test func sortedKeysProduceDeterministicOutput() {
        // Two identical encodings of the same input must be byte-equal —
        // this is the contract that makes snapshot diffing meaningful.
        let transcript = makeTranscript()
        let a = JSONFormatter.format(transcript)
        let b = JSONFormatter.format(transcript)
        #expect(a == b)
    }

    // MARK: - TextOutputStream integration

    @Test func writesToPassedInTextOutputStream() {
        var buffer = StringBuffer()
        let transcript = makeTranscript()
        JSONFormatter.write(transcript, to: &buffer)
        #expect(buffer.contents.hasSuffix("\n"))
        #expect(buffer.contents.contains("\"version\""))
    }

    // MARK: - Helpers

    private func makeTranscript() -> Transcript {
        Transcript(
            segments: [.init(startSeconds: 0, endSeconds: 1, text: "x", confidence: 0.5)],
            locale: "en-US",
            durationSeconds: 1,
            model: "SpeechAnalyzer/macOS26",
            source: .file(path: "/x.m4a")
        )
    }
}

// MARK: - Snapshot infrastructure

/// In-memory `TextOutputStream` for `write(_:to:)` capture.
private struct StringBuffer: TextOutputStream {
    private(set) var contents = ""
    mutating func write(_ string: String) {
        contents.append(string)
    }
}

/// Compares `actual` against the snapshot file at
/// `Tests/DictamacCoreTests/__Snapshots__/<name>.json`. When the
/// environment variable `UPDATE_SNAPSHOTS=1` is set, writes the actual
/// value as the new snapshot and records an Issue (so the test still
/// "fails" until the developer commits and re-runs without the flag).
///
/// Uses `#filePath` to anchor the snapshot directory next to the test
/// source — no `Bundle.module` resource bundling required, so a snapshot
/// regression diff lands in the same PR alongside the test change that
/// caused it.
private func assertSnapshot(
    _ actual: String,
    named name: String,
    sourceFile: StaticString = #filePath
) throws {
    let url = snapshotURL(name: name, sourceFile: sourceFile)
    let updateMode = ProcessInfo.processInfo.environment["UPDATE_SNAPSHOTS"] == "1"

    if updateMode || !FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try actual.write(to: url, atomically: true, encoding: .utf8)
        Issue.record("Wrote snapshot \(name).json — review the diff and commit before merging.")
        return
    }

    let expected = try String(contentsOf: url, encoding: .utf8)
    #expect(
        actual == expected,
        Comment(rawValue: "Snapshot drift in \(name).json. Re-run with UPDATE_SNAPSHOTS=1 to update.")
    )
}

private func snapshotURL(name: String, sourceFile: StaticString) -> URL {
    URL(fileURLWithPath: String(describing: sourceFile))
        .deletingLastPathComponent()
        .appendingPathComponent("__Snapshots__")
        .appendingPathComponent("\(name).json")
}
