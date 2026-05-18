import Foundation

/// Wire shape for one Voice Memo as returned by the
/// `--list-voice-memos --json` CLI mode and the MCP `list_voice_memos`
/// tool. One type, two transports — defining it here (rather than
/// inside the CLI or MCP target) prevents the two transports from
/// drifting on the field set or key names.
///
/// PLAN.md §5 fixes the schema: `{title, recordedAt, durationSeconds,
/// identifier}`. ``VoiceMemoMetadata`` is the richer internal shape;
/// this listing is the agent-facing projection.
public struct VoiceMemoListing: Codable, Hashable, Sendable {
    public let identifier: String
    public let title: String
    public let recordedAt: Date
    public let durationSeconds: TimeInterval

    public init(
        identifier: String,
        title: String,
        recordedAt: Date,
        durationSeconds: TimeInterval
    ) {
        self.identifier = identifier
        self.title = title
        self.recordedAt = recordedAt
        self.durationSeconds = durationSeconds
    }

    /// Projection from the internal metadata shape. Drops the
    /// asset-path field that the agent surface deliberately hides —
    /// callers transcribe by identifier, not by path.
    public init(from metadata: VoiceMemoMetadata) {
        self.identifier = metadata.identifier
        self.title = metadata.title
        self.recordedAt = metadata.recordedAt
        self.durationSeconds = metadata.durationSeconds
    }
}
