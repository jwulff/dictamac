import Testing
import Foundation
@testable import DictamacCLI
@testable import DictamacCore
@testable import DictamacVoiceMemos

/// Tests for the `--voice-memo` CLI handler.
///
/// The handler is wired through ``runVoiceMemo(query:resolver:transcriber:audioResolver:localeIdentifier:wantsJSON:now:writeStdout:writeStderr:exit:)``,
/// the testable seam parallel to ``runResolveAndTranscribe`` and
/// ``runListVoiceMemos`` — it accepts an injectable voice-memos
/// resolver, audio resolver, and transcriber plus stdout/stderr/exit
/// closures so the production process never touches `Darwin.exit(_:)`
/// from inside a test run.
///
/// Behavior parity with the MCP `transcribe_voice_memo` tool (PR #54)
/// is the architectural reason this handler exists at all — every
/// test below has a matching test in
/// `Tests/DictamacMCPTests/ToolsCallTests.swift` that asserts the same
/// boundary on the MCP side. Drift between the two would violate the
/// PLAN.md §5 / §7 U9 "thin shells over the same core" invariant.
struct VoiceMemoHandlerTests {

    // MARK: - Happy path: plaintext

    @Test func happyPathRendersPlaintextAndExitsZero() async {
        let now = Date(timeIntervalSince1970: 1_715_000_000)
        let memo = canonicalMemo(now: now)
        let resolver = MockVoiceMemosResolver(listings: [memo])
        let resolvedURL = memo.assetPath
        let audioResolver = MockAudioFileResolver(resolvedURL: resolvedURL)
        let transcriber = MockTranscriber(
            transcriptToReturn: TranscriptFixture.canned(text: "hello agent")
        )
        let recorder = OutputRecorder()

        await runVoiceMemoForTest(
            query: "standup",
            voiceMemosResolver: resolver,
            transcriber: transcriber,
            audioResolver: audioResolver,
            wantsJSON: false,
            now: now,
            recorder: recorder
        )

        // The audio resolver was handed the memo's asset path.
        let audioSources = await audioResolver.receivedSources
        #expect(audioSources == [.path(memo.assetPath.path)])

        // The transcriber received the resolved URL with the
        // `.voiceMemo` source variant carrying the memo's identifier
        // and title (parity with the MCP `transcribe_voice_memo`
        // envelope, and the architectural fix from PR #57 review:
        // without this, the emitted transcript's source would collapse
        // to `.file(path: assetURL.path)` and `--json --voice-memo`
        // would leak the opaque asset path instead of the memo
        // metadata).
        let requests = await transcriber.receivedRequests
        #expect(requests.count == 1)
        if case .voiceMemo(let identifier, let title, let url) = requests.first?.source {
            #expect(identifier == memo.identifier)
            #expect(title == memo.title)
            #expect(url == resolvedURL)
        } else {
            Issue.record("expected request.source == .voiceMemo(...); got \(String(describing: requests.first?.source))")
        }
        #expect(requests.first?.format == .text)
        #expect(requests.first?.locale.identifier == "en-US")

        let stdout = recorder.stdoutText
        #expect(stdout.contains("hello agent"))
        #expect(!stdout.contains("\"version\""), "plaintext output must not contain JSON keys")

        let exitCodes = recorder.exitCodes
        #expect(exitCodes == [0])
    }

    // MARK: - JSON path

    @Test func jsonPathRendersJSONAndExitsZero() async {
        let now = Date(timeIntervalSince1970: 1_715_000_000)
        let memo = canonicalMemo(now: now)
        let resolver = MockVoiceMemosResolver(listings: [memo])
        let audioResolver = MockAudioFileResolver(resolvedURL: memo.assetPath)
        let transcriber = MockTranscriber(
            transcriptToReturn: TranscriptFixture.canned(text: "json transcript")
        )
        let recorder = OutputRecorder()

        await runVoiceMemoForTest(
            query: "yesterday",
            voiceMemosResolver: resolver,
            transcriber: transcriber,
            audioResolver: audioResolver,
            wantsJSON: true,
            now: now,
            recorder: recorder
        )

        let stdout = recorder.stdoutText
        #expect(stdout.contains("\"version\""), "JSON output must contain the schema version key")
        #expect(stdout.contains("json transcript"))

        let exitCodes = recorder.exitCodes
        #expect(exitCodes == [0])
    }

