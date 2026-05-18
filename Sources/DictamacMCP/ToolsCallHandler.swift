import Foundation
import DictamacCore
import DictamacVoiceMemos

/// MCP `tools/call` handler.
///
/// Routes incoming `tools/call` requests by `params.name` to one of the
/// three documented tools (`transcribe_file`, `transcribe_voice_memo`,
/// `list_voice_memos`). The handler itself is the only JSON-RPC method
/// behind the curtain — tool-level failures NEVER bubble up as JSON-RPC
/// `error` envelopes; they ride the MCP `isError: true` content shape
/// instead (PLAN.md §5).
///
/// ## Boundary between JSON-RPC errors and tool errors
///
/// - Malformed `tools/call` invocations — missing `name`, wrong shape of
///   `arguments`, missing required tool arguments — raise
///   ``MCPProtocolError/invalidParams(_:)`` which the dispatch surface
///   maps to JSON-RPC `-32602`.
/// - Unknown tool name -> tool-level error envelope (`isError: true`).
///   The MCP spec reserves JSON-RPC `-32601` for unknown JSON-RPC
///   *methods* — `tools/call` itself is registered; the per-tool
///   dispatch is application-level.
/// - Every ``DictamacError`` raised by the underlying core — file not
///   found, decode failed, permission denied, etc. — becomes an
///   `isError: true` envelope whose text matches the CLI's stderr
///   message verbatim (parity via ``DictamacError/description``).
///
/// ## Dependency injection
///
/// The handler accepts a ``Transcriber`` and an ``AudioFileResolver`` so
/// the same dispatch path can be exercised from tests with mocks.
/// `ProductionMCPHandlers.register(on:)` wires the production
/// implementations (``DefaultTranscriber`` /
/// ``DefaultAudioFileResolver``) without changing the call sites.
public struct MCPToolsCallHandler: Sendable {

    // MARK: - Dependencies

    private let transcriber: any Transcriber
    private let audioResolver: any AudioFileResolver
    private let voiceMemosResolver: any VoiceMemosResolver

    /// Construct a handler bound to a specific ``Transcriber``,
    /// ``AudioFileResolver``, and ``VoiceMemosResolver``. Tests inject
    /// mocks; production wires the `Default*` implementations through
    /// ``ProductionMCPHandlers/register(on:transcriber:audioResolver:voiceMemosResolver:)``.
    public init(
        transcriber: any Transcriber,
        audioResolver: any AudioFileResolver,
        voiceMemosResolver: any VoiceMemosResolver
    ) {
        self.transcriber = transcriber
        self.audioResolver = audioResolver
        self.voiceMemosResolver = voiceMemosResolver
    }

    // MARK: - Entry point

    /// Dispatch a `tools/call` request.
    ///
    /// Expected `params` shape (per MCP spec):
    ///
    /// ```json
    /// {
    ///   "name": "<tool-name>",
    ///   "arguments": { ...tool-specific... }
    /// }
    /// ```
    ///
    /// On a malformed envelope, throws
    /// ``MCPProtocolError/invalidParams(_:)``. On a known tool, returns
    /// the tool's result envelope (success or `isError: true`).
    public func handle(params: JSONValue?) async throws -> JSONValue {
        let toolName = try Self.extractToolName(from: params)
        let arguments = try Self.extractArguments(from: params)

        switch toolName {
        case "transcribe_file":
            return try await handleTranscribeFile(arguments: arguments)
        case "transcribe_voice_memo":
            return try await handleTranscribeVoiceMemo(arguments: arguments)
        case "list_voice_memos":
            return try await handleListVoiceMemos(arguments: arguments)
        default:
            // Unknown tool name -> tool-level error envelope, NOT
            // JSON-RPC -32601. -32601 is reserved for unknown JSON-RPC
            // methods, not unknown tool names.
            return Self.toolErrorEnvelope(
                "Unknown tool: \(toolName). "
                + "Call tools/list for the list of supported tools."
            )
        }
    }

    // MARK: - transcribe_file

