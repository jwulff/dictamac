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
///
/// ## Testability of the status-to-error mapping
///
/// `AssetInventory.Status` cases are not constructable in tests (no
/// public initializer for the framework type). To keep the mapping
/// directly unit-testable without a network or a host-specific locale
/// state, the production code translates every observed
/// `AssetInventory.Status` into the internal ``LocaleModelInstallStatus``
/// enum and dispatches mapping decisions off that. Tests synthesize
/// `LocaleModelInstallStatus` values and exercise the same
/// ``decide(forStatus:locale:)`` and reason-string helpers the
/// production path uses.
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

        let rawStatus = await AssetInventory.status(forModules: [probe])
        let status = Self.translate(rawStatus)

        switch Self.decide(forStatus: status, locale: locale) {
        case .alreadyInstalled:
            // Fast path. No stderr noise — stdout discipline plus
            // "no extra output when nothing was done" is part of the
            // acceptance criteria.
            break

        case .install:
            try await Self.downloadModel(
                for: probe,
                locale: locale,
                progress: progress
            )

        case .fail(let reason):
            throw DictamacError.speechAnalyzerUnavailable(reason: reason)
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

    // MARK: - Status translation

    /// Map the framework's `AssetInventory.Status` onto our internal
    /// ``LocaleModelInstallStatus``. This exists because the framework
    /// enum cases are not constructable in tests, while our internal
    /// enum is — preserving the contract that every observable status
    /// maps to exactly one branch of ``decide(forStatus:locale:)``.
    ///
    /// `@unknown default` collapses any future SDK case onto our
    /// internal `.unknown` so the mapping decision (fail with a
    /// `future-SDK` hint) is in one place.
    static func translate(_ status: AssetInventory.Status) -> LocaleModelInstallStatus {
        switch status {
        case .installed:
            return .installed
        case .supported:
            return .supported
        case .downloading:
            return .downloading
        case .unsupported:
            return .unsupported
        @unknown default:
            return .unknown
        }
    }

    // MARK: - Pure mapping (unit-tested directly)

    /// Pure decision over a translated status. Lives as a `static`
    /// function with no I/O so unit tests can hammer every branch
    /// without touching `AssetInventory`, `SpeechTranscriber`, or
    /// the network.
    static func decide(
        forStatus status: LocaleModelInstallStatus,
        locale: Locale
    ) -> LocaleModelDecision {
        switch status {
        case .installed:
            return .alreadyInstalled
        case .supported, .downloading:
            return .install
        case .unsupported:
            return .fail(reason: unsupportedReason(for: locale))
        case .unknown:
            return .fail(reason: unknownStatusReason(for: locale))
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

    // MARK: - Reason strings (pure, unit-tested directly)

    static func unsupportedReason(for locale: Locale) -> String {
        let id = bcp47(locale)
        return "Locale \(id) is not supported by SpeechAnalyzer on this device. " +
            "Check the list of supported locales in System Settings → General → " +
            "Language & Region, or invoke dictamac with a different --locale."
    }

    static func unknownStatusReason(for locale: Locale) -> String {
        let id = bcp47(locale)
        return "Unknown locale model installation status for \(id). " +
            "This is likely a future SDK status the current build of dictamac " +
            "does not recognize; please file an issue."
    }

    static func downloadFailureReason(
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

    static func reservationFailureReason(
        for locale: Locale,
        underlying: any Error
    ) -> String {
        let id = bcp47(locale)
        let detail = describe(underlying)
        return "Failed to reserve speech model for \(id): \(detail). " +
            "Another process may be holding the per-host reservation cap; " +
            "close other speech-using apps and retry."
    }

    static func bcp47(_ locale: Locale) -> String {
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

// MARK: - Internal status & decision types

/// Internal mirror of `AssetInventory.Status` constructable in tests.
///
/// The framework's enum is `frozen`-style for the runtime but has no
/// public initializer, so test code cannot synthesize a `.unsupported`
/// or `.installed` value to drive
/// ``SpeechAPILocaleModelChecker/decide(forStatus:locale:)`` directly.
/// This enum is the seam: production translates the framework value
/// once via ``SpeechAPILocaleModelChecker/translate(_:)`` and every
/// downstream decision (already-installed / install / fail) runs off
/// the internal enum that tests can construct.
///
/// `.unknown` represents the `@unknown default` branch of the framework
/// switch — a future SDK case we don't yet recognize.
enum LocaleModelInstallStatus: Sendable, Equatable {
    case installed
    case supported
    case downloading
    case unsupported
    case unknown
}

/// What ``SpeechAPILocaleModelChecker/decide(forStatus:locale:)`` says
/// the caller should do next. The reason string for the failure case is
/// the same one that ends up inside
/// `DictamacError.speechAnalyzerUnavailable(reason:)`, so tests can pin
/// the exact human-readable text without indirection through the error
/// type.
enum LocaleModelDecision: Sendable, Equatable {
    case alreadyInstalled
    case install
    case fail(reason: String)
}
