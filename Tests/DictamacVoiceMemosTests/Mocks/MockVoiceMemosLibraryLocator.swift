import Foundation
import DictamacCore
@testable import DictamacVoiceMemos

/// Test-only ``VoiceMemosLibraryLocator`` that returns a canned
/// ``VoiceMemosLibraryLocation`` or throws a canned ``DictamacError``.
///
/// Modelled as a final class with immutable storage so it satisfies
/// the protocol's `Sendable` requirement without `@unchecked`.
final class MockVoiceMemosLibraryLocator: VoiceMemosLibraryLocator, Sendable {
    private let result: Result<VoiceMemosLibraryLocation, DictamacError>

    init(location: VoiceMemosLibraryLocation) {
        self.result = .success(location)
    }

    init(error: DictamacError) {
        self.result = .failure(error)
    }

    func locate() throws -> VoiceMemosLibraryLocation {
        switch result {
        case .success(let location):
            return location
        case .failure(let error):
            throw error
        }
    }
}
