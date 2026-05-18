import Foundation
import Testing
@testable import DictamacCore
@testable import DictamacSpeech

/// Unit tests for the pure status-to-decision and reason-string
/// mapping helpers on ``SpeechAPILocaleModelChecker``.
///
/// These tests exist because the failure-mode tests in
/// ``LocaleModelCheckerTests`` exercise the protocol seam via
/// ``MockLocaleModelChecker`` — which throws *already-mapped*
/// `DictamacError` values. A regression in the production checker's
/// real ``LocaleModelInstallStatus`` → ``LocaleModelDecision`` mapping
/// (the `.unsupported` branch, `.unknown` / `@unknown default` branch,
/// or the human-readable reason strings) would not be caught by the
/// mock-driven tests.
///
/// The internal ``LocaleModelInstallStatus`` enum exists precisely so
/// these tests can synthesize every observable status without needing
/// a network, a host-specific model state, or constructable
/// `AssetInventory.Status` values (Apple's framework type has no public
/// initializer). Production code translates the framework status via
/// ``SpeechAPILocaleModelChecker/translate(_:)`` and then dispatches
/// off the internal enum that's exercised here, so the mapping under
/// test is exactly the production mapping.
struct SpeechAPILocaleModelCheckerMappingTests {

    // MARK: - decide(forStatus:locale:)

    @Test func installedStatusMapsToAlreadyInstalled() {
        let locale = Locale(identifier: "en-US")
        let decision = SpeechAPILocaleModelChecker.decide(
            forStatus: .installed,
            locale: locale
        )
        #expect(decision == .alreadyInstalled)
    }

    @Test func supportedStatusMapsToInstall() {
        let locale = Locale(identifier: "en-US")
        let decision = SpeechAPILocaleModelChecker.decide(
            forStatus: .supported,
            locale: locale
        )
        #expect(decision == .install)
    }

    @Test func downloadingStatusMapsToInstall() {
        let locale = Locale(identifier: "en-US")
        let decision = SpeechAPILocaleModelChecker.decide(
            forStatus: .downloading,
            locale: locale
        )
        #expect(decision == .install)
    }

    @Test func unsupportedStatusMapsToFailWithUnsupportedReason() {
        let locale = Locale(identifier: "qq-QQ")
        let decision = SpeechAPILocaleModelChecker.decide(
            forStatus: .unsupported,
            locale: locale
        )
        guard case .fail(let reason) = decision else {
            Issue.record("expected .fail, got \(decision)")
            return
        }
        #expect(reason.contains("qq-QQ"))
        #expect(reason.contains("not supported"))
        #expect(reason.contains("System Settings"))
        // Cross-check parity with the dedicated reason-string helper.
        let direct = SpeechAPILocaleModelChecker.unsupportedReason(for: locale)
        #expect(reason == direct)
    }

    @Test func unknownStatusMapsToFailWithFutureSDKReason() {
        let locale = Locale(identifier: "en-US")
        let decision = SpeechAPILocaleModelChecker.decide(
            forStatus: .unknown,
            locale: locale
        )
        guard case .fail(let reason) = decision else {
            Issue.record("expected .fail, got \(decision)")
            return
        }
        #expect(reason.contains("Unknown"))
        #expect(reason.contains("en-US"))
        #expect(reason.contains("file an issue"))
        let direct = SpeechAPILocaleModelChecker.unknownStatusReason(for: locale)
        #expect(reason == direct)
    }

    // MARK: - Reason-string helpers in isolation

    @Test func unsupportedReasonNamesTheLocaleAndPointsAtSystemSettings() {
        let reason = SpeechAPILocaleModelChecker.unsupportedReason(
            for: Locale(identifier: "fr-FR")
        )
        #expect(reason.contains("fr-FR"))
        #expect(reason.contains("not supported"))
        #expect(reason.contains("Language & Region"))
    }

    @Test func unknownStatusReasonNamesTheLocaleAndAsksForAnIssue() {
        let reason = SpeechAPILocaleModelChecker.unknownStatusReason(
            for: Locale(identifier: "de-DE")
        )
        #expect(reason.contains("de-DE"))
        #expect(reason.contains("future SDK"))
        #expect(reason.contains("file an issue"))
    }

    @Test func downloadFailureReasonEmbedsUnderlyingErrorAndManualHint() {
        struct Underlying: LocalizedError {
            var errorDescription: String? { "network unreachable" }
        }
        let reason = SpeechAPILocaleModelChecker.downloadFailureReason(
            for: Locale(identifier: "en-US"),
            underlying: Underlying()
        )
        #expect(reason.contains("en-US"))
        #expect(reason.contains("network unreachable"))
        #expect(reason.contains("manually"))
        #expect(reason.contains("Live Captions"))
    }

    @Test func reservationFailureReasonNamesLocaleAndCapHint() {
        struct Underlying: LocalizedError {
            var errorDescription: String? { "reservation cap exceeded" }
        }
        let reason = SpeechAPILocaleModelChecker.reservationFailureReason(
            for: Locale(identifier: "en-US"),
            underlying: Underlying()
        )
        #expect(reason.contains("en-US"))
        #expect(reason.contains("reservation cap exceeded"))
        #expect(reason.contains("retry"))
    }

    // MARK: - BCP-47 normalization

    @Test func bcp47FallsBackToRawIdentifierForLocalesWithoutBCP47Form() {
        // The standard en-US locale produces "en-US" via the BCP-47
        // identifier accessor.
        let normal = SpeechAPILocaleModelChecker.bcp47(Locale(identifier: "en-US"))
        #expect(normal == "en-US")

        // Underscore-separated identifiers are normalized to dashes by
        // the BCP-47 accessor (Locale converts "en_US" → "en-US" on
        // initialization), so the helper still produces a stable form.
        let underscored = SpeechAPILocaleModelChecker.bcp47(Locale(identifier: "en_US"))
        #expect(underscored == "en-US")
    }
}
