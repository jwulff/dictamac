import Foundation
@testable import DictamacVoiceMemos
@testable import DictamacCore

/// Test-only stub implementation of ``VoiceMemosResolver`` for the
/// `--list-voice-memos` handler tests. Returns canned listings or
/// throws a caller-supplied error so tests can drive the success and
/// failure paths without standing up a real Voice Memos library.
///
/// Modelled as a final class with @unchecked Sendable so callers can
/// inspect captured arguments synchronously inside the test body —
/// the actor variant would require awaits inside @Sendable closures
/// and complicate the handler-recording shape.
final class MockVoiceMemosResolver: VoiceMemosResolver, @unchecked Sendable {
    private let lock = NSLock()
    private var _listings: [VoiceMemoMetadata]
    private var _errorToThrow: (any Error)?
    private var _receivedListSince: [Date] = []
    private var _receivedListLimit: [Int] = []

    init(
        listings: [VoiceMemoMetadata] = [],
        errorToThrow: (any Error)? = nil
    ) {
        self._listings = listings
        self._errorToThrow = errorToThrow
    }

    var receivedListSince: [Date] {
        lock.lock(); defer { lock.unlock() }
        return _receivedListSince
    }

    var receivedListLimit: [Int] {
        lock.lock(); defer { lock.unlock() }
        return _receivedListLimit
    }

    func resolve(_ query: VoiceMemoQuery, now: Date) throws -> VoiceMemoMetadata {
        lock.lock(); defer { lock.unlock() }
        if let _errorToThrow {
            throw _errorToThrow
        }
        guard let first = _listings.first else {
            throw DictamacError.voiceMemoNotFound(query: "<mock>")
        }
        return first
    }

    func list(since: Date, limit: Int) throws -> [VoiceMemoMetadata] {
        lock.lock()
        _receivedListSince.append(since)
        _receivedListLimit.append(limit)
        let listings = _listings
        let error = _errorToThrow
        lock.unlock()
        if let error {
            throw error
        }
        return Array(listings.prefix(limit))
    }
}
