import Foundation
import Speech
import DictamacCore

/// Production ``LocaleModelChecker`` that drives Apple's macOS 26
/// `AssetInventory` + `SpeechTranscriber.installedLocales` APIs.
///
/// ## Why this lives in its own file
///
/// The inline bootstrap that landed with PR #40 (`DefaultTranscriber`'s
/// `ensureLocaleModelAvailable` private static) handled only the
/// minimum the analyzer needed to make progress. This implementation
/// is the proper replacement called out in that PR's `changes/` doc:
///
/// 1. Surfaces progress lines for the multi-second first-run download
///    so an agent (or human) doesn't mistake a download for a hang.
/// 2. Maps every failure mode (network unreachable, API error,
///    `.unsupported` status, `@unknown default`) to
///    ``DictamacCore/DictamacError/speechAnalyzerUnavailable(reason:)``
///    → exit code 67.
/// 3. Embeds a manual-install hint in the failure message so a user
///    can prime the model via System Settings when network isn't an
///    option.
/// 4. Reserves the locale unconditionally — without
///    `AssetInventory.reserve(locale:)` the analyzer silently hangs
///    (the framework writes "Cannot use modules with unallocated
///    locales" to the unified log but never throws). This is the
///    single most expensive trap to rediscover. Preserve it.
///
/// ## On the probe `SpeechTranscriber`
///
/// `AssetInventory.status(forModules:)` operates on concrete `Module`
/// instances, not bare locales. We build a short-lived
/// `SpeechTranscriber` purely for the status query; it isn't used to
/// drive any analyzer. The real transcriber that runs the audio is
/// constructed downstream in `DefaultTranscriber.transcribe(_:)`.
public struct SpeechAPILocaleModelChecker: LocaleModelChecker {

    public init() {}

    public func ensureModelAvailable(
        for locale: Locale,
        progress: LocaleModelProgressSink
    ) async throws {
        let probe = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )

        let status = await AssetInventory.status(forModules: [probe])

        switch status {
        case .installed:
            // Fast path. No stderr noise — stdout discipline plus
            // "no extra output when nothing was done" is part of the
            // acceptance criteria.
            break

        case .supported, .downloading:
            try await Self.downloadModel(
                for: probe,
                locale: locale,
                progress: progress
            )

        case .unsupported:
            // The host doesn't ship a model for this locale. No amount
            // of network access fixes this — surface a tailored hint.
            throw DictamacError.speechAnalyzerUnavailable(
                reason: Self.unsupportedReason(for: locale)
            )

        @unknown default:
            // A future `Status` case appears. Conservative bail-out
            // beats blocking on an unknown state.
            throw DictamacError.speechAnalyzerUnavailable(
                reason: Self.unknownStatusReason(for: locale)
            )
        }

        // Reserving is idempotent for already-reserved locales; do it
        // unconditionally so a process that previously released the
        // reservation re-acquires it cleanly. Without the reservation,
        // `SpeechAnalyzer.analyzeSequence` hangs forever — see the
        // type-level note.
        do {
            _ = try await AssetInventory.reserve(locale: locale)
        } catch {
            throw DictamacError.speechAnalyzerUnavailable(
                reason: Self.reservationFailureReason(for: locale, underlying: error)
            )
        }
    }

    // MARK: - Download path

    private static func downloadModel(
        for probe: SpeechTranscriber,
        locale: Locale,
        progress: LocaleModelProgressSink
    ) async throws {
        let identifier = bcp47(locale)
        progress("Downloading speech model for \(identifier)…\n")

        do {
            if let installRequest = try await AssetInventory.assetInstallationRequest(
                supporting: [probe]
            ) {
                try await installRequest.downloadAndInstall()
            }
            // No `installRequest` means the framework decided no work
            // was needed — treat as success. The reservation step that
            // follows in `ensureModelAvailable` is the final gate.
        } catch {
            // Network unreachable, transient API error, AssetInventory
            // surfaces an error — all collapse to exit code 67 with a
            // manual-install hint so the operator has a recovery path.
            throw DictamacError.speechAnalyzerUnavailable(
                reason: downloadFailureReason(for: locale, underlying: error)
            )
        }

        progress("Speech model installed.\n")
    }

    // MARK: - Reason strings

    private static func unsupportedReason(for locale: Locale) -> String {
        let id = bcp47(locale)
        return "Locale \(id) is not supported by SpeechAnalyzer on this device. " +
            "Check the list of supported locales in System Settings → General → " +
            "Language & Region, or invoke dictamac with a different --locale."
    }

    private static func unknownStatusReason(for locale: Locale) -> String {
        let id = bcp47(locale)
        return "Unknown locale model installation status for \(id). " +
            "This is likely a future SDK status the current build of dictamac " +
            "does not recognize; please file an issue."
    }

    private static func downloadFailureReason(
        for locale: Locale,
        underlying: any Error
    ) -> String {
        let id = bcp47(locale)
        let detail = describe(underlying)
        return "Failed to download speech model for \(id): \(detail). " +
            "To trigger the install manually, open System Settings → General → " +
            "Language & Region → Live Captions (or Voice Control) and enable " +
            "the \(id) language; the OS will fetch the model the next time you " +
            "have network access."
    }

    private static func reservationFailureReason(
        for locale: Locale,
        underlying: any Error
    ) -> String {
        let id = bcp47(locale)
        let detail = describe(underlying)
        return "Failed to reserve speech model for \(id): \(detail). " +
            "Another process may be holding the per-host reservation cap; " +
            "close other speech-using apps and retry."
    }

    private static func bcp47(_ locale: Locale) -> String {
        let identifier = locale.identifier(.bcp47)
        return identifier.isEmpty ? locale.identifier : identifier
    }

    private static func describe(_ error: any Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription {
            return localized
        }
        return String(describing: error)
    }
}
