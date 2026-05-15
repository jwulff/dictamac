import Foundation

/// A timed slice of recognized speech.
///
/// Encoding semantics (per PLAN.md §6): when ``confidence`` is `nil`, the
/// `confidence` JSON key is omitted from the segment object entirely
/// — it is *not* encoded as `null`. Consumers should treat the absent key
/// as "confidence unknown".
public struct TranscriptSegment: Sendable, Equatable, Codable {
    public let startSeconds: Double
    public let endSeconds: Double
    public let text: String
    public let confidence: Double?

    public init(
        startSeconds: Double,
        endSeconds: Double,
        text: String,
        confidence: Double? = nil
    ) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
        self.confidence = confidence
    }

    private enum CodingKeys: String, CodingKey {
        case startSeconds, endSeconds, text, confidence
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(startSeconds, forKey: .startSeconds)
        try container.encode(endSeconds, forKey: .endSeconds)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(confidence, forKey: .confidence)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.startSeconds = try container.decode(Double.self, forKey: .startSeconds)
        self.endSeconds = try container.decode(Double.self, forKey: .endSeconds)
        self.text = try container.decode(String.self, forKey: .text)
        self.confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
    }
}

/// Descriptor for what produced a ``Transcript`` — recorded in the JSON
/// output as a tagged object so MCP consumers can distinguish a raw file
/// input from a Voice Memos lookup.
///
/// Encoded shapes (PLAN.md §6):
/// - `.file`     → `{"type": "file", "path": "..."}`
/// - `.voiceMemo` → `{"type": "voice-memo", "identifier": "...", "title": "..."}`
public enum TranscriptSource: Sendable, Equatable, Codable {
    case file(path: String)
    case voiceMemo(identifier: String, title: String)

    private enum Discriminator: String, Codable {
        case file
        case voiceMemo = "voice-memo"
    }

    private enum CodingKeys: String, CodingKey {
        case type, path, identifier, title
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .file(let path):
            try container.encode(Discriminator.file, forKey: .type)
            try container.encode(path, forKey: .path)
        case .voiceMemo(let identifier, let title):
            try container.encode(Discriminator.voiceMemo, forKey: .type)
            try container.encode(identifier, forKey: .identifier)
            try container.encode(title, forKey: .title)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let discriminator = try container.decode(Discriminator.self, forKey: .type)
        switch discriminator {
        case .file:
            let path = try container.decode(String.self, forKey: .path)
            self = .file(path: path)
        case .voiceMemo:
            let identifier = try container.decode(String.self, forKey: .identifier)
            let title = try container.decode(String.self, forKey: .title)
            self = .voiceMemo(identifier: identifier, title: title)
        }
    }
}

/// A completed transcription result, ready to hand to a formatter.
///
/// Encoding matches the v1 schema in PLAN.md §6: the `version` field is
/// always written as the string `"1"`, and ``fullText`` is computed from
/// ``segments`` using the same normalization that ``PlaintextFormatter``
/// applies (trim, drop whitespace-only, collapse internal whitespace, join
/// with a single ASCII space) — minus the trailing newline, which the
/// plaintext CLI surface adds.
public struct Transcript: Sendable, Equatable, Codable {
    /// JSON schema version stamped into the encoded transcript. Bump only
    /// on incompatible changes to the §6 schema.
    public static let version = "1"

    public let segments: [TranscriptSegment]
    public let locale: String
    public let durationSeconds: Double
    public let model: String
    public let source: TranscriptSource

    public init(
        segments: [TranscriptSegment],
        locale: String,
        durationSeconds: Double,
        model: String,
        source: TranscriptSource
    ) {
        self.segments = segments
        self.locale = locale
        self.durationSeconds = durationSeconds
        self.model = model
        self.source = source
    }

    /// Normalized full-text form of the transcript: per-segment trim, drop
    /// whitespace-only segments, collapse internal whitespace runs to one
    /// ASCII space, join with one ASCII space. No trailing newline.
    public var fullText: String {
        segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map(Self.collapseWhitespace)
            .joined(separator: " ")
    }

    private static func collapseWhitespace(_ string: String) -> String {
        var output = ""
        output.reserveCapacity(string.count)
        var lastWasSpace = false
        for scalar in string.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !lastWasSpace {
                    output.append(" ")
                    lastWasSpace = true
                }
            } else {
                output.unicodeScalars.append(scalar)
                lastWasSpace = false
            }
        }
        return output
    }

    private enum CodingKeys: String, CodingKey {
        case version, segments, locale, durationSeconds, model, source, fullText
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.version, forKey: .version)
        try container.encode(locale, forKey: .locale)
        try container.encode(durationSeconds, forKey: .durationSeconds)
        try container.encode(model, forKey: .model)
        try container.encode(source, forKey: .source)
        try container.encode(segments, forKey: .segments)
        try container.encode(fullText, forKey: .fullText)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.segments = try container.decode([TranscriptSegment].self, forKey: .segments)
        self.locale = try container.decode(String.self, forKey: .locale)
        self.durationSeconds = try container.decode(Double.self, forKey: .durationSeconds)
        self.model = try container.decode(String.self, forKey: .model)
        self.source = try container.decode(TranscriptSource.self, forKey: .source)
    }
}
