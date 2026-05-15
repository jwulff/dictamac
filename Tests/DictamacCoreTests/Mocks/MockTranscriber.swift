import Foundation
@testable import DictamacCore

/// Test-only stub implementation of ``Transcriber``. Returns a canned
/// ``Transcript`` and records each incoming request so downstream tests
/// (CLI parser, MCP loop, voice-memo dispatch) can assert what was sent.
///
/// Modelled as an actor so it satisfies the protocol's ``Sendable``
/// requirement without needing `@unchecked`.
actor MockTranscriber: Transcriber {
    var transcriptToReturn: Transcript
    var errorToThrow: Error?
    private(set) var receivedRequests: [TranscriptionRequest] = []

    init(transcriptToReturn: Transcript, errorToThrow: Error? = nil) {
        self.transcriptToReturn = transcriptToReturn
        self.errorToThrow = errorToThrow
    }

    func transcribe(_ request: TranscriptionRequest) async throws -> Transcript {
        receivedRequests.append(request)
        if let errorToThrow {
            throw errorToThrow
        }
        return transcriptToReturn
    }

    func setError(_ error: Error?) {
        self.errorToThrow = error
    }

    func setTranscript(_ transcript: Transcript) {
        self.transcriptToReturn = transcript
    }
}
