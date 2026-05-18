import Foundation
@testable import DictamacVoiceMemos

/// Test-only ``FilesystemRecordingsScanner`` that returns a canned
/// list of memos (or throws). Records the `libraryURL` it was called
/// with so callers can assert the resolver propagated the right path.
final class MockFilesystemRecordingsScanner: FilesystemRecordingsScanner, @unchecked Sendable {
    private let memos: [VoiceMemoMetadata]
    private let errorToThrow: Error?
    private let lock = NSLock()
    private var capturedURLs: [URL] = []

    init(memos: [VoiceMemoMetadata] = [], errorToThrow: Error? = nil) {
        self.memos = memos
        self.errorToThrow = errorToThrow
    }

    func scan(libraryURL: URL) throws -> [VoiceMemoMetadata] {
        lock.lock()
        capturedURLs.append(libraryURL)
        lock.unlock()
        if let errorToThrow {
            throw errorToThrow
        }
        return memos
    }

    var receivedLibraryURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return capturedURLs
    }
}
