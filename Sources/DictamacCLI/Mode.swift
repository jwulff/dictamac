import Foundation

/// One of the five top-level CLI modes resolved from argv after
/// validation. Each case carries the data the corresponding handler
/// needs to run; everything else has already been validated away by
/// the time a `Mode` value exists.
///
/// The dispatcher in `ModeDispatch.swift` consumes this enum, so
/// adding a new mode means adding a case here, a handler closure on
/// `ModeHandlers`, and a switch arm in `dispatch(mode:handlers:)`.
public enum Mode: Equatable, Sendable {
    /// Transcribe the file at the given (un-expanded) path argument.
    case file(path: String)

    /// Drain audio from stdin and transcribe it. Stub-only in this
    /// PR — the real pipeline ships under #27.
    case stdin

    /// Resolve a Voice Memo by query and transcribe it. Stub-only
    /// here — the real implementation lives in epic #4.
    case voiceMemo(query: String)

    /// List Voice Memos. Stub-only here — epic #4 lands the real
    /// behavior plus `--since` / `--limit` plumbing.
    ///
    /// The payload carries the validated `--since` / `--limit` values
    /// so the dispatch seam can hand them to the real handler when
    /// epic #4 lands. Both are optional because either flag may be
    /// omitted on the command line; the parser has already enforced
    /// that they are only set when `--list-voice-memos` is also set.
    case listVoiceMemos(since: String?, limit: Int?)

    /// Run the MCP JSON-RPC stdio server. Stub-only here — epic #5
    /// owns the real implementation.
    case mcp
}
