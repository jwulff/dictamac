# Add MCP JSON-RPC stdio loop

PR: TBD
Issues: Closes #18 (Refs #5)

## What changed

`dictamac --mcp` now runs a real JSON-RPC 2.0 stdio server instead of
the "not yet implemented" stub from PR #42. The new transport reads
line-delimited JSON requests from stdin, dispatches by method name to
registered handlers, and writes one-line responses to stdout — with
strict stdout/stderr separation so the JSON-RPC channel stays clean.

For this PR the handler registry is empty: every method call returns
`-32601 Method not found`. The actual `initialize` / `tools/list` /
`tools/call` handlers plug in via `MCPServer.register(method:handler:)`
in follow-up issues (#22, #26). The dispatch surface — the part every
other MCP epic child depends on — is what lands here.

## Why

The MCP epic (#5) needed a foundation: a transport that handles
framing, dispatch, and the canonical JSON-RPC error responses so each
follow-up issue can focus on its own tool semantics without
re-inventing the protocol layer. Implementing the loop directly (no
third-party Swift MCP SDK) was a deliberate constraint — the surface
is ~200 lines and a dependency would buy little for a project this
focused.

## How — module shape

New SPM target `DictamacMCP`, depending on `DictamacCore` only. The
CLI target now depends on it so `Mode.mcp` can construct and run a
server. Two new test targets land alongside: `DictamacMCPTests`
covering the transport in isolation.

**Note on parallel work.** Agent G on issue #14 (`Sources/DictamacVoiceMemos/`)
is editing `Package.swift` at the same time to add a different SPM
target. Both PRs touch the `targets:` array; whichever lands second
will resolve a trivial conflict by reapplying its target entry.

## How — JSONValue design

`JSONValue` is a Codable enum with cases `null / bool / int / double /
string / array / object`. The Int vs. Double split is intentional:

- JSON-RPC ids are commonly integers and we want them to stay
  integral through the round trip
- `JSONDecoder` will accept any number as a `Double`, so we try `Int`
  first in `init(from:)` to preserve whole-number type fidelity

This keeps `JSONValue` self-contained — no `Any`, no `[String: Any]`,
no JSONSerialization detour — and lets handlers convert to typed
models lazily.

## How — server architecture

`MCPServer` is an actor so handler registration and the dispatch table
are race-free without callers having to coordinate locks. The read
loop awaits each handler sequentially: MCP doesn't promise concurrent
dispatch, and parallel handlers would let a slow `tools/call` race a
fast `tools/list` onto the wire out of order.

### Line framing

Each JSON-RPC request is one JSON object on one line, terminated by
`\n`. The server buffers incoming bytes (4096-byte chunks via
`FileHandle.read(upToCount:)`) and peels off `\n`-terminated lines one
at a time. CRLF is tolerated (trailing `\r` stripped). EOF on stdin
returns from `serve()` cleanly; any partially-buffered final line
without a trailing newline is still dispatched before exit so a
sloppy client doesn't silently lose its last request.

### Error mapping

| Wire condition | Response |
|---|---|
| Method not registered | `-32601 Method not found`, id preserved |
| Handler throws `MCPProtocolError.invalidParams(_)` | `-32602 Invalid params`, id preserved |
| Handler throws anything else | `-32603 Internal error`, description preserved |
| Line fails to JSON-decode | `-32700 Parse error`, `id: null` |

The `id: null` shape on parse errors is encoded explicitly via
`container.encodeNil(forKey: .id)` — `encodeIfPresent` would omit the
key, which violates the spec.

### Three-state request `id` (post-review fix)

Codex review caught that the original `JSONRPCRequest.id: JSONRPCID?`
collapsed two spec-distinct states into one `nil` value:

- **Field absent** — notification per §4.1; server MUST NOT respond.
- **Field present and `null`** — request per §4.2; server MUST respond
  with `"id": null` echoed back.
- **Field present with string/int** — normal request.

A plain `Optional<JSONRPCID>` cannot tell the first two apart. A
correct JSON-RPC 2.0 client that sent `"id": null` to invoke a method
would hang waiting for the response we silently suppressed.

The fix introduces `JSONRPCIDField` — a three-case enum (`absent` /
`null` / `value(JSONRPCID)`) — and a custom `JSONRPCRequest.init(from:)`
that uses `container.contains(.id)` plus `container.decodeNil(forKey:)`
to distinguish all three states on decode. The dispatcher switches on
`request.id.isNotification` instead of `request.id == nil`; the
response id is then derived via `request.id.responseID`, which maps
both `.absent` and `.null` to `nil` (the `.absent` case never reaches
the response writer in practice). The response side is unchanged —
`JSONRPCResponse.id == nil` already encodes as JSON `null` via the
custom encoder added for the parse-error path.

Regression tests cover all three states across the happy path,
unknown-method (-32601), and invalid-params (-32602) branches. The
existing notification + malformed-line tests verify the no-response
and parse-error paths still behave correctly.

### Stdout discipline (the hard rule)

stdout is the JSON-RPC channel and nothing else. The server has one
dedicated path for diagnostics — `logToStandardError(_:)` — used only
for genuine I/O / encoding failures that can't be surfaced as a
JSON-RPC response. The dedicated `MCPServerStdoutTests` suite drives
mixed-traffic scenarios (good calls + parse errors + invalid-params
throws + unknown methods) through the server and asserts every line
on stdout decodes as a `JSONRPCResponse`. A stray `print()` in the
dispatch path would fail this test loudly.

### CLI integration

`Mode.mcp` in `ModeDispatch.swift` now builds an `MCPServer()` bound
to the real `FileHandle.standardInput` / `standardOutput` /
`standardError`, calls `serve()`, then `Darwin.exit(0)` once the loop
returns. The concurrency-shape rationale from PR #40
(`ParsableCommand` + `Task {}` + `dispatchMain()`) is preserved
verbatim — switching to `AsyncParsableCommand` would still break
SpeechAnalyzer when the actual transcription tools land. The MCP path
doesn't need the main RunLoop today, but the surrounding shell does
once `tools/call` plugs in.

## Verified

- `swift test` — 203 tests across 19 suites, all passing (44 of those
  are new `DictamacMCPTests`).
- `make build` — clean release build, ad-hoc signed.
- E2E:
  ```
  $ echo '{"jsonrpc":"2.0","id":1,"method":"foo"}' | ./.build/release/dictamac --mcp
  {"error":{"code":-32601,"message":"Method not found: foo"},"id":1,"jsonrpc":"2.0"}
  ```
  Exit code 0. Stderr silent.
- E2E with mixed traffic (request + notification + malformed line)
  produces exactly two response lines (the notification correctly
  produces none, the malformed line yields `-32700` with `id: null`)
  and again silent stderr.

## Follow-ups

- #22 — `initialize` + `tools/list` handlers, registered via the new
  surface
- #26 — `tools/call` dispatch + MCP `isError: true` tool-error mapping
- #15 (or successor) — subprocess integration test spawning
  `dictamac --mcp` and exercising the full handshake
