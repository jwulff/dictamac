import Foundation
@testable import DictamacCore

/// Test-only stub implementation of ``AudioFileResolver`` for the MCP
/// tools/call tests. Records each incoming source and either returns a
/// canned ``ResolvedAudio`` (with a cleanup hook the caller can verify
/// ran) or throws a caller-supplied error so tests can drive the error
/// paths without staging real audio.
///
/// Modelled as an actor so it satisfies the protocol's ``Sendable``
/// requirement without needing `@unchecked`.
actor MockAudioFileResolver: AudioFileResolver {
    /// URL the resolver returns on success. Defaults to a fictional
    /// path under the temp dir — tests that care can override.
    let resolvedURL: URL
    let errorToThrow: (any Error)?
    private(set) var receivedSources: [AudioSource] = []
    private(set) var cleanupCallCount = 0

    init(
        resolvedURL: URL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dictamac-mock-resolved.m4a"),
        errorToThrow: (any Error)? = nil
    ) {
        self.resolvedURL = resolvedURL
        self.errorToThrow = errorToThrow
    }

    func resolve(source: AudioSource) async throws -> ResolvedAudio {
        receivedSources.append(source)
        if let errorToThrow {
            throw errorToThrow
        }
        // The cleanup closure is `@Sendable` and non-async; it can't
        // await the actor directly. Hop through a detached `Task` so
        // the cleanup count update lands on the actor.
        let counter = self
        return ResolvedAudio(url: resolvedURL, cleanup: {
            Task { await counter.recordCleanup() }
        })
    }

    func recordCleanup() {
        cleanupCallCount += 1
    }
}
