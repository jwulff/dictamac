import Foundation
import Testing
@testable import DictamacCore
@testable import DictamacSpeech

/// End-to-end transcription against the committed en-US fixture.
///
/// The fixture was generated with the macOS `say` command (synthesized
/// speech — no real-person recording, per the public-repo audio-fixture
/// rule in `CLAUDE.md`). The assertion is a case-insensitive substring
/// check against the segment text so the test tolerates the small
/// per-output variance the speech model exhibits between runs.
///
/// This test exercises the real `SpeechAnalyzer` lifecycle, which means
/// it needs:
///
/// - macOS 26+ at runtime (the SPM platform target enforces this at
///   build time).
/// - The en-US speech model installed on the host. If the model is
///   missing, the SDK fails the request; the test surfaces that as a
///   regular Swift Testing failure with the underlying error attached.
/// - The Speech Recognition TCC permission for the test runner. On a
///   fresh machine the OS will prompt; in CI the model is pre-installed
///   and the permission is pre-granted in setup.
struct DefaultTranscriberIntegrationTests {

    @Test func transcribesEnglishFixtureContainingHelloWorld() async throws {
        let fixtureURL = try requireFixture(name: "hello-world", extension: "m4a")
        let transcriber = DefaultTranscriber()
        let request = TranscriptionRequest(
            source: .file(fixtureURL),
            locale: Locale(identifier: "en-US"),
            format: .text
        )

        let transcript = try await transcriber.transcribe(request)

        #expect(transcript.locale == "en-US")
        #expect(transcript.model == "SpeechAnalyzer/macOS26")
        #expect(transcript.durationSeconds > 0)
        #expect(!transcript.segments.isEmpty, "expected at least one final segment from SpeechAnalyzer")

        // Case-insensitive substring assertion: model output varies
        // slightly between runs (capitalization, punctuation,
        // contraction expansion), but the lexical content is stable.
        let combined = transcript.fullText.lowercased()
        #expect(combined.contains("hello"), "transcript missing 'hello': \(transcript.fullText)")
        #expect(combined.contains("world"), "transcript missing 'world': \(transcript.fullText)")

        // Segment ranges should be monotonically non-decreasing and
        // bounded by the clip duration.
        for segment in transcript.segments {
            #expect(segment.startSeconds >= 0)
            #expect(segment.endSeconds >= segment.startSeconds)
            #expect(segment.endSeconds <= transcript.durationSeconds + 0.5,
                    "segment endSeconds=\(segment.endSeconds) exceeded durationSeconds=\(transcript.durationSeconds)")
        }

        // Source should round-trip the file path so the JSON formatter
        // can stamp it without re-deriving.
        if case .file(let path) = transcript.source {
            #expect(path == fixtureURL.path)
        } else {
            Issue.record("expected .file source, got \(transcript.source)")
        }
    }

    private func requireFixture(name: String, extension ext: String) throws -> URL {
        if let url = Bundle.module.url(forResource: name, withExtension: ext) {
            return url
        }
        if let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") {
            return url
        }
        throw FixtureMissing(name: "\(name).\(ext)")
    }

    private struct FixtureMissing: Error, CustomStringConvertible {
        let name: String
        var description: String { "fixture \(name) not found in test bundle" }
    }
}
