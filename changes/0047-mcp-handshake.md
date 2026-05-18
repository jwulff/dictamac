# Add MCP `initialize` and `tools/list` handshake

PR: #47
Issues: Closes #22 (Refs #5)

## What changed

`dictamac --mcp` now answers the two methods every MCP client calls at
startup:

- **`initialize`** — returns the server identity (`name: "dictamac"`,
  `version: "0.0.0-dev"`, `vendor: "jwulff"`), the `tools`-only
  capability set, and the pinned MCP `protocolVersion`.
- **`tools/list`** — returns the three transcription tool schemas
  documented in `docs/PLAN.md` §5: `transcribe_file`,
  `transcribe_voice_memo`, `list_voice_memos`.

Until now the dispatch loop landed by #18 was wired to an empty
handler registry; any method returned `-32601 Method not found`. The
handshake is the minimum surface a client needs before it can
meaningfully call anything else (`tools/call` lands in #26).

## Why this exists as a single PR

The acceptance criteria on #22 deliberately bundle the two handlers
because the pinned `protocolVersion` belongs in exactly one constant.
Splitting them would either duplicate the version string or invent a
shared module just to hold one line; the bundling avoids both.

## Pinned protocol version

The pin lives in `Sources/DictamacMCP/MCPProtocol.swift`:

```swift
public let mcpProtocolVersion: String = "2025-06-18"
```

The chosen revision is the latest stable Model Context Protocol spec
version available at the time of writing
(<https://spec.modelcontextprotocol.io/>). `docs/PLAN.md` §5 mentions
`"2024-11-05"` from the project's initial planning, but bumping to
`2025-06-18` aligns the implementation with the current published spec
and the more recent revision is what mainstream MCP clients now
advertise. The PLAN.md update can ride in a follow-up docs PR — the
constant is the source of truth at runtime.

### Drift guard

`InitializeHandlerTests.pinnedProtocolVersionMatchesExpectedConstant`
asserts the literal value of the constant, not just "any non-empty
string". Bumping the constant therefore fails the test, which fails
CI, which makes the bump deliberate. That's the mitigation called out
in `docs/PLAN.md` §9 ("MCP protocol version drift").

## Tool schemas — golden-file snapshot test

`ToolsListHandlerTests.toolsListMatchesGoldenSnapshot` loads the full
`tools/list` result envelope from
`Tests/DictamacMCPTests/__Snapshots__/tools-list.json` and structurally
compares it (via `JSONValue` Codable round-trip) against the live
handler output. Structural equality, not byte equality — JSON key
ordering would otherwise cause spurious failures depending on encoder
sort flags.

A spec drift (renamed tool, added field, changed enum) fails the
snapshot test loudly with a message pointing the dev at both the
snapshot file and `docs/PLAN.md` §5. Updating the snapshot file is
then the deliberate act that captures the new spec.

The snapshot file ships as a test resource via
`Package.swift`'s `DictamacMCPTests.resources: [.copy("__Snapshots__")]`
— the only change to `Package.swift` in this PR. The `targets:` array
itself is untouched.

## Module shape

New files:

- `Sources/DictamacMCP/MCPProtocol.swift` — the pinned version constant
  and `MCPServerIdentity` value type. Two compile units share these
  (`ProductionMCPHandlers` and the test target) so duplication of the
  identity strings doesn't drift.
- `Sources/DictamacMCP/ProductionMCPHandlers.swift` — the actual
  handler functions plus `register(on:)`. Designed as a single seam:
  the CLI calls `ProductionMCPHandlers.register(on: server)` and tests
  invoke `ProductionMCPHandlers.initialize(params:)` /
  `.toolsList(params:)` directly. Adding `tools/call` in #26 is an
  edit to this one file.

`Sources/DictamacCLI/ModeDispatch.swift`'s `.mcp` arm now calls
`ProductionMCPHandlers.register(on: server)` before `server.serve()`.
Everything else in the dispatch path is unchanged.

## Stdout discipline (still the hard rule)

Both handlers are pure functions that return `JSONValue` — they have
no I/O of their own. Diagnostic output happens only through
`MCPServer.logToStandardError(_:)`, which already targets stderr. The
existing `MCPServerStdoutTests` mixed-traffic suite continues to pass
unchanged, and two new `*RegisteredOnServerProducesExpectedEnvelope`
tests assert stderr stays empty when our handlers run.

## Following the package-version note

The issue suggests reading the version from a single source of truth.
Today that's the `CommandConfiguration(version: "0.0.0-dev")` in
`Sources/DictamacCLI/Dictamac.swift`; extracting a shared package
constant means either pulling argparse into `DictamacMCP` (circular)
or moving the constant into `DictamacCore` and threading it through
the CLI. Neither is right-sized for this PR — both edits are bigger
than the handshake itself. The current arrangement hardcodes
`"0.0.0-dev"` in `MCPServerIdentity.dictamac` with a note in the
doc comment pointing back at the CLI's value; a follow-up issue
should land a shared `DictamacVersion` constant once the dust settles
on what owns it.

## Verified

- `make test` — 227 tests across 22 suites, all passing (52 of those
  are `DictamacMCPTests`, +14 new vs. PR #46).
- `make build` + `make sign` — clean release build, ad-hoc signed.
- E2E (full handshake, including `notifications/initialized`):
  ```
  $ printf '%s\n%s\n%s\n' \
      '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
      '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
      '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
      | ./.build/release/dictamac --mcp
  {"id":1,"jsonrpc":"2.0","result":{"capabilities":{"tools":{}},"protocolVersion":"2025-06-18","serverInfo":{"name":"dictamac","vendor":"jwulff","version":"0.0.0-dev"}}}
  {"id":2,"jsonrpc":"2.0","result":{"tools":[…transcribe_file…transcribe_voice_memo…list_voice_memos…]}}
  ```
  Two requests → two response lines. The notification produces no
  response. Stderr silent. Exit code 0.

## Follow-ups

- #26 — `tools/call` dispatch and MCP `isError: true` tool-error
  mapping (will plug into the same
  `ProductionMCPHandlers.register(on:)` seam)
- Follow-up issue (to file): consolidate the dictamac version string
  so `Dictamac.swift` and `MCPServerIdentity.dictamac` read from one
  constant
- Follow-up issue (to file): update `docs/PLAN.md` §5 to reference
  `2025-06-18` as the pinned protocol version (currently still says
  `2024-11-05`)
