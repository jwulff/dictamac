import Foundation
import Speech
import Testing
@testable import DictamacCore
@testable import DictamacSpeech

/// Integration tests against the real ``SpeechAPILocaleModelChecker``.
///
/// These tests touch the actual `AssetInventory` / `SpeechTranscriber`
/// APIs. The fast-path assertion is host-dependent: it requires the
/// en-US speech model to be already installed on the test runner. A
/// fresh CI image or a freshly-provisioned developer machine has no
/// models installed; running the test there would (correctly) take the
/// slow `.supported` → install path and emit progress lines, failing
/// the assertion for an environmental reason rather than a regression
/// in the checker.
///
/// Rather than make CI conditional on a manual one-time bootstrap of
/// the en-US model, the test preflights `AssetInventory.status` and
/// records a skip when the precondition isn't met. This keeps the suite
/// green on both seasoned developer machines (where it really does
/// validate the fast path) and on fresh hosts (where it explicitly
/// announces why it's skipping). Failure modes that don't depend on
/// host state — the `.unsupported` and `@unknown default` branches and
/// every reason string — are covered by the pure mapping tests in
/// ``SpeechAPILocaleModelCheckerMappingTests``, and by the
/// mock-driven failure-mode tests in ``LocaleModelCheckerTests``.
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
        let locale = Locale(identifier: "en-US")

        // Preflight: only run this assertion when the en-US model is
        // already installed. On a fresh host the slow path is the
        // correct behavior and would emit progress lines, so the
        // assertion would fail for an environmental reason. Skip
        // explicitly with a diagnostic pointing at how to install.
        let probe = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
        let rawStatus = await AssetInventory.status(forModules: [probe])
        guard rawStatus == .installed else {
            Issue.record(
                """
                skipped: en-US speech model is not installed on this host \
                (AssetInventory.status reported \(rawStatus)). The fast-path \
                assertion is host-dependent — run dictamac once against \
                Tests/DictamacSpeechTests/Fixtures/hello-world.m4a to trigger \
                the first-run download, or rely on the pure mapping tests in \
                SpeechAPILocaleModelCheckerMappingTests for status-to-error \
                coverage that does not require an installed model.
                """
            )
            return
        }

        let capture = ProgressCapture()
        let checker = SpeechAPILocaleModelChecker()

        try await checker.ensureModelAvailable(
            for: locale,
            progress: capture.sink()
        )

        await capture.waitForPendingWrites()
        let captured = await capture.lines
        let diagnostic: Comment = "expected zero progress lines on already-installed fast path; got \(captured)."
        #expect(captured.isEmpty, diagnostic)
    }
}
