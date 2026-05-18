import Testing
import Foundation
@testable import DictamacCLI
@testable import DictamacCore

/// Tests for the resolver-fronted intake pipeline shared by the file
/// and stdin handlers (issue #27).
///
/// These tests pin the architectural invariant that
/// ``runResolveAndTranscribe(source:resolver:transcriber:localeIdentifier:wantsJSON:verbose:writeStdout:writeStderr:exit:)``
/// always:
///
/// 1. Calls `resolver.resolve(source:)` BEFORE constructing a
///    ``TranscriptionRequest``.
/// 2. Passes the resolved URL into the request with the correct
///    `TranscriptionRequest.Source` variant for the input kind
///    (`.file` for `.path`, `.stdin` for `.stdin`).
/// 3. Routes resolver errors to the right exit code (64 / 65)
///    BEFORE invoking the transcriber.
/// 4. Always runs the resolver's `cleanup()` hook before exiting,
///    on both success and failure paths.
struct ResolverWiringTests {

    // MARK: - File path: resolver is called before the transcriber

    @Test func filePathHandlerResolvesBeforeTranscribing() async {
        let resolvedURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dictamac-resolved-file.m4a")
        let resolver = MockAudioFileResolver(resolvedURL: resolvedURL)
        let transcriber = MockTranscriber(transcriptToReturn: TranscriptFixture.canned())
        let recorder = OutputRecorder()

        await runResolveAndTranscribeForTest(
            source: .path("/tmp/some-audio.m4a"),
            resolver: resolver,
            transcriber: transcriber,
            recorder: recorder
        )

        let sources = await resolver.receivedSources
        #expect(sources == [.path("/tmp/some-audio.m4a")])

        let requests = await transcriber.receivedRequests
        #expect(requests.count == 1)
        if case .file(let url) = requests.first?.source {
            #expect(url == resolvedURL)
        } else {
            Issue.record("expected request.source == .file(resolvedURL); got \(String(describing: requests.first?.source))")
        }

        let exitCodes = recorder.exitCodes
        #expect(exitCodes == [0])
    }

    // MARK: - Stdin: resolver is called with .stdin and transcriber gets .stdin source

    @Test func stdinHandlerResolvesStdinBeforeTranscribing() async {
        let stagedURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dictamac-resolved-stdin.m4a")
        let resolver = MockAudioFileResolver(resolvedURL: stagedURL)
        let transcriber = MockTranscriber(transcriptToReturn: TranscriptFixture.canned())
        let recorder = OutputRecorder()

        await runResolveAndTranscribeForTest(
            source: .stdin,
            resolver: resolver,
            transcriber: transcriber,
            recorder: recorder
        )

        let sources = await resolver.receivedSources
        #expect(sources == [.stdin])

        let requests = await transcriber.receivedRequests
        #expect(requests.count == 1)
        if case .stdin(let url) = requests.first?.source {
            #expect(url == stagedURL)
        } else {
            Issue.record("expected request.source == .stdin(stagedURL); got \(String(describing: requests.first?.source))")
        }

        let exitCodes = recorder.exitCodes
        #expect(exitCodes == [0])
    }

    // MARK: - File not found: exit 64, transcriber never called

    @Test func missingFileExitsWith64AndSkipsTranscriber() async {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dictamac-missing-\(UUID().uuidString).m4a")
        let resolver = MockAudioFileResolver(
            errorToThrow: DictamacError.fileNotFound(missing)
        )
        let transcriber = MockTranscriber(transcriptToReturn: TranscriptFixture.canned())
        let recorder = OutputRecorder()

        await runResolveAndTranscribeForTest(
            source: .path(missing.path),
            resolver: resolver,
            transcriber: transcriber,
            recorder: recorder
        )

        let exitCodes = recorder.exitCodes
        #expect(exitCodes == [64])

        let requests = await transcriber.receivedRequests
        #expect(requests.isEmpty, "transcriber should not be invoked when the resolver fails")

        let stderr = recorder.stderrText
        #expect(stderr.contains(missing.path), "stderr should name the missing file")

        // No transcript on stdout on the error path.
        let stdout = recorder.stdoutText
        #expect(stdout.isEmpty)
    }

