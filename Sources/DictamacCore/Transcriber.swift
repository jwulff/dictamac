import Foundation

/// The single seam the CLI and MCP transports depend on. Concrete
/// implementations (the macOS 26 ``SpeechAnalyzer``-backed transcriber,
/// or test-only mocks) plug in behind this protocol.
///
/// `Sendable` so the protocol can cross task boundaries safely;
/// implementations may be actors or value types as needed.
public protocol Transcriber: Sendable {
    func transcribe(_ request: TranscriptionRequest) async throws -> Transcript
}
