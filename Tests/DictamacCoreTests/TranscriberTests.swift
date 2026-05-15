import Testing
import Foundation
@testable import DictamacCore

struct TranscriberTests {

    @Test func mockReturnsCannedTranscript() async throws {
        let expected = makeTranscript(text: "ok")
        let mock = MockTranscriber(transcriptToReturn: expected)
        let request = TranscriptionRequest(
            source: .file(URL(fileURLWithPath: "/x.m4a")),
            locale: Locale(identifier: "en-US"),
            format: .text
        )

        let result = try await mock.transcribe(request)

        #expect(result.fullText == "ok")
        #expect(result.locale == expected.locale)
        let received = await mock.receivedRequests
        #expect(received.count == 1)
    }

    @Test func mockRecordsEveryRequestInOrder() async throws {
        let mock = MockTranscriber(transcriptToReturn: makeTranscript(text: "x"))
        let req1 = TranscriptionRequest(
            source: .file(URL(fileURLWithPath: "/a.m4a")),
            locale: Locale(identifier: "en-US"),
            format: .text
        )
        let req2 = TranscriptionRequest(
            source: .stdin(URL(fileURLWithPath: "/tmp/stdin.m4a")),
            locale: Locale(identifier: "en-US"),
            format: .json
        )

        _ = try await mock.transcribe(req1)
        _ = try await mock.transcribe(req2)

        let received = await mock.receivedRequests
        #expect(received.count == 2)
        if case .file(let url) = received[0].source {
            #expect(url == URL(fileURLWithPath: "/a.m4a"))
        } else {
            Issue.record("expected .file source on first request")
        }
        if case .stdin(let url) = received[1].source {
            #expect(url == URL(fileURLWithPath: "/tmp/stdin.m4a"))
        } else {
            Issue.record("expected .stdin source on second request")
        }
    }

    @Test func mockThrowsWhenErrorConfigured() async throws {
        struct FakeError: Error, Equatable {}
        let mock = MockTranscriber(
            transcriptToReturn: makeTranscript(text: "x"),
            errorToThrow: FakeError()
        )
        let request = TranscriptionRequest(
            source: .file(URL(fileURLWithPath: "/x.m4a")),
            locale: Locale(identifier: "en-US"),
            format: .json
        )

        await #expect(throws: FakeError.self) {
            try await mock.transcribe(request)
        }
    }

    @Test func transcriberCanBeUsedAsExistential() async throws {
        // Compile-time check: both transports (CLI + MCP) depend on the
        // protocol, never the concrete type. If this stops compiling, the
        // protocol seam is broken.
        let transcriber: any Transcriber = MockTranscriber(
            transcriptToReturn: makeTranscript(text: "hi")
        )
        let result = try await transcriber.transcribe(
            TranscriptionRequest(
                source: .file(URL(fileURLWithPath: "/x.m4a")),
                locale: Locale(identifier: "en-US"),
                format: .text
            )
        )
        #expect(result.fullText == "hi")
    }

    private func makeTranscript(text: String) -> Transcript {
        Transcript(
            segments: [.init(startSeconds: 0, endSeconds: 1, text: text, confidence: nil)],
            locale: "en-US",
            durationSeconds: 1,
            model: "test",
            source: .file(path: "/x.m4a")
        )
    }
}
