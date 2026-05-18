import Foundation
import Testing
@testable import DictamacCore
@testable import DictamacSpeech

/// Tests that don't require a live `SpeechAnalyzer`. The end-to-end
/// transcription of the committed `.m4a` fixture lives in
/// ``IntegrationTests`` so it can be gated separately if a CI runner
/// lacks the on-device speech model.
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

        await #expect(throws: DictamacError.self) {
            try await transcriber.transcribe(request)
        }
    }

    @Test func modelIdentifierMatchesPlanContract() {
        // The JSON schema (PLAN.md §6) pins `model` to this exact string,
        // so it's a stable public contract; tests assert the literal.
        #expect(DefaultTranscriber.modelIdentifier == "SpeechAnalyzer/macOS26")
    }
}
