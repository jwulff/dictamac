import Foundation
@testable import DictamacCore

/// Test-only stub implementation of ``Transcriber`` for the CLI
/// dispatch tests. Returns a canned ``Transcript`` and records every
/// incoming ``TranscriptionRequest`` so tests can assert the resolver's
/// URL flowed through correctly.
///
/// Modelled as an actor so it satisfies the protocol's ``Sendable``
/// requirement without needing `@unchecked`. Mirrors
/// `Tests/DictamacCoreTests/Mocks/MockTranscriber.swift` — kept
/// independent so the CLI test target doesn't pull in the core test
/// target.
actor MockTranscriber: Transcriber {
    let transcriptToReturn: Transcript
    let errorToThrow: (any Error)?
    private(set) var receivedRequests: [TranscriptionRequest] = []

    init(transcriptToReturn: Transcript, errorToThrow: (any Error)? = nil) {
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
}

/// Convenience builder for a minimal ``Transcript`` value used by the
/// CLI dispatch tests. Keeps the call sites readable — most tests only
/// care that the transcript flowed through, not its content.
enum TranscriptFixture {
    static func canned(
        text: String = "hello world",
        source: TranscriptSource = .file(path: "/mock/path.m4a")
    ) -> Transcript {
        Transcript(
            segments: [
                TranscriptSegment(
                    startSeconds: 0,
                    endSeconds: 1,
                    text: text,
                    confidence: nil
                )
            ],
            locale: "en-US",
            durationSeconds: 1,
            model: "MockTranscriber",
            source: source
        )
    }
}
