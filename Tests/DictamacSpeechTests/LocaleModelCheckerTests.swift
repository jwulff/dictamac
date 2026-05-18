import Foundation
import Testing
@testable import DictamacCore
@testable import DictamacSpeech

/// Tests covering the ``LocaleModelChecker`` seam and its production
/// glue inside ``DefaultTranscriber``.
///
/// These tests do NOT touch the real `SpeechAnalyzer` /
/// `AssetInventory` APIs. They drive the protocol seam with
/// ``MockLocaleModelChecker`` and a capture sink so each of the
/// failure modes (no network, `.unsupported`, `@unknown default`,
/// reservation failure) can be exercised deterministically.
struct LocaleModelCheckerTests {

    // MARK: - Capture sink

    /// Actor-backed buffer that collects every line written to a
    /// ``LocaleModelProgressSink``. Swift Testing's `#expect` runs
    /// synchronously, so tests `await` the buffer's `lines` accessor
    /// before asserting.
    private actor ProgressCapture {
        private(set) var lines: [String] = []

        func append(_ line: String) {
            lines.append(line)
        }

        func sink() -> LocaleModelProgressSink {
            LocaleModelProgressSink { line in
                Task { await self.append(line) }
            }
        }

        /// Drain in-flight `Task { await append … }` writes that the
        /// sink fires off. Tests use this as the synchronization point
        /// before asserting `lines`.
        func waitForPendingWrites() async {
            // Yield twice: once to let the dispatched Task pick up,
            // once to let its `await append(_:)` continuation run on
            // this actor.
            await Task.yield()
            await Task.yield()
        }
    }

    // MARK: - Already-installed fast path

    @Test func alreadyInstalledLocaleEmitsNoProgress() async throws {
        let capture = ProgressCapture()
        let checker = MockLocaleModelChecker(outcome: .success(emit: []))
        let locale = Locale(identifier: "en-US")

        try await checker.ensureModelAvailable(
            for: locale,
            progress: capture.sink()
        )

        await capture.waitForPendingWrites()
        let received = await checker.receivedLocales
        let captured = await capture.lines
        #expect(received == [locale])
        #expect(captured.isEmpty, "fast path must produce no stderr output, got \(captured)")
    }

    // MARK: - Missing + reachable: download progress

    @Test func missingLocaleEmitsDownloadProgressLines() async throws {
        let capture = ProgressCapture()
        let checker = MockLocaleModelChecker(outcome: .success(emit: [
            "Downloading speech model for en-US…\n",
            "Speech model installed.\n",
        ]))
        let locale = Locale(identifier: "en-US")

        try await checker.ensureModelAvailable(
            for: locale,
            progress: capture.sink()
        )

        await capture.waitForPendingWrites()
        let captured = await capture.lines
        #expect(captured.count == 2)
        #expect(captured.first?.contains("Downloading") == true)
        #expect(captured.first?.contains("en-US") == true)
        #expect(captured.last?.contains("installed") == true)
        // Each line is newline-terminated — the sink writes verbatim,
        // so any caller responsible for joining is the one that adds
        // the `\n`.
        for line in captured {
            #expect(line.hasSuffix("\n"), "progress line missing trailing newline: \(line)")
        }
    }

    // MARK: - Failure modes → exit 67

    @Test func missingNetworkSurfacesAsExit67() async throws {
        let reason = "Failed to download speech model for en-US: network unreachable. To trigger the install manually…"
        let checker = MockLocaleModelChecker(
            outcome: .throwError(DictamacError.speechAnalyzerUnavailable(reason: reason))
        )
        let locale = Locale(identifier: "en-US")

        await expectSpeechAnalyzerUnavailable(
            from: checker,
            for: locale,
            assertReasonContains: ["network", "manually"]
        )
    }

    @Test func unsupportedLocaleSurfacesAsExit67() async throws {
        let reason = "Locale qq-QQ is not supported by SpeechAnalyzer on this device. Check the list…"
        let checker = MockLocaleModelChecker(
            outcome: .throwError(DictamacError.speechAnalyzerUnavailable(reason: reason))
        )
        let locale = Locale(identifier: "qq-QQ")

        await expectSpeechAnalyzerUnavailable(
            from: checker,
            for: locale,
            assertReasonContains: ["not supported", "qq-QQ"]
        )
    }

    @Test func unknownFutureStatusSurfacesAsExit67() async throws {
        let reason = "Unknown locale model installation status for en-US. This is likely a future SDK status…"
        let checker = MockLocaleModelChecker(
            outcome: .throwError(DictamacError.speechAnalyzerUnavailable(reason: reason))
        )
        let locale = Locale(identifier: "en-US")

        await expectSpeechAnalyzerUnavailable(
            from: checker,
            for: locale,
            assertReasonContains: ["Unknown", "en-US"]
        )
    }

    @Test func reservationFailureSurfacesAsExit67() async throws {
        let reason = "Failed to reserve speech model for en-US: per-process cap exceeded. Close other speech-using apps…"
        let checker = MockLocaleModelChecker(
            outcome: .throwError(DictamacError.speechAnalyzerUnavailable(reason: reason))
        )
        let locale = Locale(identifier: "en-US")

        await expectSpeechAnalyzerUnavailable(
            from: checker,
            for: locale,
            assertReasonContains: ["reserve", "en-US"]
        )
    }