    /// Regression for the PR #57 review thread: when the JSON path is
    /// taken, the emitted transcript's `source` MUST carry the memo's
    /// identifier and title — not the opaque asset path. Before the
    /// fix, `DefaultTranscriber` collapsed the request source to
    /// `.file(path: assetURL.path)` and JSON consumers couldn't tell a
    /// Voice Memos lookup from a raw file transcription. The MCP path
    /// has the same regression test in
    /// ``ToolsCallTests/transcribeVoiceMemoJSONSourceCarriesMemoMetadata``.
    @Test func jsonPathEmitsVoiceMemoSourceWithIdentifierAndTitle() async throws {
        let now = Date(timeIntervalSince1970: 1_715_000_000)
        let memo = canonicalMemo(now: now)
        let resolver = MockVoiceMemosResolver(listings: [memo])
        let audioResolver = MockAudioFileResolver(resolvedURL: memo.assetPath)

        // The transcript the mock returns is built by feeding the same
        // request source through ``DefaultTranscriber/transcriptSource(for:audioURL:)``.
        // This way the test exercises the full pipeline contract: the
        // CLI handler builds a `.voiceMemo` request source, the
        // transcriber maps it to a `.voiceMemo` transcript source, and
        // the JSON formatter encodes that as `{"type": "voice-memo",
        // "identifier": ..., "title": ...}`.
        let resolvedURL = memo.assetPath
        let transcriber = TranscriptSourceEchoingTranscriber(
            memoIdentifier: memo.identifier,
            memoTitle: memo.title,
            resolvedURL: resolvedURL
        )
        let recorder = OutputRecorder()

        await runVoiceMemoForTest(
            query: "yesterday",
            voiceMemosResolver: resolver,
            transcriber: transcriber,
            audioResolver: audioResolver,
            wantsJSON: true,
            now: now,
            recorder: recorder
        )

        let stdout = recorder.stdoutText
        // Parse the JSON instead of substring-matching so a future
        // tweak to formatting (e.g. trailing whitespace, key order)
        // doesn't silently mask a regression.
        let data = try #require(stdout.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data)
        let dict = try #require(object as? [String: Any])
        let source = try #require(dict["source"] as? [String: Any])

        #expect(source["type"] as? String == "voice-memo")
        #expect(source["identifier"] as? String == memo.identifier)
        #expect(source["title"] as? String == memo.title)
        #expect(source["path"] == nil, "voice-memo source must NOT leak the asset path (PR #57)")

        let exitCodes = recorder.exitCodes
        #expect(exitCodes == [0])
    }

    // MARK: - Locale forwarded

    @Test func customLocaleIsForwardedToTranscriber() async {
        let memo = canonicalMemo(now: Date())
        let resolver = MockVoiceMemosResolver(listings: [memo])
        let audioResolver = MockAudioFileResolver(resolvedURL: memo.assetPath)
        let transcriber = MockTranscriber(
            transcriptToReturn: TranscriptFixture.canned()
        )
        let recorder = OutputRecorder()

        await runVoiceMemoForTest(
            query: "today",
            voiceMemosResolver: resolver,
            transcriber: transcriber,
            audioResolver: audioResolver,
            wantsJSON: false,
            now: Date(),
            localeIdentifier: "fr-FR",
            recorder: recorder
        )

        let requests = await transcriber.receivedRequests
        #expect(requests.first?.locale.identifier == "fr-FR")
    }

    // MARK: - Whitespace-only query → exit 2

    @Test func whitespaceOnlyQueryExitsTwoWithArgumentError() async {
        let resolver = MockVoiceMemosResolver(listings: [])
        let audioResolver = MockAudioFileResolver()
        let transcriber = MockTranscriber(
            transcriptToReturn: TranscriptFixture.canned()
        )
        let recorder = OutputRecorder()

        await runVoiceMemoForTest(
            query: "   ",
            voiceMemosResolver: resolver,
            transcriber: transcriber,
            audioResolver: audioResolver,
            wantsJSON: false,
            now: Date(),
            recorder: recorder
        )

        let exitCodes = recorder.exitCodes
        #expect(exitCodes == [2], "expected exit 2 for whitespace-only query; got \(exitCodes)")
        #expect(recorder.stdoutText.isEmpty)
        let stderr = recorder.stderrText
        #expect(stderr.lowercased().contains("argument"))

        // Audio resolver and transcriber must not be touched.
        let audioSources = await audioResolver.receivedSources
        #expect(audioSources.isEmpty, "audio resolver should not be called for an invalid query")
        let requests = await transcriber.receivedRequests
        #expect(requests.isEmpty, "transcriber should not be called for an invalid query")
    }

