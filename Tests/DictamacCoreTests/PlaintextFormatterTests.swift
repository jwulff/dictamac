import Testing
import Foundation
@testable import DictamacCore

struct PlaintextFormatterTests {

    // MARK: - Golden strings

    @Test func singleSegmentEmitsTextPlusNewline() {
        let transcript = makeTranscript(
            segments: [.init(startSeconds: 0, endSeconds: 1, text: "Hello world.", confidence: nil)]
        )
        #expect(format(transcript) == "Hello world.\n")
    }

    @Test func multipleSegmentsAreJoinedWithSingleSpace() {
        let transcript = makeTranscript(
            segments: [
                .init(startSeconds: 0, endSeconds: 1, text: "Hello", confidence: nil),
                .init(startSeconds: 1, endSeconds: 2, text: "world", confidence: nil),
                .init(startSeconds: 2, endSeconds: 3, text: "again.", confidence: nil),
            ]
        )
        #expect(format(transcript) == "Hello world again.\n")
    }

    @Test func segmentInternalWhitespaceIsCollapsed() {
        // Per PLAN.md §7 U7: runs of internal whitespace collapse to a
        // single ASCII space — no double spaces in plaintext output.
        let transcript = makeTranscript(
            segments: [
                .init(startSeconds: 0, endSeconds: 1, text: "  hello  ", confidence: nil),
                .init(startSeconds: 1, endSeconds: 2, text: "\tworld\n", confidence: nil),
                .init(startSeconds: 2, endSeconds: 3, text: "this   is", confidence: nil),
            ]
        )
        #expect(format(transcript) == "hello world this is\n")
    }

    @Test func whitespaceOnlySegmentsAreDropped() {
        let transcript = makeTranscript(
            segments: [
                .init(startSeconds: 0, endSeconds: 1, text: "hello", confidence: nil),
                .init(startSeconds: 1, endSeconds: 2, text: "   ", confidence: nil),
                .init(startSeconds: 2, endSeconds: 3, text: "\t\n", confidence: nil),
                .init(startSeconds: 3, endSeconds: 4, text: "world", confidence: nil),
            ]
        )
        #expect(format(transcript) == "hello world\n")
    }

    @Test func emptyTranscriptEmitsOnlyTrailingNewline() {
        // Documented behavior (PLAN.md §6 zero-segment note): the stdout
        // contract is "one trailing newline, nothing else" even when the
        // transcript is empty. We emit "\n", not "" — so downstream
        // pipelines see a consistent newline-terminated record.
        let transcript = makeTranscript(segments: [])
        #expect(format(transcript) == "\n")
    }

    @Test func singleEmptySegmentEmitsOnlyTrailingNewline() {
        let transcript = makeTranscript(
            segments: [.init(startSeconds: 0, endSeconds: 1, text: "", confidence: nil)]
        )
        #expect(format(transcript) == "\n")
    }

    @Test func confidenceAndTimestampsAreNotEmitted() {
        // Plaintext is strictly text content — no timestamps, no confidence.
        let transcript = makeTranscript(
            segments: [
                .init(startSeconds: 0.5, endSeconds: 2.5, text: "spoken", confidence: 0.92),
            ]
        )
        let output = format(transcript)
        #expect(output == "spoken\n")
        #expect(output.contains("0.5") == false)
        #expect(output.contains("2.5") == false)
        #expect(output.contains("0.92") == false)
    }

    @Test func plaintextMatchesFullTextPlusNewline() {
        // The CLI plaintext and MCP JSON `fullText` must stay byte-aligned
        // (per PLAN.md §6) — plaintext is exactly fullText + "\n".
        let transcript = makeTranscript(
            segments: [
                .init(startSeconds: 0, endSeconds: 1, text: "  hello  ", confidence: nil),
                .init(startSeconds: 1, endSeconds: 2, text: "world", confidence: nil),
            ]
        )
        #expect(format(transcript) == transcript.fullText + "\n")
    }

    // MARK: - TextOutputStream integration

    @Test func writesToPassedInTextOutputStream() {
        // Acceptance criterion: writes via TextOutputStream so MCP can
        // capture the formatted result into a string buffer.
        var buffer = StringBuffer()
        let transcript = makeTranscript(
            segments: [.init(startSeconds: 0, endSeconds: 1, text: "captured", confidence: nil)]
        )
        PlaintextFormatter.write(transcript, to: &buffer)
        #expect(buffer.contents == "captured\n")
    }

    @Test func successiveWritesAppendToSameStream() {
        var buffer = StringBuffer()
        let t1 = makeTranscript(segments: [.init(startSeconds: 0, endSeconds: 1, text: "one", confidence: nil)])
        let t2 = makeTranscript(segments: [.init(startSeconds: 0, endSeconds: 1, text: "two", confidence: nil)])
        PlaintextFormatter.write(t1, to: &buffer)
        PlaintextFormatter.write(t2, to: &buffer)
        #expect(buffer.contents == "one\ntwo\n")
    }

    // MARK: - Helpers

    private func format(_ transcript: Transcript) -> String {
        PlaintextFormatter.format(transcript)
    }

    private func makeTranscript(segments: [TranscriptSegment]) -> Transcript {
        Transcript(
            segments: segments,
            locale: "en-US",
            durationSeconds: 0,
            model: "test",
            source: .file(path: "/a.m4a")
        )
    }
}

/// In-memory `TextOutputStream` for test capture.
private struct StringBuffer: TextOutputStream {
    private(set) var contents = ""
    mutating func write(_ string: String) {
        contents.append(string)
    }
}
