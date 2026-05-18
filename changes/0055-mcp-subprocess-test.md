# Add subprocess integration test for MCP

PR: #55
Issues: Closes #28 (Refs #5)

## What changed

A single Swift Testing test that spawns the built `dictamac --mcp`
binary as a real subprocess and drives a full JSON-RPC handshake
over its stdin/stdout pipes. The test exercises the transport the
way a real MCP client (an agent harness, Claude) does — process
boundary, real `\n`-framed line buffering, real stdout vs. stderr
separation, real ad-hoc-signed binary with the SpeechAnalyzer
entitlements, and the actual macOS 26 `SpeechAnalyzer` pipeline
rather than an in-process mock.

Files:

- `Tests/DictamacMCPTests/MCPSubprocessIntegrationTests.swift` —
  the integration test plus a `StreamingLineReader` helper. The
  test sends `initialize`, `tools/list`, and `tools/call
  transcribe_file` against the committed `hello-world.m4a`
  fixture, then asserts the response shape, the version pin, the
  capability surface (`tools` only, no `resources`/`prompts`/
  `sampling`), the three documented tool names + schema fields,
  and that the transcribed text contains at least one of `hello`,
  `world`, `test`. Every line on subprocess stdout must parse as
  a JSON-RPC envelope; any stderr line that decodes as a JSON-RPC
  envelope fails the test (channel mis-routing guard).
- `Makefile` — added a `test-integration` target that depends on
  `build` so the signed binary is guaranteed present before the
  suite runs end-to-end. The default `test` target is unchanged
  (the integration test self-skips when the binary is absent).

## How it skips

The test records a `.warning`-severity `Issue` (not `.error`) and
returns when any of these hold:

- `DICTAMAC_SKIP_INTEGRATION_TESTS=1` is set — CI escape hatch
  for runners that don't have the en-US locale model installed.
- `<repo>/.build/release/dictamac` is absent — `swift test`
  alone doesn't build or sign the executable target. The error
  message points the operator at `make build`.
- The repo root can't be located by walking up from
  `Bundle.module.bundleURL`. Defensive — shouldn't fire in
  practice.
- The fixture file is missing.

`severity: .warning` issues are visible in Swift Testing output
(prefixed with `⚠`) without flipping the suite red. This matches
the existing skip pattern in
`SpeechAPILocaleModelCheckerIntegrationTests`.

## macOS 26 Foundation regression worked around

While building the test we hit a macOS 26 / Swift 6.3 regression:
`FileHandle.read(upToCount:)` on a pipe connected to a child
process does NOT return as soon as bytes are available — it
blocks until either the buffer fills (~4096 bytes) or the writer
closes the pipe. Reproduced both with `dictamac` and with a
trivial `Darwin.write(1, …)` writer child. Reading one byte at
a time worked; reading 4096 hung until the child closed its end
of the pipe.

Two consequences for this PR:

1. The test reads subprocess stdout/stderr via posix
   `Darwin.read(_:_:_:)` on the underlying file descriptor rather
   than via `FileHandle.read(upToCount:)` /
   `readDataToEndOfFile()`. `StreamingLineReader` documents the
   reasoning inline.
2. The test sends all three requests in a single batched write,
   then closes stdin before draining stdout. That's the same I/O
   pattern every in-process MCP server test in this target
   already uses (e.g. `MCPServerTests.dispatchesRegisteredHandler…`),
   and it's sufficient to exercise the process boundary,
   signing, entitlements, and stdout/stderr discipline — which
   the in-process tests cannot.

`MCPServer.swift` itself uses `FileHandle.read(upToCount:)` and
will exhibit the same blocking when a real MCP client streams
requests over time without closing stdin between them. Today
every shell-piped invocation (`echo {…} | dictamac --mcp`)
matches the close-after-write pattern, so the binary is fine in
practice; whether the streaming-client case needs MCPServer to
switch to `Darwin.read` is a separate question. Followup: see
issue (TBD) for tracking the read-loop streaming behavior under
the Foundation regression.

## Why not `swift run`

`swift run` skips code-signing. `SpeechAnalyzer` requires the
`disable-library-validation` and `allow-jit` entitlements at
launch or the binary takes `SIGTRAP` on first touch. `make build`
runs `codesign --entitlements …` after the link step; the test
depends on that artifact being present. The acceptance criterion
"the test must depend on `make build` so signing happens, not
invoke `swift run`" (#28 Notes) is satisfied by the self-skip
gate.

## End-to-end verification

```
$ make build && make test
…
✔ Test subprocessHandshakeListsToolsAndTranscribesFixture() passed after 0.279 seconds.
✔ Test run with 350 tests in 31 suites passed after 0.355 seconds.
```

Sample exchange captured by the test for debugging (always
printed):

```
→ [1] {"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
→ [2] {"jsonrpc":"2.0","id":2,"method":"tools/list"}
→ [3] {…"name":"transcribe_file","arguments":{"path":"…/hello-world.m4a"}…}

← initialize: protocolVersion=2025-06-18, serverInfo={dictamac/0.0.0-dev/jwulff},
              capabilities={tools:{}}
← tools/list: [transcribe_file, transcribe_voice_memo, list_voice_memos]
← tools/call: {"content":[{"text":"Hello, world, this is a test.\n","type":"text"}]}

exit status=0 (clean)
```

## Anti-patterns avoided

- No new top-level directory (file lives under `Tests/DictamacMCPTests/`).
- No duplication of the en-US fixture (reuses
  `Tests/DictamacSpeechTests/Fixtures/hello-world.m4a` via repo-root
  walk).
- No force unwraps; every optional unwrap goes through `guard` or
  `if case .object(…)` with a structured fallback.
- No modification to `Sources/DictamacMCP/` (Agent Q's territory
  for #50).
- No `--no-verify` git operations.