    /// `transcribe_file({path, locale?, format?})`. Validates the
    /// supplied path, hands it through the shared
    /// ``AudioFileResolver`` + ``Transcriber``, and renders the result
    /// into the MCP single-text-content envelope (PLAN.md §5).
    private func handleTranscribeFile(arguments: [String: JSONValue]) async throws -> JSONValue {
        // Validate required `path`. Missing / wrong type / non-absolute
        // -> JSON-RPC -32602 (malformed invocation).
        guard let pathValue = arguments["path"] else {
            throw MCPProtocolError.invalidParams(
                "transcribe_file requires a 'path' argument."
            )
        }
        guard case .string(let path) = pathValue else {
            throw MCPProtocolError.invalidParams(
                "transcribe_file 'path' must be a string."
            )
        }
        guard path.hasPrefix("/") else {
            throw MCPProtocolError.invalidParams(
                "transcribe_file 'path' must be an absolute path; got \(path)."
            )
        }

        let format = try Self.extractFormat(from: arguments)
        let localeIdentifier = try Self.extractLocale(from: arguments)
            ?? "en-US"

        // From here on, any DictamacError becomes a tool-level error
        // envelope — never a JSON-RPC error — so the agent sees a
        // structured failure message it can react to.
        do {
            let resolved = try await audioResolver.resolve(source: .path(path))
            defer { resolved.cleanup() }

            let request = TranscriptionRequest(
                source: .file(resolved.url),
                locale: Locale(identifier: localeIdentifier),
                format: format
            )

            let transcript = try await transcriber.transcribe(request)
            let rendered = Self.render(transcript: transcript, format: format)
            return Self.toolSuccessEnvelope(text: rendered)
        } catch let error as DictamacError {
            return Self.toolErrorEnvelope(error.mcpToolErrorText)
        } catch {
            // Anything that escapes ``DictamacError`` classification
            // still becomes a tool-level error envelope, wrapped in the
            // generic internal-failure mapping so behaviour parity
            // with the CLI's catch-all path holds.
            return Self.toolErrorEnvelope(
                DictamacError.internalFailure(error).mcpToolErrorText
            )
        }
    }

    // MARK: - transcribe_voice_memo

    /// `transcribe_voice_memo({query, locale?, format?})` — resolves
    /// the query via the shared ``VoiceMemosResolver``, then runs the
    /// same `transcribe_file`-style pipeline against the resolved memo's
    /// asset path. Result envelope shape and parity-with-CLI rules are
    /// identical to ``handleTranscribeFile(arguments:)`` (PLAN.md §5).
    private func handleTranscribeVoiceMemo(arguments: [String: JSONValue]) async throws -> JSONValue {
        guard let queryValue = arguments["query"] else {
            throw MCPProtocolError.invalidParams(
                "transcribe_voice_memo requires a 'query' argument."
            )
        }
        guard case .string(let query) = queryValue else {
            throw MCPProtocolError.invalidParams(
                "transcribe_voice_memo 'query' must be a string."
            )
        }
        // Trim before the emptiness check. `VoiceMemoQuery.parse(_:)`
        // also trims, so without this guard a whitespace-only query
        // like "   " would slip past `!query.isEmpty`, parse to
        // `.fuzzyTitle("")`, and surface as a useless `voiceMemoNotFound`
        // envelope instead of the intended `-32602` protocol error.
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            throw MCPProtocolError.invalidParams(
                "transcribe_voice_memo 'query' must be a non-empty string."
            )
        }

        let format = try Self.extractFormat(from: arguments)
        let localeIdentifier = try Self.extractLocale(from: arguments)
            ?? "en-US"

