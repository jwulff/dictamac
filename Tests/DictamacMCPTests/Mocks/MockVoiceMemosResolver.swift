import Foundation
@testable import DictamacVoiceMemos
@testable import DictamacCore

/// Test-only stub implementation of ``VoiceMemosResolver`` for the MCP
/// `tools/call` tests. Returns canned metadata or throws a caller-
/// supplied error so tests can drive the success and failure paths for
/// `transcribe_voice_memo` and `list_voice_memos` without standing up a
/// real Voice Memos library.
///
/// Kept independent from
/// `Tests/DictamacCLITests/Mocks/MockVoiceMemosResolver.swift` so the
/// MCP test target doesn't pull in the CLI test target — duplicating
/// the shape is cheap and keeps the targets isolated.
///
/// Modelled as a final class with `@unchecked Sendable` so callers can
/// inspect captured arguments synchronously inside the test body — the
/// actor variant would require awaits inside `@Sendable` closures and
/// complicate the handler-recording shape.
final class MockVoiceMemosResolver: VoiceMemosResolver, @unchecked Sendable {
    private let lock = NSLock()
    private var _listings: [VoiceMemoMetadata]
    private var _resolveError: (any Error)?
    private var _listError: (any Error)?
    private var _resolveResult: VoiceMemoMetadata?
    private var _receivedResolveQueries: [VoiceMemoQuery] = []
    private var _receivedListSince: [Date] = []
    private var _receivedListLimit: [Int] = []

    init(
        listings: [VoiceMemoMetadata] = [],
        resolveResult: VoiceMemoMetadata? = nil,
        resolveError: (any Error)? = nil,
        listError: (any Error)? = nil
    ) {
        self._listings = listings
        self._resolveResult = resolveResult
        self._resolveError = resolveError
        self._listError = listError
    }

    var receivedResolveQueries: [VoiceMemoQuery] {
        lock.lock(); defer { lock.unlock() }
        return _receivedResolveQueries
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
        lock.lock()
        _receivedResolveQueries.append(query)
        let error = _resolveError
        let result = _resolveResult ?? _listings.first
        lock.unlock()
        if let error {
            throw error
        }
        guard let result else {
            throw DictamacError.voiceMemoNotFound(query: "<mock>")
        }
        return result
    }

    func list(since: Date, limit: Int) throws -> [VoiceMemoMetadata] {
        lock.lock()
        _receivedListSince.append(since)
        _receivedListLimit.append(limit)
        let error = _listError
        let listings = _listings
        lock.unlock()
        if let error {
            throw error
        }
        return Array(listings.prefix(limit))
    }
}

/// Convenience builder for a minimal ``VoiceMemoMetadata`` used by MCP
/// tools/call tests. Keeps call sites readable — most tests only care
/// that the metadata flowed through, not its content.
enum VoiceMemoMetadataFixture {
    static func canned(
        identifier: String = "mock-id-1",
        title: String = "Mock Memo",
        recordedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        durationSeconds: TimeInterval = 12.5,
        assetPath: URL = URL(fileURLWithPath: "/mock/voice-memo.m4a")
    ) -> VoiceMemoMetadata {
        VoiceMemoMetadata(
            identifier: identifier,
            title: title,
            recordedAt: recordedAt,
            durationSeconds: durationSeconds,
            assetPath: assetPath
        )
    }
}
