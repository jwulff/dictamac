# Add MCP tools/call dispatcher with transcribe_file wired

PR: #52
Issues: Closes #26 (Refs #5)

## What changed

Two new files in `Sources/DictamacMCP/` and one in
`Tests/DictamacMCPTests/` add the `tools/call` dispatcher that turns
`dictamac --mcp` from a handshake-only server into one that actually
transcribes:

- `Sources/DictamacMCP/ToolsCallHandler.swift` — the `tools/call`
  dispatcher. Owns the per-tool routing for `transcribe_file`,
  `transcribe_voice_memo`, and `list_voice_memos`. Only `transcribe_file`
  is fully wired in this PR; the two Voice-Memos tools return a tagged
  `isError: true` envelope pointing at follow-up issue #50.
- `Sources/DictamacMCP/ProductionMCPHandlers.swift` — gains a new
  overload `register(on:transcriber:audioResolver:)` so the CLI can wire
  all three handlers (`initialize`, `tools/list`, `tools/call`) in one
  pass. Existing handshake-only tests keep using the dep-less overload.
- `Sources/DictamacCore/DictamacError.swift` — gains a one-line
  `mcpToolErrorText` property whose value is `description`. This is the
  parity seam: the CLI writes `formattedStderrLine` (description + `\n`)
  to stderr, the MCP transport puts `description` into the `text`
  content item — both paths consult the same source of truth.
- `Sources/DictamacCLI/ModeDispatch.swift` — the `Mode.mcp` branch now
  calls the new registration overload with the shared `Transcriber` +
  `AudioFileResolver`. No other handler paths are touched.
- `Tests/DictamacMCPTests/ToolsCallTests.swift` plus
  `Tests/DictamacMCPTests/Mocks/{MockTranscriber,MockAudioFileResolver}.swift`
  — 23 tests covering happy paths, JSON-RPC `-32602` malformed-invocation
  paths, unknown-tool-name `isError` envelopes, every representative
  `DictamacError` variant (8 cases), CLI/MCP text parity, the two
  voice-memo stub paths, and an end-to-end stdout-discipline test that
  pipes four JSON-RPC requests through a real `MCPServer` and asserts
  every byte on stdout decodes as a JSON-RPC envelope.

## Why

The `tools/call` dispatcher is where MCP actually does work. Until it
landed, `dictamac --mcp` could greet a client and list its tools but
not transcribe anything. The acceptance criteria on issue #26 demand
that:

1. Every `DictamacError` produces an `isError: true` envelope whose
   text matches the CLI's stderr line verbatim — so an agent that
   parses one transport's failure message can parse the other's. The
   `description` property of `DictamacError` already encodes that
   message; the `mcpToolErrorText` shim makes the parity contract
   explicit at the call site instead of relying on an implicit
   convention.
2. Unknown tool names return `isError: true`, NOT JSON-RPC `-32601`.
   `-32601` is reserved for unknown JSON-RPC *methods* — and `tools/call`
   itself is a registered method, so the per-tool dispatch is
   application-level. Conflating the two would force agents to handle
   the same "tool not implemented" condition in two completely
   different ways.
3. Malformed `tools/call` invocations (missing `name`, missing required
   `path`, wrong `format` enum value) raise `-32602` at the
   protocol level. These are not failed tool executions; they are
   protocol-shape violations.

## How

A few decisions worth flagging:

- **`MCPToolsCallHandler` is a value type, not an actor.** All state it
  references — the `Transcriber` and `AudioFileResolver` — is already
  `Sendable`. Making the handler itself a struct lets the actor that is
  `MCPServer` invoke `handler.handle(params:)` without an extra
  await-hop, which keeps the dispatch path readable. Strict-concurrency
  is happy because each closure capture is a value-typed `any
  Transcriber` / `any AudioFileResolver` that the protocol already
  declares `Sendable`.
- **The voice-memo tools are stubs that validate their params.** Even
  though the bodies just return a stub envelope, the param validation
  is fully wired: missing `query` raises `-32602`, an empty `query`
  raises `-32602`, a non-integer `limit` raises `-32602`. When #50
  swaps the body for the real implementation, the validation already
  matches the schema and the test suite catches drift on day one.
- **`extractFormat` lives on `TranscriptionRequest.Format.init(rawValue:)`.**
  The format enum is already `RawRepresentable(rawValue: "text")`, so
  the MCP `format` argument decodes for free. We deliberately don't
  silently coerce unknown values — `format: "yaml"` raises `-32602`
  rather than falling back to text.
- **Absolute-path validation is at the param layer.** `transcribe_file`
  requires absolute paths so an agent can't accidentally trigger a
  relative-path resolve against the dictamac process's cwd (which it
  has no way to discover). The validation message includes the offered
  path so the agent's error log is debuggable.
- **The stub message includes a clickable issue URL.** Agents inspecting
  the `isError` text need to know exactly what is unimplemented and
  where the wiring work lives. `https://github.com/jwulff/dictamac/issues/50`
  is the canonical pointer; the same URL is referenced from this PR
  and the follow-up issue body.

## Test strategy

The tests fall in five buckets, all using Swift Testing:

1. **Happy paths.** `transcribe_file` with default format, with
   `format: "json"`, with a custom `locale`. The mock transcriber
   records what the dispatcher gave it so we can assert the
   `TranscriptionRequest` shape directly instead of just the response
   envelope.
2. **Protocol-level errors.** Every malformed invocation that should
   raise `-32602`: missing `name`, missing `path`, wrong `path` type,
   relative `path`, unknown `format` enum, missing `query`, wrong
   `limit` / `since` type.
3. **Tool-level errors.** Unknown tool name → `isError`. Every
   representative `DictamacError` variant from PLAN.md §7 U9 →
   `isError` with the right text. A `for` loop over the enumerated
   list keeps this honest as the enum grows.
4. **Parity test.** For every representative `DictamacError`,
   `formattedStderrLine.trimmingCharacters(in: .newlines)` must equal
   `mcpToolErrorText`. The test fails loudly if anyone changes one
   side without the other.
5. **End-to-end stdout discipline.** A real `MCPServer` with the
   production handler set wired up, four JSON-RPC requests on stdin
   (initialize + happy + unknown-tool + missing-param), and the
   assertion that every line on stdout decodes as a JSON-RPC envelope.
   This is the test that would have caught any stray `print(...)` in
   the dispatch path.

## Cross-PR coordination

Two parallel agents are working in adjacent territory:

- Agent M on #23 (`Sources/DictamacVoiceMemos/`) — this PR doesn't
  touch their files.
- Agent N on #25 (`Sources/DictamacCLI/`) — this PR only edits the
  `Mode.mcp` branch of `ModeDispatch.swift`; the
  `Mode.listVoiceMemos` branch is left alone.

The follow-up issue (#50) wires the two stub Voice-Memos MCP tools
once #23 + #25 land. The stub messages already point at #50 so an
agent that hits the stub knows exactly where to look.

## Follow-ups

- Issue #50 — replace the two stub voice-memo tool bodies with calls
  through the shared `VoiceMemosIndex` once #23 / #25 merge.
- A subprocess integration test that spawns the real binary and drives
  it with the `hello-world.m4a` fixture lives in the future. PLAN.md
  §7 U10 documents that gap; out of scope here per the issue's
  "Out of scope" line.
