import Foundation

/// Metadata for one Voice Memo, returned by both the CloudRecordings
/// SQLite reader (issue #17) and the filesystem fallback scanner (issue
/// #20). Shape is intentionally minimal — only what the resolver and
/// the `list_voice_memos` MCP tool need.
public struct VoiceMemoMetadata: Sendable, Hashable {
    /// Stable identifier — for SQLite rows, the primary key; for
    /// filesystem entries, the filename stem.
    public let identifier: String

    /// User-visible title. Falls back to the filename stem when neither
    /// CloudRecordings nor xattrs provide a title.
    public let title: String

    /// When the recording started. From CloudRecordings.db when
    /// available; otherwise xattr `kMDItemContentCreationDate`, then
    /// filesystem `creationDate`.
    public let recordedAt: Date

    /// Audio duration in seconds. From CloudRecordings.db when
    /// available; otherwise computed from `AVAudioFile`.
    public let durationSeconds: TimeInterval

    /// Absolute path to the `.m4a` asset on disk.
    public let assetPath: URL

    public init(
        identifier: String,
        title: String,
        recordedAt: Date,
        durationSeconds: TimeInterval,
        assetPath: URL
    ) {
        self.identifier = identifier
        self.title = title
        self.recordedAt = recordedAt
        self.durationSeconds = durationSeconds
        self.assetPath = assetPath
    }
}