    // MARK: - Empty stdin: exit 65, stderr mentions empty stdin

    @Test func emptyStdinExitsWith65AndMentionsStdin() async {
        let stagedURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dictamac-empty-stdin.m4a")
        let resolver = MockAudioFileResolver(
            errorToThrow: DictamacError.audioDecodeFailed(
                stagedURL,
                underlying: AudioResolverError.stdinEmpty
            )
        )
        let transcriber = MockTranscriber(transcriptToReturn: TranscriptFixture.canned())
        let recorder = OutputRecorder()

        await runResolveAndTranscribeForTest(
            source: .stdin,
            resolver: resolver,
            transcriber: transcriber,
            recorder: recorder
        )

        let exitCodes = recorder.exitCodes
        #expect(exitCodes == [65])

        let requests = await transcriber.receivedRequests
        #expect(requests.isEmpty)

        let stderr = recorder.stderrText.lowercased()
        #expect(stderr.contains("stdin"))
        #expect(stderr.contains("empty"))

        let stdout = recorder.stdoutText
        #expect(stdout.isEmpty)
    }

    // MARK: - Decode failure: exit 65, underlying error surfaced

    @Test func decodeFailureExitsWith65() async {
        let stagedURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dictamac-bad-bytes.m4a")
        struct BogusCodecError: Error, LocalizedError {
            var errorDescription: String? { "bogus codec marker" }
        }
        let resolver = MockAudioFileResolver(
            errorToThrow: DictamacError.audioDecodeFailed(
                stagedURL,
                underlying: BogusCodecError()
            )
        )
        let transcriber = MockTranscriber(transcriptToReturn: TranscriptFixture.canned())
        let recorder = OutputRecorder()

        await runResolveAndTranscribeForTest(
            source: .path("/tmp/whatever.m4a"),
            resolver: resolver,
            transcriber: transcriber,
            recorder: recorder
        )

        let exitCodes = recorder.exitCodes
        #expect(exitCodes == [65])

        let stderr = recorder.stderrText
        #expect(stderr.contains("bogus codec marker"), "underlying error should surface on stderr")
    }

    // MARK: - Cleanup runs on success

    @Test func cleanupRunsOnSuccessPath() async {
        let resolver = MockAudioFileResolver()
        let transcriber = MockTranscriber(transcriptToReturn: TranscriptFixture.canned())
        let recorder = OutputRecorder()

        await runResolveAndTranscribeForTest(
            source: .stdin,
            resolver: resolver,
            transcriber: transcriber,
            recorder: recorder
        )

        // The cleanup closure schedules a detached Task; give the
        // runtime one yield so the counter increment lands before we
        // assert.
        for _ in 0..<10 {
            let count = await resolver.cleanupCallCount
            if count >= 1 { break }
            await Task.yield()
        }
        let cleanupCount = await resolver.cleanupCallCount
        #expect(cleanupCount >= 1, "resolved.cleanup() should be invoked on the success path")
    }

    // MARK: - Cleanup runs when the transcriber fails

    @Test func cleanupRunsWhenTranscriberFails() async {
        let resolver = MockAudioFileResolver()
        struct TranscribeBoom: Error, LocalizedError {
            var errorDescription: String? { "transcribe boom" }
        }
        let transcriber = MockTranscriber(
            transcriptToReturn: TranscriptFixture.canned(),
            errorToThrow: DictamacError.internalFailure(TranscribeBoom())
        )
        let recorder = OutputRecorder()

        await runResolveAndTranscribeForTest(
            source: .stdin,
            resolver: resolver,
            transcriber: transcriber,
            recorder: recorder
        )

        for _ in 0..<10 {
            let count = await resolver.cleanupCallCount
            if count >= 1 { break }
            await Task.yield()
        }
        let cleanupCount = await resolver.cleanupCallCount
        #expect(cleanupCount >= 1, "resolved.cleanup() should fire even when the transcriber fails")

        let exitCodes = recorder.exitCodes
        #expect(exitCodes == [1], "DictamacError.internalFailure maps to exit code 1")
    }

