import Foundation

/// Renders a ``Transcript`` as JSON for the CLI's `--json` output and the
/// MCP transport's `format: "json"` tool responses.
///
/// Output matches the v1 schema in PLAN.md §6 verbatim — `Transcript`'s
/// Codable conformance is the source of truth for that schema, so this
/// type's job is purely encoder configuration: deterministic key order,
/// pretty-printing, one trailing newline.
///
/// Stateless. Use ``format(_:)`` for the convenience string overload or
/// ``write(_:to:)`` to stream into any ``TextOutputStream`` (MCP captures
/// the same bytes into a string buffer for its `text` content items).
public enum JSONFormatter {

    /// Returns the JSON form of the transcript (always ends with one
    /// trailing `"\n"`).
    public static func format(_ transcript: Transcript) -> String {
        let encoder = makeEncoder()
        // `Transcript`'s Codable always succeeds for in-memory values, so
        // a forced try keeps the public API non-throwing. If this ever
        // does throw it indicates a programmer error (e.g. a non-finite
        // Double in `durationSeconds`) and a crash is more honest than a
        // silent empty string.
        let data = try! encoder.encode(transcript)
        return String(data: data, encoding: .utf8)! + "\n"
    }

    /// Writes the JSON form of the transcript to the given output stream.
    /// Appends to the stream's existing contents; never resets.
    public static func write<Stream: TextOutputStream>(
        _ transcript: Transcript,
        to stream: inout Stream
    ) {
        stream.write(format(transcript))
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