        // From here on, any DictamacError becomes a tool-level error
        // envelope — never a JSON-RPC error — so the agent sees a
        // structured failure message identical to the CLI's stderr line.
        do {
            // 1. Resolve the query to a specific memo. The resolver
            // produces ``DictamacError/voiceMemoNotFound``,
            // ``DictamacError/voiceMemoLibraryMissing``, or
            // ``DictamacError/permissionDenied`` — all of which fall
            // out as `isError: true` envelopes below.
            let parsedQuery = VoiceMemoQuery.parse(trimmedQuery)
            let memo = try voiceMemosResolver.resolve(
                parsedQuery,
                now: Date()
            )

            // 2. Hand the memo's asset path through the same audio
            // resolver `transcribe_file` uses. This keeps the codec /
            // decode validation (exit 65 in the CLI; the equivalent
            // error envelope here) in one place.
            let resolved = try await audioResolver.resolve(
                source: .path(memo.assetPath.path)
            )
            defer { resolved.cleanup() }

            // The request carries the `.voiceMemo` source variant — not
            // `.file` — so the emitted transcript stamps the memo's
            // identifier + title into ``Transcript.source`` instead of
            // the opaque asset URL inside the Voice Memos library.
            // Without this, `format: "json"` would surface
            // `source.type == "file"` with the asset path, making a
            // voice-memo lookup indistinguishable from a raw file
            // transcription (PR #57 review). The CLI handler mirrors
            // this exactly so the two transports stay byte-aligned.
            let request = TranscriptionRequest(
                source: .voiceMemo(
                    identifier: memo.identifier,
                    title: memo.title,
                    url: resolved.url
                ),
                locale: Locale(identifier: localeIdentifier),
                format: format
            )

            let transcript = try await transcriber.transcribe(request)
            let rendered = Self.render(transcript: transcript, format: format)
            return Self.toolSuccessEnvelope(text: rendered)
        } catch let error as DictamacError {
            return Self.toolErrorEnvelope(error.mcpToolErrorText)
        } catch {
            return Self.toolErrorEnvelope(
                DictamacError.internalFailure(error).mcpToolErrorText
            )
        }
    }

    // MARK: - list_voice_memos

    /// `list_voice_memos({since?, limit?})` — queries the shared
    /// ``VoiceMemosResolver`` with defaults `since: "30d"`, `limit: 30`,
    /// returning a single `text` content item containing a JSON array
    /// of ``VoiceMemoListing`` (PLAN.md §5).
    private func handleListVoiceMemos(arguments: [String: JSONValue]) async throws -> JSONValue {
        // 1. Validate argument types up-front. Wrong shape -> -32602.
        // String parsing (`since`) happens after the type guard so an
        // unrecognized duration also surfaces as -32602 — same boundary
        // as the CLI's `--since` flag, which exits 2 (argument error).
        let sinceArgument: String?
        if let sinceValue = arguments["since"] {
            guard case .string(let raw) = sinceValue else {
                throw MCPProtocolError.invalidParams(
                    "list_voice_memos 'since' must be a string when present."
                )
            }
            sinceArgument = raw
        } else {
            sinceArgument = nil
        }

        let limitArgument: Int?
        if let limitValue = arguments["limit"] {
            guard case .int(let raw) = limitValue else {
                throw MCPProtocolError.invalidParams(
                    "list_voice_memos 'limit' must be an integer when present."
                )
            }
            limitArgument = raw
        } else {
            limitArgument = nil
        }

        // 2. Parse `since` (default 30d). Bad duration string ->
        // -32602 to mirror "malformed argument" semantics on the wire.
        let now = Date()
        let sinceDate: Date
        do {
            let parsed = try DurationString(sinceArgument ?? "30d")
            sinceDate = parsed.date(relativeTo: now)
        } catch let error as DurationStringError {
            throw MCPProtocolError.invalidParams(
                "list_voice_memos 'since': \(error.description)"
            )
        } catch {
            throw MCPProtocolError.invalidParams(
                "list_voice_memos 'since': \(error.localizedDescription)"
            )
        }

        // 3. Clamp limit to [1, 100]; default 30. Same contract as the
        // CLI's `--list-voice-memos --limit` flag.
        let clampedLimit = Self.clamp(
            limitArgument ?? 30,
            minimum: 1,
            maximum: 100
        )

        // 4. Call the resolver. Any DictamacError -> isError envelope.
        do {
            let memos = try voiceMemosResolver.list(
                since: sinceDate,
                limit: clampedLimit
            )

            // 5. Defensive reverse-chronological sort. The resolver is
            // documented to return reverse-chrono, but we don't trust
            // silent contract drift to make it past the MCP surface.
            let sorted = memos.sorted { $0.recordedAt > $1.recordedAt }

            // 6. Encode the projection. ``VoiceMemoListing`` is the
            // shared wire shape — keeps the CLI's `--list-voice-memos
            // --json` output and this MCP tool aligned via one type.
            let listings = sorted.map(VoiceMemoListing.init(from:))
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(listings)
            let body = String(data: data, encoding: .utf8) ?? "[]"
            // Trailing newline matches the CLI's `--list-voice-memos
            // --json` output (see `renderJSON` in
            // `ListVoiceMemosHandler.swift`). The other tool envelopes
            // already end with `\n` because `PlaintextFormatter` /
            // `JSONFormatter` produce one; mirroring that here keeps
            // transport parity byte-for-byte.
            return Self.toolSuccessEnvelope(text: body + "\n")
        } catch let error as DictamacError {
            return Self.toolErrorEnvelope(error.mcpToolErrorText)
        } catch {
            return Self.toolErrorEnvelope(
                DictamacError.internalFailure(error).mcpToolErrorText
            )
        }
    }

    /// Clamps `value` into `[minimum, maximum]`. Local helper rather
    /// than an `Int` extension — matches the CLI's
    /// ``runListVoiceMemos(since:limit:resolver:now:wantsJSON:writeStdout:writeStderr:exit:)``
    /// implementation so behaviour stays in lockstep.
    private static func clamp(_ value: Int, minimum: Int, maximum: Int) -> Int {
        if value < minimum { return minimum }
        if value > maximum { return maximum }
        return value
    }

    // MARK: - Param extraction helpers

    private static func extractToolName(from params: JSONValue?) throws -> String {
        guard let params else {
            throw MCPProtocolError.invalidParams(
                "tools/call requires a params object with a 'name' field."
            )
        }
        guard case .object(let object) = params else {
            throw MCPProtocolError.invalidParams(
                "tools/call params must be a JSON object."
            )
        }
        guard let nameValue = object["name"] else {
            throw MCPProtocolError.invalidParams(
                "tools/call params missing required 'name' field."
            )
        }
        guard case .string(let name) = nameValue, !name.isEmpty else {
            throw MCPProtocolError.invalidParams(
                "tools/call 'name' must be a non-empty string."
            )
        }
        return name
    }

    /// `arguments` is optional in the MCP spec — a tool may take no
    /// arguments. When absent we return an empty dictionary so per-tool
    /// handlers can index it without an extra guard. When present but
    /// the wrong shape (array, string, number, etc.) we raise `-32602`
    /// at the protocol layer rather than silently treating it as
    /// missing — a malformed `arguments` is a protocol-shape violation,
    /// not a failed tool execution.
    private static func extractArguments(from params: JSONValue?) throws -> [String: JSONValue] {
        guard case .object(let object) = params else {
            return [:]
        }
        guard let argumentsValue = object["arguments"] else {
            return [:]
        }
        guard case .object(let arguments) = argumentsValue else {
            throw MCPProtocolError.invalidParams(
                "tools/call 'arguments' must be a JSON object when present."
            )
        }
        return arguments
    }

    /// Parses an optional `format` argument and returns the matching
    /// ``TranscriptionRequest.Format``. Default is `.text`. Anything
    /// other than `"text"` or `"json"` -> -32602.
    private static func extractFormat(
        from arguments: [String: JSONValue]
    ) throws -> TranscriptionRequest.Format {
        guard let formatValue = arguments["format"] else {
            return .text
        }
        guard case .string(let formatString) = formatValue else {
            throw MCPProtocolError.invalidParams(
                "'format' must be a string when present (got non-string)."
            )
        }
        guard let format = TranscriptionRequest.Format(rawValue: formatString) else {
            throw MCPProtocolError.invalidParams(
                "'format' must be 'text' or 'json'; got '\(formatString)'."
            )
        }
        return format
    }

    /// Parses an optional `locale` argument and returns its identifier.
    /// Missing -> nil (caller picks the default). Non-string -> -32602.
    private static func extractLocale(
        from arguments: [String: JSONValue]
    ) throws -> String? {
        guard let localeValue = arguments["locale"] else {
            return nil
        }
        guard case .string(let identifier) = localeValue, !identifier.isEmpty else {
            throw MCPProtocolError.invalidParams(
                "'locale' must be a non-empty BCP-47 string when present."
            )
        }
        return identifier
    }

    // MARK: - Result envelopes

    /// Render a successful transcript into the single-text-content
    /// envelope MCP expects (PLAN.md §5).
    ///
    /// `format == .text` -> plaintext via ``PlaintextFormatter``;
    /// `format == .json` -> JSON-stringified transcript via
    /// ``JSONFormatter``. Both formatters already produce a trailing
    /// newline; we hand that through unchanged so the MCP content text
    /// matches the CLI stdout byte-for-byte.
    private static func render(
        transcript: Transcript,
        format: TranscriptionRequest.Format
    ) -> String {
        switch format {
        case .text:
            return PlaintextFormatter.format(transcript)
        case .json:
            return JSONFormatter.format(transcript)
        }
    }

    /// Build a tool-call success envelope with a single `text` content
    /// item carrying `text`. Per PLAN.md §5, the `isError` key is
    /// omitted on success — its absence is the success signal.
    public static func toolSuccessEnvelope(text: String) -> JSONValue {
        .object([
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(text),
                ]),
            ]),
        ])
    }

    /// Build a tool-call error envelope. Always uses a single `text`
    /// content item — agents key off the message text and we don't
    /// want to fragment that into multiple items per failure.
    ///
    /// Public so the CLI / MCP parity tests can call it directly when
    /// asserting `DictamacError` -> envelope mapping.
    public static func toolErrorEnvelope(_ message: String) -> JSONValue {
        .object([
            "isError": .bool(true),
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(message),
                ]),
            ]),
        ])
    }

}

// MARK: - DictamacError -> tool-error text (parity seam)

extension DictamacError {
    /// The exact text the MCP `tools/call` `isError` envelope carries
    /// for this error.
    ///
    /// Behaviour parity with the CLI is a hard requirement: the CLI
    /// writes ``formattedStderrLine`` (description + `"\n"`) to stderr,
    /// and the MCP transport puts ``description`` (no trailing newline)
    /// into the `text` content item. ``formattedStderrLine`` minus the
    /// trailing newline is exactly ``description`` — so the two
    /// transports stay in lockstep as long as both consult this seam.
    ///
    /// Exposed as a property rather than a free function so the parity
    /// tests can iterate over enumerated cases and assert symmetry.
    public var mcpToolErrorText: String {
        description
    }
}