    // MARK: - Plaintext vs JSON output

    @Test func plaintextFormatterIsUsedByDefault() async {
        let resolver = MockAudioFileResolver()
        let transcriber = MockTranscriber(
            transcriptToReturn: TranscriptFixture.canned(text: "hello agent")
        )
        let recorder = OutputRecorder()

        await runResolveAndTranscribeForTest(
            source: .path("/tmp/x.m4a"),
            resolver: resolver,
            transcriber: transcriber,
            recorder: recorder,
            wantsJSON: false
        )

        let stdout = recorder.stdoutText
        #expect(stdout.contains("hello agent"))
        #expect(!stdout.contains("\"version\""), "plaintext output must not contain JSON keys")
    }

    @Test func jsonFormatterIsUsedWhenWantsJSON() async {
        let resolver = MockAudioFileResolver()
        let transcriber = MockTranscriber(
            transcriptToReturn: TranscriptFixture.canned(text: "hello agent")
        )
        let recorder = OutputRecorder()

        await runResolveAndTranscribeForTest(
            source: .path("/tmp/x.m4a"),
            resolver: resolver,
            transcriber: transcriber,
            recorder: recorder,
            wantsJSON: true
        )

        let stdout = recorder.stdoutText
        #expect(stdout.contains("\"version\""), "JSON output must contain the schema version key")
        #expect(stdout.contains("hello agent"))
    }

    // MARK: - Test helper

    /// Drives ``runResolveAndTranscribe`` with a `Void`-returning exit
    /// closure so the test can `await` the call and assert what the
    /// production path would have written / what code it would have
    /// terminated with. Production always passes `Darwin.exit(_:)`
    /// (which is `Never`); the function itself uses an explicit
    /// `return` after every `exit(...)` so the test path stops at the
    /// first exit too.
    ///
    /// The captured closures touch the recorder synchronously under a
    /// lock — using `Task { ... }` here would race the test
    /// assertions because the production function returns before the
    /// detached Tasks have a chance to run.
    private func runResolveAndTranscribeForTest(
        source: AudioSource,
        resolver: any AudioFileResolver,
        transcriber: any Transcriber,
        recorder: OutputRecorder,
        wantsJSON: Bool = false,
        verbose: Bool = false
    ) async {
        await runResolveAndTranscribe(
            source: source,
            resolver: resolver,
            transcriber: transcriber,
            localeIdentifier: "en-US",
            wantsJSON: wantsJSON,
            verbose: verbose,
            writeStdout: { string in
                recorder.appendStdout(string)
            },
            writeStderr: { string in
                recorder.appendStderr(string)
            },
            exit: { code in
                recorder.recordExit(code)
            }
        )
    }
}

/// Collects bytes the production path would have written to stdout /
/// stderr plus the exit codes it would have produced.
///
/// The captured closures in
/// ``runResolveAndTranscribe(source:resolver:transcriber:localeIdentifier:wantsJSON:verbose:writeStdout:writeStderr:exit:)``
/// are `@Sendable` non-async, so synchronous lock-guarded storage is
/// simpler and more deterministic than hopping through `Task { ... }`
/// onto an actor — the latter races with the test assertions when the
/// production function returns before the spawned Tasks have run.
final class OutputRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _stdoutText: String = ""
    private var _stderrText: String = ""
    private var _exitCodes: [Int32] = []

    var stdoutText: String {
        lock.lock(); defer { lock.unlock() }
        return _stdoutText
    }

    var stderrText: String {
        lock.lock(); defer { lock.unlock() }
        return _stderrText
    }

    var exitCodes: [Int32] {
        lock.lock(); defer { lock.unlock() }
        return _exitCodes
    }

    func appendStdout(_ string: String) {
        lock.lock(); defer { lock.unlock() }
        _stdoutText.append(string)
    }

    func appendStderr(_ string: String) {
        lock.lock(); defer { lock.unlock() }
        _stderrText.append(string)
    }

    func recordExit(_ code: Int32) {
        lock.lock(); defer { lock.unlock() }
        _exitCodes.append(code)
    }
}
