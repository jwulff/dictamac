import Foundation

/// Renders a ``Transcript`` as plaintext for the CLI's stdout surface.
///
/// The output is exactly ``Transcript/fullText`` followed by one ASCII
/// newline — including for empty transcripts, where the output is a bare
/// `"\n"` (PLAN.md §6 zero-segment note). Per-segment normalization
/// (trim, drop whitespace-only, collapse internal whitespace, join with a
/// single ASCII space) is performed by `Transcript.fullText`, so the CLI
/// plaintext and the MCP JSON `fullText` field stay byte-aligned by
/// construction.
///
/// Stateless and side-effect-free — write directly with ``format(_:)`` or
/// stream into any ``TextOutputStream`` via ``write(_:to:)`` so MCP tool
/// responses can capture the same bytes into a string buffer.
public enum PlaintextFormatter {

    /// Returns the plaintext form of the transcript (always ends with one
    /// trailing `"\n"`).
    public static func format(_ transcript: Transcript) -> String {
        transcript.fullText + "\n"
    }

    /// Writes the plaintext form of the transcript to the given output
    /// stream. Appends to the stream's existing contents; never resets.
    public static func write<Stream: TextOutputStream>(
        _ transcript: Transcript,
        to stream: inout Stream
    ) {
        stream.write(format(transcript))
    }
}