    @Test func emptyQueryExitsTwoWithArgumentError() async {
        let resolver = MockVoiceMemosResolver(listings: [])
        let audioResolver = MockAudioFileResolver()
        let transcriber = MockTranscriber(
            transcriptToReturn: TranscriptFixture.canned()
        )
        let recorder = OutputRecorder()

        await runVoiceMemoForTest(
            query: "",
            voiceMemosResolver: resolver,
            transcriber: transcriber,
            audioResolver: audioResolver,
            wantsJSON: false,
            now: Date(),
            recorder: recorder
        )

        let exitCodes = recorder.exitCodes
        #expect(exitCodes == [2])
        #expect(recorder.stdoutText.isEmpty)
    }

    // MARK: - voiceMemoNotFound → exit 66

    @Test func voiceMemoNotFoundExitsSixtySix() async {
        let resolver = MockVoiceMemosResolver(
            errorToThrow: DictamacError.voiceMemoNotFound(query: "yesterday")
        )
        let audioResolver = MockAudioFileResolver()
        let transcriber = MockTranscriber(
            transcriptToReturn: TranscriptFixture.canned()
        )
        let recorder = OutputRecorder()

        await runVoiceMemoForTest(
            query: "yesterday",
            voiceMemosResolver: resolver,
            transcriber: transcriber,
            audioResolver: audioResolver,
            wantsJSON: false,
            now: Date(),
            recorder: recorder
        )

        let exitCodes = recorder.exitCodes
        #expect(exitCodes == [66])
        #expect(recorder.stdoutText.isEmpty)

        // The stderr line should exactly match the
        // ``DictamacError.voiceMemoNotFound`` formattedStderrLine,
        // since that's the parity seam the MCP transport mirrors
        // (minus the trailing newline).
        let expected = DictamacError
            .voiceMemoNotFound(query: "yesterday")
            .formattedStderrLine
        #expect(recorder.stderrText == expected)

        // The audio resolver and transcriber must not be touched.
        let audioSources = await audioResolver.receivedSources
        #expect(audioSources.isEmpty)
        let requests = await transcriber.receivedRequests
        #expect(requests.isEmpty)
    }

    // MARK: - voiceMemoLibraryMissing → exit 74

    @Test func voiceMemoLibraryMissingExitsSeventyFour() async {
        let searched = [URL(fileURLWithPath: "/Users/test/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/")]
        let error = DictamacError.voiceMemoLibraryMissing(searched: searched)
        let resolver = MockVoiceMemosResolver(errorToThrow: error)
        let audioResolver = MockAudioFileResolver()
        let transcriber = MockTranscriber(
            transcriptToReturn: TranscriptFixture.canned()
        )
        let recorder = OutputRecorder()

        await runVoiceMemoForTest(
            query: "today",
            voiceMemosResolver: resolver,
            transcriber: transcriber,
            audioResolver: audioResolver,
            wantsJSON: false,
            now: Date(),
            recorder: recorder
        )

        let exitCodes = recorder.exitCodes
        #expect(exitCodes == [74])
        #expect(recorder.stdoutText.isEmpty)
        #expect(recorder.stderrText == error.formattedStderrLine)
    }

    // MARK: - permissionDenied → exit 73, deep-link surfaces

    @Test func permissionDeniedExitsSeventyThreeWithDeepLink() async {
        let deepLink = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")
        let error = DictamacError.permissionDenied(
            domain: "Files & Folders",
            deepLink: deepLink
        )
        let resolver = MockVoiceMemosResolver(errorToThrow: error)
        let audioResolver = MockAudioFileResolver()
        let transcriber = MockTranscriber(
            transcriptToReturn: TranscriptFixture.canned()
        )
        let recorder = OutputRecorder()

        await runVoiceMemoForTest(
            query: "today",
            voiceMemosResolver: resolver,
            transcriber: transcriber,
            audioResolver: audioResolver,
            wantsJSON: false,
            now: Date(),
            recorder: recorder
        )

        let exitCodes = recorder.exitCodes
        #expect(exitCodes == [73])
        #expect(recorder.stdoutText.isEmpty)
        #expect(recorder.stderrText.contains("Privacy_FilesAndFolders"))
    }

