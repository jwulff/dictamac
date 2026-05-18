import Testing
import Foundation
@testable import DictamacCore

struct TranscriptTests {

    // MARK: - TranscriptSegment

    @Test func segmentEncodesConfidenceWhenPresent() throws {
        let segment = TranscriptSegment(
            startSeconds: 1.0,
            endSeconds: 2.5,
            text: "hello",
            confidence: 0.87
        )
        let dict = try jsonObject(encoding: segment)
        #expect(dict["confidence"] as? Double == 0.87)
        #expect(dict["text"] as? String == "hello")
        #expect(dict["startSeconds"] as? Double == 1.0)
        #expect(dict["endSeconds"] as? Double == 2.5)
    }

    @Test func segmentOmitsConfidenceKeyWhenAbsent() throws {
        // Per PLAN.md §6: when confidence is unknown the JSON key must be
        // omitted entirely from the segment object, NOT encoded as null.
        let segment = TranscriptSegment(
            startSeconds: 0,
            endSeconds: 1,
            text: "hi",
            confidence: nil
        )
        let dict = try jsonObject(encoding: segment)
        #expect(dict.keys.contains("confidence") == false)
        #expect(dict["text"] as? String == "hi")
    }

    @Test func segmentRoundTripsWhenConfidencePresent() throws {
        let original = TranscriptSegment(startSeconds: 0, endSeconds: 1, text: "x", confidence: 0.5)
        #expect(try roundTrip(original) == original)
    }

    @Test func segmentRoundTripsWhenConfidenceAbsent() throws {
        let original = TranscriptSegment(startSeconds: 0, endSeconds: 1, text: "x", confidence: nil)
        #expect(try roundTrip(original) == original)
    }

    // MARK: - TranscriptSource

    @Test func fileSourceEncodesToSchema() throws {
        let source = TranscriptSource.file(path: "/tmp/audio.m4a")
        let dict = try jsonObject(encoding: source)
        #expect(dict["type"] as? String == "file")
        #expect(dict["path"] as? String == "/tmp/audio.m4a")
        #expect(dict.keys.contains("identifier") == false)
        #expect(dict.keys.contains("title") == false)
    }

    @Test func voiceMemoSourceEncodesToSchema() throws {
        let source = TranscriptSource.voiceMemo(identifier: "ABC-123", title: "Standup")
        let dict = try jsonObject(encoding: source)
        #expect(dict["type"] as? String == "voice-memo")
        #expect(dict["identifier"] as? String == "ABC-123")
        #expect(dict["title"] as? String == "Standup")
        #expect(dict.keys.contains("path") == false)
    }

    @Test func fileSourceRoundTrips() throws {
        let original = TranscriptSource.file(path: "/some/path.m4a")
        #expect(try roundTrip(original) == original)
    }

    @Test func voiceMemoSourceRoundTrips() throws {
        let original = TranscriptSource.voiceMemo(identifier: "X", title: "Y")
        #expect(try roundTrip(original) == original)
    }

