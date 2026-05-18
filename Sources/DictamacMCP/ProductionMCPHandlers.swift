import Foundation
import DictamacCore
import DictamacVoiceMemos

/// Production MCP method handlers.
///
/// This enum is the single seam where `dictamac --mcp` wires every
/// JSON-RPC method into ``MCPServer``. ``register(on:)`` is what the CLI
/// calls; the individual `initialize` / `toolsList` entry points are
/// exposed for unit tests that need to exercise a handler without
/// standing up a server.
///
/// `tools/call` (#26) is registered via the overload that accepts a
/// ``Transcriber`` + ``AudioFileResolver`` so the underlying core
/// dependencies stay injectable.
public enum ProductionMCPHandlers {

    // MARK: - Registration

    /// Register `initialize` + `tools/list` on the given ``MCPServer``.
    /// Idempotent: registering twice replaces the previous handlers
    /// (the actor enforces single-writer semantics).
    ///
    /// `tools/call` is intentionally NOT registered by this overload —
    /// it requires production dependencies (``Transcriber`` /
    /// ``AudioFileResolver``) that the MCP target doesn't own. The CLI
    /// uses ``register(on:transcriber:audioResolver:)`` to wire all
    /// three handlers in one pass; existing handshake-only tests keep
    /// using this overload.
    public static func register(on server: MCPServer) async {
        await server.register(method: "initialize") { params in
            try await Self.initialize(params: params)
        }
        await server.register(method: "tools/list") { params in
            try await Self.toolsList(params: params)
        }
    }

    /// Register every production handler — including `tools/call` —
    /// on the given ``MCPServer``. The `tools/call` handler is bound to
    /// the supplied ``Transcriber``, ``AudioFileResolver``, and
    /// ``VoiceMemosResolver`` so the same dispatch path can be
    /// exercised end-to-end from tests.
    public static func register(
        on server: MCPServer,
        transcriber: any Transcriber,
        audioResolver: any AudioFileResolver,
        voiceMemosResolver: any VoiceMemosResolver
    ) async {
        await register(on: server)
        let toolsCall = MCPToolsCallHandler(
            transcriber: transcriber,
            audioResolver: audioResolver,
            voiceMemosResolver: voiceMemosResolver
        )
        await server.register(method: "tools/call") { params in
            try await toolsCall.handle(params: params)
        }
    }

    // MARK: - initialize

    /// MCP `initialize` handler.
    ///
    /// Returns the server's pinned protocol version, the `tools`-only
    /// capability set, and the canonical server identity. The client's
    /// `params` (which may carry the client's own protocolVersion and
    /// capabilities) is intentionally ignored today — we don't
    /// negotiate. If a future issue introduces negotiation, this is the
    /// seam to update; the tests already verify "ignores incoming
    /// params" so a regression would surface.
    public static func initialize(params: JSONValue?) async throws -> JSONValue {
        _ = params  // explicitly unused — see doc comment
        return .object([
            "protocolVersion": .string(mcpProtocolVersion),
            "capabilities": .object([
                "tools": .object([:]),
            ]),
            "serverInfo": .object([
                "name": .string(MCPServerIdentity.dictamac.name),
                "version": .string(MCPServerIdentity.dictamac.version),
                "vendor": .string(MCPServerIdentity.dictamac.vendor),
            ]),
        ])
    }

    // MARK: - tools/list

    /// MCP `tools/list` handler.
    ///
    /// Returns the three transcription tool schemas documented in
    /// `docs/PLAN.md` §5: `transcribe_file`, `transcribe_voice_memo`,
    /// and `list_voice_memos`. The order matches the documented order
    /// so the snapshot test's array equality stays stable.
    ///
    /// Drift between this function and the spec is the kind of bug
    /// that silently breaks downstream agents — the snapshot test in
    /// `ToolsListHandlerTests` is the drift guard.
    public static func toolsList(params: JSONValue?) async throws -> JSONValue {
        _ = params  // tools/list takes no params; ignore client input
        return .object([
            "tools": .array([
                transcribeFileToolSchema,
                transcribeVoiceMemoToolSchema,
                listVoiceMemosToolSchema,
            ]),
        ])
    }

    // MARK: - Tool schemas

    /// JSON Schema for `transcribe_file`. Mirrors PLAN.md §5 exactly —
    /// edit both this constant AND the snapshot when the spec changes.
    private static let transcribeFileToolSchema: JSONValue = .object([
        "name": .string("transcribe_file"),
        "description": .string(
            "Transcribe an audio file via Apple's on-device SpeechAnalyzer. "
            + "Returns plaintext by default, or a structured transcript "
            + "with timestamps when format=\"json\"."
        ),
        "inputSchema": .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Absolute path to the audio file."),
                ]),
                "locale": .object([
                    "type": .string("string"),
                    "description": .string(
                        "BCP-47 locale (e.g. en-US). Defaults to system locale."
                    ),
                ]),
                "format": .object([
                    "type": .string("string"),
                    "enum": .array([.string("text"), .string("json")]),
                    "default": .string("text"),
                ]),
            ]),
            "required": .array([.string("path")]),
        ]),
    ])

    /// JSON Schema for `transcribe_voice_memo`. Mirrors PLAN.md §5.
    private static let transcribeVoiceMemoToolSchema: JSONValue = .object([
        "name": .string("transcribe_voice_memo"),
        "description": .string(
            "Find a Voice Memo by title or date and transcribe it. "
            + "The Voice Memos app does not always auto-transcribe; "
            + "this tool transcribes on demand."
        ),
        "inputSchema": .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Substring match against Voice Memo titles, or time "
                        + "anchor (today, yesterday, this morning), or ISO "
                        + "date (YYYY-MM-DD), or an identifier from "
                        + "list_voice_memos."
                    ),
                ]),
                "locale": .object([
                    "type": .string("string"),
                ]),
                "format": .object([
                    "type": .string("string"),
                    "enum": .array([.string("text"), .string("json")]),
                    "default": .string("text"),
                ]),
            ]),
            "required": .array([.string("query")]),
        ]),
    ])

    /// JSON Schema for `list_voice_memos`. Mirrors PLAN.md §5. Note no
    /// `required` field — both `since` and `limit` are optional.
    private static let listVoiceMemosToolSchema: JSONValue = .object([
        "name": .string("list_voice_memos"),
        "description": .string(
            "List Voice Memos in reverse chronological order with their "
            + "titles, recording dates, and durations."
        ),
        "inputSchema": .object([
            "type": .string("object"),
            "properties": .object([
                "since": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Duration string (7d, 2w, 1m) or ISO date. Default: 30d."
                    ),
                ]),
                "limit": .object([
                    "type": .string("integer"),
                    "minimum": .int(1),
                    "maximum": .int(100),
                    "default": .int(30),
                ]),
            ]),
        ]),
    ])
}
