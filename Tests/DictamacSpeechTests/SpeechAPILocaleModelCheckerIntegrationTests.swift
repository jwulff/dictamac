import Foundation
import Testing
@testable import DictamacCore
@testable import DictamacSpeech

/// Integration tests against the real ``SpeechAPILocaleModelChecker``.
///
/// These tests touch the actual `AssetInventory` / `SpeechTranscriber`
/// APIs and assume the en-US speech model is already installed on the
/// host (which is the standard developer-laptop state and the explicit
/// precondition for PR #40's end-to-end fixture test).
///
/// Failure modes that REQUIRE network unreachability or an
/// `.unsupported` locale on the host are not exercised here — those
/// are covered by the protocol-seam tests in
/// ``LocaleModelCheckerTests`` via ``MockLocaleModelChecker``. This
/// file's job is to pin the already-installed fast path (no progress
/// output, no throw) against the real framework so a regression in the
/// production wrapper is caught locally.
struct SpeechAPILocaleModelCheckerIntegrationTests {

    /// Capture sink for asserting "no progress output emitted". Mirrors
    /// the actor-backed buffer in ``LocaleModelCheckerTests`` so the
    /// async dispatch into the sink is observable.
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

        func waitForPendingWrites() async {
            await Task.yield()
            await Task.yield()
        }
    }

    @Test func alreadyInstalledEnUSEmitsNoProgressAndDoesNotThrow() async throws {
        let capture = ProgressCapture()
        let checker = SpeechAPILocaleModelChecker()
        let locale = Locale(identifier: "en-US")

        // If the host doesn't have en-US installed, this test would
        // emit "Downloading…" / "installed." lines instead. That's not
        // a regression in the checker — it's a precondition failure
        // for the test runner. Surface the captured lines on failure
        // so the diagnostic is obvious.
        try await checker.ensureModelAvailable(
            for: locale,
            progress: capture.sink()
        )

        await capture.waitForPendingWrites()
        let captured = await capture.lines
        let diagnostic: Comment = "expected zero progress lines on already-installed fast path; got \(captured). If this fails, the en-US model is not yet installed on this host — run dictamac once against the en-US fixture to trigger the first-run download."
        #expect(captured.isEmpty, diagnostic)
    }
}
