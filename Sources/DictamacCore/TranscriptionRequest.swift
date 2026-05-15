import Foundation

/// Input to a ``Transcriber``: where to read audio from, what locale model
/// to use, and which output format the caller wants back.
public struct TranscriptionRequest: Sendable, Equatable {
    /// Where the audio bytes live on disk at request time.
    ///
    /// `.file` is a user-supplied path; `.stdin` is a temp file the
    /// caller has already drained stdin into. Both are local file URLs
    /// suitable for `AVAudioFile(forReading:)`.
    public enum Source: Sendable, Equatable {
        case file(URL)
        case stdin(URL)
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
