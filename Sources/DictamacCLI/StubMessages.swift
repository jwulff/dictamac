import Foundation

/// Centralized strings for the not-yet-implemented mode handlers and a
/// tiny helper that writes UTF-8 + trailing newline to a caller-
/// supplied `FileHandle`.
///
/// Keeping the messages here (not inline in the handler closures)
/// makes them straightforward to assert against in unit tests and
/// keeps the "epic / issue number we point at" in one place — when
/// epic #4 or #5 lands, the corresponding strings get replaced with
/// real behavior and these constants disappear.
public enum StubMessages {

    /// Voice Memos epic. The query is preserved verbatim so an agent
    /// that just got "not implemented" still sees what it asked for.
    public static func voiceMemoNotImplemented(query: String) -> String {
        "--voice-memo \"\(query)\" not yet implemented — see epic #4."
    }

    /// MCP transport epic.
    public static let mcpNotImplemented =
        "--mcp stdio server not yet implemented — see epic #5."

    /// Writes `message` + `\n` to the given file handle.
    ///
    /// Defaults to `FileHandle.standardError` so the production
    /// callers stay one-liners. Tests inject
    /// `Pipe().fileHandleForWriting` so they can assert what would
    /// have hit the terminal without polluting the test runner's
    /// stderr.
    public static func writeStderrLine(
        _ message: String,
        to handle: FileHandle = .standardError
    ) {
        guard let data = (message + "\n").data(using: .utf8) else { return }
        handle.write(data)
    }
}
