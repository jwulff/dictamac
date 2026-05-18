import Foundation

/// Input to a ``Transcriber``: where to read audio from, what locale model
/// to use, and which output format the caller wants back.
public struct TranscriptionRequest: Sendable, Equatable {
    /// Where the audio bytes live on disk at request time.
    ///
    /// All three variants carry a local file URL suitable for
    /// `AVAudioFile(forReading:)`; the transcriber reads from each URL
    /// identically. The variants differ only in what gets stamped into
    /// the emitted ``Transcript`` (see
    /// ``DefaultTranscriber/transcriptSource(for:audioURL:)``):
    ///
    /// - `.file` is a user-supplied path. The path goes into
    ///   ``TranscriptSource/file(path:)`` verbatim.
    /// - `.stdin` is a temp file the caller has already drained stdin
    ///   into. The temp path MUST NOT leak into the emitted transcript
    ///   — the CLI deletes the file immediately after transcribing —
    ///   so the emitted ``TranscriptSource`` is the payload-less
    ///   ``TranscriptSource/stdin``.
    /// - `.voiceMemo` carries the resolved memo's `identifier`, `title`,
    ///   and asset URL. The emitted ``TranscriptSource`` is
    ///   ``TranscriptSource/voiceMemo(identifier:title:)`` — the asset
    ///   URL is read for transcription but never surfaced, because the
    ///   memo's identifier + title are the user-meaningful reference,
    ///   not the on-disk asset path (which may be an opaque
    ///   `<UUID>.m4a` inside the Voice Memos library).
    ///
    /// The mapping lives in the transcriber so the CLI and MCP
    /// voice-memo handlers don't have to rewrite the transcript's
    /// source after the fact — they construct the right
    /// ``TranscriptionRequest.Source`` and the transcriber preserves
    /// the metadata into the result.
    public enum Source: Sendable, Equatable {
        case file(URL)
        case stdin(URL)
        case voiceMemo(identifier: String, title: String, url: URL)
    }

    /// Output formatter the caller wants the transcript rendered as.
    public enum Format: String, Sendable, Equatable, Codable {
        case text
        case json
    }

    public let source: Source
    public let locale: Locale
    public let format: Format

    public init(source: Source, locale: Locale, format: Format) {
        self.source = source
        self.locale = locale
        self.format = format
    }
}