    // MARK: - Audio resolver fileNotFound → exit 64

    @Test func audioFileNotFoundExitsSixtyFour() async {
        let memo = canonicalMemo(now: Date())
        let resolver = MockVoiceMemosResolver(listings: [memo])
        let missing = memo.assetPath
        let audioResolver = MockAudioFileResolver(
            errorToThrow: DictamacError.fileNotFound(missing)
        )
        let transcriber = MockTranscriber(
            transcriptToReturn: TranscriptFixture.canned()
        )
        let recorder = OutputRecorder()

        await runVoiceMemoForTest(
            query: "standup",
            voiceMemosResolver: resolver,
            transcriber: transcriber,
            audioResolver: audioResolver,
            wantsJSON: false,
            now: Date(),
            recorder: recorder
        )

        let exitCodes = recorder.exitCodes
        #expect(exitCodes == [64])
        #expect(recorder.stdoutText.isEmpty)
        #expect(recorder.stderrText.contains(missing.path))

        // The transcriber must not be invoked once the audio resolver
        // has failed.
        let requests = await transcriber.receivedRequests
        #expect(requests.isEmpty)
    }

    // MARK: - Transcriber failure → exit code + cleanup

    @Test func transcriberFailureExitsOneAndRunsCleanup() async {
        let memo = canonicalMemo(now: Date())
        let resolver = MockVoiceMemosResolver(listings: [memo])
        let audioResolver = MockAudioFileResolver(resolvedURL: memo.assetPath)
        struct TranscribeBoom: Error, LocalizedError {
            var errorDescription: String? { "transcribe boom" }
        }
        let transcriber = MockTranscriber(
            transcriptToReturn: TranscriptFixture.canned(),
            errorToThrow: DictamacError.internalFailure(TranscribeBoom())
        )
        let recorder = OutputRecorder()

        await runVoiceMemoForTest(
            query: "standup",
            voiceMemosResolver: resolver,
            transcriber: transcriber,
            audioResolver: audioResolver,
            wantsJSON: false,
            now: Date(),
            recorder: recorder
        )

        let exitCodes = recorder.exitCodes
        #expect(exitCodes == [1], "DictamacError.internalFailure maps to exit code 1")
        #expect(recorder.stdoutText.isEmpty)
        #expect(recorder.stderrText.contains("transcribe boom"))

        // Cleanup must have been invoked even on the failure path,
        // matching the MCP handler's `defer { resolved.cleanup() }`.
        for _ in 0..<10 {
            let count = await audioResolver.cleanupCallCount
            if count >= 1 { break }
            await Task.yield()
        }
        let cleanupCount = await audioResolver.cleanupCallCount
        #expect(cleanupCount >= 1, "audio resolved.cleanup() should fire even when the transcriber fails")
    }

    // MARK: - Cleanup runs on success

    @Test func cleanupRunsOnSuccessPath() async {
        let memo = canonicalMemo(now: Date())
        let resolver = MockVoiceMemosResolver(listings: [memo])
        let audioResolver = MockAudioFileResolver(resolvedURL: memo.assetPath)
        let transcriber = MockTranscriber(
            transcriptToReturn: TranscriptFixture.canned()
        )
        let recorder = OutputRecorder()

        await runVoiceMemoForTest(
            query: "standup",
            voiceMemosResolver: resolver,
            transcriber: transcriber,
            audioResolver: audioResolver,
            wantsJSON: false,
            now: Date(),
            recorder: recorder
        )

        for _ in 0..<10 {
            let count = await audioResolver.cleanupCallCount
            if count >= 1 { break }
            await Task.yield()
        }
        let cleanupCount = await audioResolver.cleanupCallCount
        #expect(cleanupCount >= 1, "audio resolved.cleanup() should be invoked on the success path")
    }

    // MARK: - Parity: same DictamacError → same stderr text as MCP envelope