    @Test func sourceDecodeRejectsUnknownType() throws {
        let badJSON = #"{"type":"bogus","path":"/x"}"#.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TranscriptSource.self, from: badJSON)
        }
    }

    @Test func stdinSourceEncodesToTypeOnly() throws {
        // The .stdin variant exists precisely so JSON consumers can
        // distinguish piped input from a real file without seeing a
        // dangling temp-file path. Encoding must therefore produce
        // {"type": "stdin"} with NO path / identifier / title keys.
        let source = TranscriptSource.stdin
        let dict = try jsonObject(encoding: source)
        #expect(dict["type"] as? String == "stdin")
        #expect(dict.keys.contains("path") == false)
        #expect(dict.keys.contains("identifier") == false)
        #expect(dict.keys.contains("title") == false)
    }

    @Test func stdinSourceRoundTrips() throws {
        let original = TranscriptSource.stdin
        #expect(try roundTrip(original) == original)
    }

    @Test func stdinSourceDecodesFromTypeOnlyPayload() throws {
        // Forward-compat: a hand-written `{"type":"stdin"}` payload
        // (no extra keys) must decode back to .stdin without error.
        let json = #"{"type":"stdin"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TranscriptSource.self, from: json)
        #expect(decoded == .stdin)
    }

    // MARK: - Transcript JSON schema

    @Test func transcriptVersionConstantIsOne() {
        #expect(Transcript.version == "1")
    }

    @Test func transcriptIncludesVersionString() throws {
        let dict = try jsonObject(encoding: simpleTranscript())
        #expect(dict["version"] as? String == "1")
    }

    @Test func transcriptIncludesAllRequiredFields() throws {
        let dict = try jsonObject(encoding: simpleTranscript())
        #expect(dict["locale"] as? String == "en-US")
        #expect(dict["durationSeconds"] as? Double == 3.0)
        #expect(dict["model"] as? String == "SpeechAnalyzer/macOS26")
        #expect(dict["source"] is [String: Any])
        #expect(dict["segments"] is [Any])
        #expect(dict["fullText"] as? String == "Hello world.")
    }

    @Test func transcriptEncodesSegmentsArray() throws {
        let transcript = simpleTranscript()
        let dict = try jsonObject(encoding: transcript)
        let segments = try #require(dict["segments"] as? [[String: Any]])
        #expect(segments.count == 1)
        #expect(segments[0]["text"] as? String == "Hello world.")
        #expect(segments[0]["confidence"] as? Double == 0.94)
    }

    @Test func transcriptEncodesVoiceMemoSource() throws {
        let transcript = Transcript(
            segments: [],
            locale: "en-US",
            durationSeconds: 0,
            model: "SpeechAnalyzer/macOS26",
            source: .voiceMemo(identifier: "VM-1", title: "Walk")
        )
        let dict = try jsonObject(encoding: transcript)
        let source = try #require(dict["source"] as? [String: Any])
        #expect(source["type"] as? String == "voice-memo")
        #expect(source["identifier"] as? String == "VM-1")
        #expect(source["title"] as? String == "Walk")
    }

    @Test func transcriptRoundTripsThroughCodable() throws {
        let original = simpleTranscript()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Transcript.self, from: data)
        #expect(decoded.segments == original.segments)
        #expect(decoded.locale == original.locale)
        #expect(decoded.durationSeconds == original.durationSeconds)
        #expect(decoded.model == original.model)
        #expect(decoded.source == original.source)
    }

    // MARK: - Version validation (Copilot review feedback on #34)

    @Test func transcriptDecodeRejectsMissingVersion() throws {
        // A payload with no version key would silently decode as v1 if we
        // ignored the field — that defeats the point of stamping the version.
        // Decoding must fail instead.
        let json = #"""
        {
          "segments": [],
          "locale": "en-US",
          "durationSeconds": 0,
          "model": "x",
          "source": {"type": "file", "path": "/a.m4a"},
          "fullText": ""
        }
        """#.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Transcript.self, from: json)
        }
    }

    @Test func transcriptDecodeRejectsUnknownVersion() throws {
        // A future v2 payload must fail loudly so callers see the mismatch
        // rather than silently dropping new fields.
        let json = #"""
        {
          "version": "2",
          "segments": [],
          "locale": "en-US",
          "durationSeconds": 0,
          "model": "x",
          "source": {"type": "file", "path": "/a.m4a"},
          "fullText": ""
        }
        """#.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Transcript.self, from: json)
        }
    }

    @Test func transcriptDecodeAcceptsVersionOne() throws {
        // Sanity: a hand-written v1 payload still decodes cleanly.
        let json = #"""
        {
          "version": "1",
          "segments": [],
          "locale": "en-US",
          "durationSeconds": 0,
          "model": "x",
          "source": {"type": "file", "path": "/a.m4a"},
          "fullText": ""
        }
        """#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Transcript.self, from: json)
        #expect(decoded.locale == "en-US")
        #expect(decoded.segments.isEmpty)
    }

    // MARK: - fullText normalization (PLAN.md §6 / §7 U7)

    @Test func fullTextEmptyWhenNoSegments() {
        let t = transcriptWithSegments([])
        #expect(t.fullText == "")
    }

    @Test func fullTextTrimsLeadingAndTrailingWhitespace() {
        let t = transcriptWithSegments([
            .init(startSeconds: 0, endSeconds: 1, text: "  hello  ", confidence: nil),
            .init(startSeconds: 1, endSeconds: 2, text: "\tworld\n", confidence: nil),
        ])
        #expect(t.fullText == "hello world")
    }

    @Test func fullTextDropsWhitespaceOnlySegments() {
        let t = transcriptWithSegments([
            .init(startSeconds: 0, endSeconds: 1, text: "hello", confidence: nil),
            .init(startSeconds: 1, endSeconds: 2, text: "   ", confidence: nil),
            .init(startSeconds: 2, endSeconds: 3, text: "\t\n", confidence: nil),
            .init(startSeconds: 3, endSeconds: 4, text: "world", confidence: nil),
        ])
        #expect(t.fullText == "hello world")
    }

    @Test func fullTextCollapsesInternalWhitespace() {
        let t = transcriptWithSegments([
            .init(startSeconds: 0, endSeconds: 1, text: "hello   world", confidence: nil),
            .init(startSeconds: 1, endSeconds: 2, text: "this\tis\nspaced", confidence: nil),
        ])
        #expect(t.fullText == "hello world this is spaced")
    }

    @Test func fullTextJoinsWithSingleSpace() {
        let t = transcriptWithSegments([
            .init(startSeconds: 0, endSeconds: 1, text: "a", confidence: nil),
            .init(startSeconds: 1, endSeconds: 2, text: "b", confidence: nil),
            .init(startSeconds: 2, endSeconds: 3, text: "c", confidence: nil),
        ])
        #expect(t.fullText == "a b c")
    }

    @Test func fullTextHasNoTrailingNewline() {
        // §6: fullText is the JSON string field — no trailing newline.
        // The plaintext CLI surface adds the "\n"; this field does not.
        let t = transcriptWithSegments([
            .init(startSeconds: 0, endSeconds: 1, text: "hello", confidence: nil),
        ])
        #expect(t.fullText.hasSuffix("\n") == false)
        #expect(t.fullText == "hello")
    }

    // MARK: - TranscriptionRequest

    @Test func requestCarriesAllFields() {
        let url = URL(fileURLWithPath: "/tmp/audio.m4a")
        let request = TranscriptionRequest(
            source: .file(url),
            locale: Locale(identifier: "en-US"),
            format: .json
        )
        #expect(request.source == .file(url))
        #expect(request.locale == Locale(identifier: "en-US"))
        #expect(request.format == .json)
    }

    @Test func requestSourceCanCarryStdinTempURL() {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("stdin.m4a")
        let request = TranscriptionRequest(
            source: .stdin(temp),
            locale: Locale(identifier: "en-US"),
            format: .text
        )
        guard case .stdin(let url) = request.source else {
            Issue.record("expected .stdin case")
            return
        }
        #expect(url == temp)
    }

    /// The `.voiceMemo` request source carries the resolved memo's
    /// identifier + title alongside the on-disk asset URL — added in
    /// the PR #57 fix so ``DefaultTranscriber`` can stamp the memo
    /// metadata into ``Transcript.source`` rather than collapsing to
    /// `.file(path: assetURL.path)` (which would leak the opaque asset
    /// path into JSON consumers).
    @Test func requestSourceCanCarryVoiceMemoMetadata() {
        let url = URL(fileURLWithPath: "/Users/test/voice-memos/42.m4a")
        let request = TranscriptionRequest(
            source: .voiceMemo(identifier: "VM-42", title: "Yesterday's standup", url: url),
            locale: Locale(identifier: "en-US"),
            format: .json
        )
        guard case .voiceMemo(let identifier, let title, let assetURL) = request.source else {
            Issue.record("expected .voiceMemo case")
            return
        }
        #expect(identifier == "VM-42")
        #expect(title == "Yesterday's standup")
        #expect(assetURL == url)
    }

    @Test func requestSourceVoiceMemoEqualityIsStructural() {
        let url = URL(fileURLWithPath: "/Users/test/voice-memos/42.m4a")
        let a = TranscriptionRequest.Source.voiceMemo(identifier: "id", title: "title", url: url)
        let b = TranscriptionRequest.Source.voiceMemo(identifier: "id", title: "title", url: url)
        let c = TranscriptionRequest.Source.voiceMemo(identifier: "other", title: "title", url: url)
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: - Helpers

    private func simpleTranscript() -> Transcript {
        Transcript(
            segments: [
                .init(startSeconds: 0, endSeconds: 3.2, text: "Hello world.", confidence: 0.94),
            ],
            locale: "en-US",
            durationSeconds: 3.0,
            model: "SpeechAnalyzer/macOS26",
            source: .file(path: "/tmp/audio.m4a")
        )
    }

    private func transcriptWithSegments(_ segments: [TranscriptSegment]) -> Transcript {
        Transcript(
            segments: segments,
            locale: "en-US",
            durationSeconds: 0,
            model: "test",
            source: .file(path: "/a.m4a")
        )
    }

    private func jsonObject<T: Encodable>(encoding value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
