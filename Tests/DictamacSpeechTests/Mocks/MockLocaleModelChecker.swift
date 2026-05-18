import Foundation
@testable import DictamacSpeech

/// Test-only stub implementation of ``LocaleModelChecker``.
///
/// Each test case configures one of three behaviors via ``Outcome``:
///
/// - `.success(emit:)` — record the request, optionally emit fake
///   progress lines to the injected sink (to validate stderr wiring),
///   return cleanly.
/// - `.throwError(_:)` — throw the supplied error verbatim. Tests pass
///   a `DictamacError.speechAnalyzerUnavailable(reason:)` to mimic the
///   real failure modes (no network, `.unsupported`, `@unknown default`,
///   reservation cap exceeded).
///
/// Modelled as an actor so it satisfies the protocol's `Sendable`
/// requirement without `@unchecked`, mirroring the `MockTranscriber`
/// shape in `Tests/DictamacCoreTests/Mocks/`.
actor MockLocaleModelChecker: LocaleModelChecker {
    enum Outcome: Sendable {
        case success(emit: [String])
        case throwError(any Error)
    }

    private let outcome: Outcome
    private(set) var receivedLocales: [Locale] = []

    init(outcome: Outcome) {
        self.outcome = outcome
    }

    func ensureModelAvailable(
        for locale: Locale,
        progress: LocaleModelProgressSink
    ) async throws {
        receivedLocales.append(locale)
        switch outcome {
        case .success(let lines):
            for line in lines {
                progress(line)
            }
        case .throwError(let error):
            throw error
        }
    }
}
