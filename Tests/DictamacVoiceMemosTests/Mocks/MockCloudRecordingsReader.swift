import Foundation
@testable import DictamacVoiceMemos

/// Test-only ``CloudRecordingsReader`` that returns a canned list of
/// memos or throws a canned ``CloudRecordingsError``. Each instance
/// fires exactly once — the resolver only ever calls ``recordings()``
/// per `resolve` / `list` invocation, so the test surface needs no
/// scripted multi-call behavior.
final class MockCloudRecordingsReader: CloudRecordingsReader, Sendable {
    private let result: Result<[VoiceMemoMetadata], CloudRecordingsError>

    init(memos: [VoiceMemoMetadata]) {
        self.result = .success(memos)
    }

    init(error: CloudRecordingsError) {
        self.result = .failure(error)
    }

    func recordings() throws -> [VoiceMemoMetadata] {
        switch result {
        case .success(let memos):
            return memos
        case .failure(let error):
            throw error
        }
    }
}
