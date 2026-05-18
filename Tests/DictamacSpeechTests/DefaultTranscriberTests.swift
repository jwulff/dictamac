import Foundation
import Testing
@testable import DictamacCore
@testable import DictamacSpeech

/// Tests that don't require a live `SpeechAnalyzer`. The end-to-end
/// transcription of the committed `.m4a` fixture lives in
/// ``DefaultTranscriberIntegrationTests`` so it can be gated separately
/// if a CI runner lacks the on-device speech model.
struct DefaultTranscriberTests {

    @Test func transcriberCanBeUsedAsAnyTranscriberExistential() async throws {
        // Compile-time check: the production type plugs into the protocol
        // seam that both CLI and MCP depend on. If this stops compiling
        // the architecture is broken.
        let _: any Transcriber = DefaultTranscriber()
    }

    @Test func missingFileSurfacesAsFileNotFoundError() async throws {
        let transcriber = DefaultTranscriber()
        let missingURL = URL(fileURLWithPath: "/tmp/dictamac-tests-definitely-does-not-exist-\(UUID().uuidString).m4a")
        let request = TranscriptionRequest(
            source: .file(missingURL),
            locale: Locale(identifier: "en-US"),
            format: .text
        )

        // The test name promises a specifically `.fileNotFound` error
        // carrying the offending URL — pin both, not just "some error".
        do {
            _ = try await transcriber.transcribe(request)
            Issue.record("expected transcribe to throw, but it returned")
        } catch let error as DictamacError {
            guard case .fileNotFound(let url) = error else {
                Issue.record("expected .fileNotFound, got \(error)")
                return
            }
            #expect(url == missingURL)
            #expect(error.exitCode == 64)
        }
    }

    @Test func modelIdentifierMatchesPlanContract() {
        // The JSON schema (PLAN.md §6) pins `model` to this exact string,
        // so it's a stable public contract; tests assert the literal.
        #expect(DefaultTranscriber.modelIdentifier == "SpeechAnalyzer/macOS26")
    }

    // MARK: - Request source → Transcript source mapping (PR #43)

    @Test func fileRequestSourceMapsToFileTranscriptSourceWithPath() {
        // The internal request source carries a URL for both .file and
        // .stdin; the external transcript source must encode the path
        // ONLY for .file, since that's the user-supplied stable
        // reference the JSON schema (PLAN.md §6) promises.
        let url = URL(fileURLWithPath: "/tmp/some-audio.m4a")
        let result = DefaultTranscriber.transcriptSource(
            for: .file(url),
            audioURL: url
        )
        #expect(result == .file(path: "/tmp/some-audio.m4a"))
    }

    @Test func stdinRequestSourceMapsToStdinTranscriptSourceWithoutPath() {
        // Regression test for the PR #43 bug: previously this collapsed
        // to `.file(path: audioURL.path)`, leaving JSON consumers with
        // a dangling /tmp/dictamac-stdin-...m4a path. The fix: emit the
        // path-less `.stdin` variant so consumers see {"type":"stdin"}
        // and can distinguish piped input from a real file.
        let stagedURL = URL(fileURLWithPath: "/tmp/dictamac-stdin-ABC.m4a")
        let result = DefaultTranscriber.transcriptSource(
            for: .stdin(stagedURL),
            audioURL: stagedURL
        )
        #expect(result == .stdin)
        // Belt-and-suspenders: assert it is NOT the file variant by any
        // path, so a future refactor that re-introduced the original
        // bug would fail this expectation with a clear diff.
        if case .file = result {
            Issue.record("expected .stdin, got .file — the PR #43 regression has returned")
        }
    }

    // MARK: - Voice-memo source mapping (PR #57 review)

    @Test func voiceMemoRequestSourceMapsToVoiceMemoTranscriptSourceWithMetadata() {
        // Regression test for the PR #57 bug: previously the CLI and
        // MCP voice-memo handlers built a `.file(resolvedURL)` request
        // source, which collapsed to `TranscriptSource.file(path:
        // assetURL.path)` and leaked the opaque asset path into JSON
        // output. The fix: a dedicated request-source variant that
        // the transcriber maps to the right transcript-source variant
        // carrying the memo's identifier + title.
        let assetURL = URL(fileURLWithPath: "/Users/test/Library/voice-memos/42.m4a")
        let result = DefaultTranscriber.transcriptSource(
            for: .voiceMemo(identifier: "VM-42", title: "Yesterday's standup", url: assetURL),
            audioURL: assetURL
        )
        #expect(result == .voiceMemo(identifier: "VM-42", title: "Yesterday's standup"))
        // Belt-and-suspenders: assert it is NOT a `.file` source, so a
        // future refactor that reverted to `.file` would fail with a
        // clear diff rather than silently regressing.
        if case .file = result {
            Issue.record("expected .voiceMemo, got .file — the PR #57 regression has returned")
        }
    }

    @Test func voiceMemoRequestSourceDropsAssetURLFromTranscriptSource() {
        // Independent of the asset URL: the emitted transcript source
        // must NOT carry it. The identifier + title are the only
        // user-meaningful fields, and the asset path inside the Voice
        // Memos library is meaningless to a human consumer.
        let assetURL = URL(fileURLWithPath: "/Users/test/Library/voice-memos/opaque-uuid.m4a")
        let result = DefaultTranscriber.transcriptSource(
            for: .voiceMemo(identifier: "VM-X", title: "Title", url: assetURL),
            audioURL: assetURL
        )
        // Round-trip through Codable and assert no `path` key — the
        // schema test in TranscriptTests already covers this, but
        // pinning it at the mapping seam too means a regression here
        // gets caught before it reaches the formatter.
        let data = try? JSONEncoder().encode(result)
        let object = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any]
        #expect(object?["type"] as? String == "voice-memo")
        #expect(object?["identifier"] as? String == "VM-X")
        #expect(object?["title"] as? String == "Title")
        #expect(object?["path"] == nil)
    }
}