    /// The MCP transcribe_voice_memo handler maps a
    /// ``DictamacError`` to the tool-error envelope using
    /// ``DictamacError/mcpToolErrorText`` (which is
    /// ``DictamacError/description``). The CLI must surface the same
    /// text (plus a trailing newline) on stderr so the two transports
    /// stay byte-for-byte aligned per PLAN.md §7 U9.
    @Test func cliStderrMatchesMCPEnvelopeTextForVoiceMemoNotFound() async {
        let error = DictamacError.voiceMemoNotFound(query: "yesterday standup")
        let resolver = MockVoiceMemosResolver(errorToThrow: error)
        let audioResolver = MockAudioFileResolver()
        let transcriber = MockTranscriber(
            transcriptToReturn: TranscriptFixture.canned()
        )
        let recorder = OutputRecorder()

        await runVoiceMemoForTest(
            query: "yesterday standup",
            voiceMemosResolver: resolver,
            transcriber: transcriber,
            audioResolver: audioResolver,
            wantsJSON: false,
            now: Date(),
            recorder: recorder
        )

        // The CLI writes formattedStderrLine (description + "\n"); the
        // MCP envelope carries description with no trailing newline.
        // formattedStderrLine minus the trailing newline must equal
        // mcpToolErrorText.
        let stderr = recorder.stderrText
        let trimmed = stderr.hasSuffix("\n") ? String(stderr.dropLast()) : stderr
        #expect(trimmed == error.mcpToolErrorText)
    }

    // MARK: - Test helpers

    private func canonicalMemo(now: Date) -> VoiceMemoMetadata {
        VoiceMemoMetadata(
            identifier: "42",
            title: "Standup notes",
            recordedAt: now,
            durationSeconds: 60.0,
            assetPath: URL(fileURLWithPath: "/tmp/dictamac-test-memo-42.m4a")
        )
    }

    /// Drives ``runVoiceMemo(...)`` with `Void`-returning exit /
    /// stdout / stderr closures so tests can `await` and assert
    /// without terminating the test runner.
    private func runVoiceMemoForTest(
        query: String,
        voiceMemosResolver: any VoiceMemosResolver,
        transcriber: any Transcriber,
        audioResolver: any AudioFileResolver,
        wantsJSON: Bool,
        now: Date,
        localeIdentifier: String = "en-US",
        recorder: OutputRecorder
    ) async {
        await runVoiceMemo(
            query: query,
            voiceMemosResolver: voiceMemosResolver,
            transcriber: transcriber,
            audioResolver: audioResolver,
            localeIdentifier: localeIdentifier,
            wantsJSON: wantsJSON,
            now: now,
            writeStdout: { recorder.appendStdout($0) },
            writeStderr: { recorder.appendStderr($0) },
            exit: { recorder.recordExit($0) }
        )
    }
}

/// Test transcriber that builds its returned ``Transcript`` to match
/// what ``DefaultTranscriber`` would emit for the incoming request —
/// specifically, when the request carries a `.voiceMemo` source the
/// emitted transcript carries a `.voiceMemo` ``TranscriptSource`` with
/// the same identifier + title.
///
/// Used by ``VoiceMemoHandlerTests/jsonPathEmitsVoiceMemoSourceWithIdentifierAndTitle``
/// to exercise the end-to-end JSON shape without spinning up
/// ``SpeechAnalyzer``. The plain ``MockTranscriber`` returns a fixed
/// transcript with a `.file` source, which would mask the regression
/// this test guards against.
private actor TranscriptSourceEchoingTranscriber: Transcriber {
    let memoIdentifier: String
    let memoTitle: String
    let resolvedURL: URL

    init(memoIdentifier: String, memoTitle: String, resolvedURL: URL) {
        self.memoIdentifier = memoIdentifier
        self.memoTitle = memoTitle
        self.resolvedURL = resolvedURL
    }

    func transcribe(_ request: TranscriptionRequest) async throws -> Transcript {
        // Sanity check: the handler must have built a `.voiceMemo`
        // request source carrying our identifier + title. If a future
        // refactor reverts to `.file`, the JSON-shape assertion in the
        // caller is the primary check; this guard surfaces the
        // upstream regression with a clearer message.
        guard case .voiceMemo(let identifier, let title, _) = request.source else {
            return TranscriptFixture.canned()
        }
        return Transcript(
            segments: [
                TranscriptSegment(
                    startSeconds: 0,
                    endSeconds: 1,
                    text: "voice memo body",
                    confidence: nil
                )
            ],
            locale: "en-US",
            durationSeconds: 1,
            model: "MockTranscriber",
            source: .voiceMemo(identifier: identifier, title: title)
        )
    }
}