    // MARK: - DefaultTranscriber wiring

    /// The injected checker must run BEFORE any audio decoding step
    /// touches the SpeechAnalyzer — that's the entire point of the
    /// seam (catch missing models before the framework hangs).
    ///
    /// We assert ordering indirectly: if the checker throws, the
    /// transcribe call surfaces that error verbatim, even with an
    /// audio file that would otherwise decode cleanly. The fixture is
    /// the existing `hello-world.m4a` so the decode would succeed if
    /// the checker were skipped.
    @Test func defaultTranscriberSurfacesCheckerFailureWithExitCode67() async throws {
        let fixtureURL = try requireFixture(name: "hello-world", extension: "m4a")
        let reason = "Failed to download speech model for en-US: no network. Open System Settings…"
        let checker = MockLocaleModelChecker(
            outcome: .throwError(DictamacError.speechAnalyzerUnavailable(reason: reason))
        )
        let transcriber = DefaultTranscriber(
            localeModelChecker: checker,
            progressSink: .null
        )
        let request = TranscriptionRequest(
            source: .file(fixtureURL),
            locale: Locale(identifier: "en-US"),
            format: .text
        )

        do {
            _ = try await transcriber.transcribe(request)
            Issue.record("expected transcribe to throw, got success")
        } catch let error as DictamacError {
            guard case .speechAnalyzerUnavailable(let surfaced) = error else {
                Issue.record("expected .speechAnalyzerUnavailable, got \(error)")
                return
            }
            #expect(surfaced == reason)
            #expect(error.exitCode == 67)
        }

        // And the checker actually ran — sanity-check it got the
        // request's locale, not a stale default.
        let received = await checker.receivedLocales
        #expect(received == [Locale(identifier: "en-US")])
    }

    /// File-not-found is decided BEFORE the model bootstrap runs — by
    /// design, since `DefaultTranscriber` resolves the URL and opens
    /// the audio file first, and only invokes the checker once the
    /// file open has succeeded. The actual existing behavior (verified
    /// by `missingFileSurfacesAsFileNotFoundError` in
    /// `DefaultTranscriberTests`) is that the file open precedes the
    /// bootstrap call. This test pins that ordering: a missing file
    /// short-circuits BEFORE the checker is consulted, so the mock
    /// should record zero invocations even though we constructed it
    /// with a throw-on-call outcome.
    @Test func fileResolutionPrecedesModelBootstrap() async throws {
        let missingURL = URL(fileURLWithPath: "/tmp/dictamac-locale-checker-test-\(UUID().uuidString).m4a")
        let unexpectedFailure = DictamacError.speechAnalyzerUnavailable(
            reason: "checker should not have been called"
        )
        let checker = MockLocaleModelChecker(outcome: .throwError(unexpectedFailure))
        let transcriber = DefaultTranscriber(
            localeModelChecker: checker,
            progressSink: .null
        )
        let request = TranscriptionRequest(
            source: .file(missingURL),
            locale: Locale(identifier: "en-US"),
            format: .text
        )

        do {
            _ = try await transcriber.transcribe(request)
            Issue.record("expected transcribe to throw, got success")
        } catch let error as DictamacError {
            guard case .fileNotFound = error else {
                Issue.record("expected .fileNotFound, got \(error)")
                return
            }
        }

        let received = await checker.receivedLocales
        #expect(received.isEmpty, "checker should not have been invoked for a missing file")
    }

    // MARK: - Progress sink contract

    @Test func standardErrorSinkIsConstructible() {
        // The static accessor is a `let`, not a func, so this is
        // effectively a compile check that the type is right. We don't
        // exercise the actual stderr write — that's covered by the
        // integration test through end-to-end behavior, and unit-style
        // stderr capture is brittle across test runners.
        let sink: LocaleModelProgressSink = .standardError
        _ = sink
    }

    @Test func nullSinkSilentlyDiscards() {
        let sink: LocaleModelProgressSink = .null
        sink("noise that should vanish\n") // no crash, no assertion needed
    }

    // MARK: - Helpers

    private func expectSpeechAnalyzerUnavailable(
        from checker: MockLocaleModelChecker,
        for locale: Locale,
        assertReasonContains substrings: [String]
    ) async {
        do {
            try await checker.ensureModelAvailable(
                for: locale,
                progress: .null
            )
            Issue.record("expected ensureModelAvailable to throw, got success")
        } catch let error as DictamacError {
            guard case .speechAnalyzerUnavailable(let reason) = error else {
                Issue.record("expected .speechAnalyzerUnavailable, got \(error)")
                return
            }
            #expect(error.exitCode == 67)
            for needle in substrings {
                #expect(reason.contains(needle), "reason missing '\(needle)': \(reason)")
            }
        } catch {
            Issue.record("expected DictamacError, got \(type(of: error)): \(error)")
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
