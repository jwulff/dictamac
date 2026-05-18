# Document stdin source in PLAN; read version from Info.plist

PR: #59
Issues: Closes #44 Closes #32

## What changed

Two small, independently scoped fixes that travel together because
neither warranted its own PR cycle.

### #44 — PLAN.md §6 documents `TranscriptSource.stdin`

`Sources/DictamacCore/Transcript.swift` already encodes three
`TranscriptSource` variants — `.file`, `.voiceMemo`, and `.stdin` —
since PR #43. PLAN.md §6 only listed the first two, so the spec and
the code had drifted. This PR brings them back into agreement.

`docs/PLAN.md` §6 now:

- Names `source.type` explicitly as a three-valued discriminator —
  `"file"`, `"voice-memo"`, `"stdin"` — and describes the payload
  shape that each implies.
- Documents that the `.stdin` variant carries **no** `path`,
  `identifier`, or `title` — just `{"type": "stdin"}` — and explains
  *why* (the CLI stages stdin into a temp file long enough to feed
  SpeechAnalyzer and then deletes it, so any path here would dangle
  by the time a consumer read the JSON).
- Includes a sibling JSON example showing the bare `"source":
  {"type": "stdin"}` shape so consumers don't have to infer it from
  prose.
- Notes that adding a new discriminator value is an additive variant —
  v1 consumers that don't know about `"stdin"` are expected to fail
  loudly on decode (matching the encoder), so the schema `version`
  is NOT bumped for this kind of addition.

No code changes — the encoder, decoder, and snapshot
(`Tests/DictamacCoreTests/__Snapshots__/stdin-source.json`) already
match. This PR aligns the spec with what ships.

### #32 — single source of truth for the version string

Before this PR the `0.0.0-dev` literal was hardcoded in three places:

- `Resources/Info.plist` (`CFBundleShortVersionString`,
  `CFBundleVersion`) — set to `0.0.0` in PR #29
- `Sources/DictamacCLI/Dictamac.swift` —
  `CommandConfiguration(version: "0.0.0-dev")`
- `Sources/DictamacMCP/MCPProtocol.swift` —
  `MCPServerIdentity.dictamac.version = "0.0.0-dev"`

Bumping any one of them and forgetting another was the bug class
this issue exists to eliminate. (Aside: the Info.plist version was
already drifting — `0.0.0` vs. the code's `0.0.0-dev`. This PR
realigns them as part of the fix.)

The new arrangement:

- `Resources/Info.plist` is the single source of truth.
  `CFBundleShortVersionString` and `CFBundleVersion` are both set to
  `0.0.0-dev`.
- `Sources/DictamacCore/DictamacVersion.swift` (new) exposes
  `DictamacVersion.current`, which reads
  `CFBundleShortVersionString` from `Bundle.main.infoDictionary` at
  process startup (computed once via a `static let` initializer).
- `Dictamac.swift`'s `CommandConfiguration(version:)` and
  `MCPServerIdentity.dictamac.version` both call into
  `DictamacVersion.current`, so the CLI banner and the MCP
  `serverInfo.version` cannot drift from each other or from the
  embedded plist.

The Makefile's `make build` target embeds `Resources/Info.plist` into
the release binary via `-Xlinker -sectcreate -Xlinker __TEXT
-Xlinker __info_plist`, so `Bundle.main.infoDictionary` resolves the
embedded plist at runtime when the signed binary runs.

### Test-bundle fallback

When running under `swift test`, `Bundle.main` is the test runner
(`xctest`) — not the dictamac executable — and there is no embedded
dictamac Info.plist in that bundle. `DictamacVersion.current` falls
through to the documented fallback string `"0.0.0-unknown"` in this
case. This is intentional: the runtime contract is "the embedded
plist wins when it's present; otherwise we surface an explicit
unknown sentinel rather than silently lying."

The fallback constant is exposed publicly
(`DictamacVersion.unknown`) so tests can assert the fallback
behavior without duplicating the literal.

### Tests

- `Tests/DictamacCoreTests/DictamacVersionTests.swift` (new) covers:
  - `DictamacVersion.current` is never empty.
  - The documented fallback is the literal `"0.0.0-unknown"`.
  - Under `swift test`, `DictamacVersion.current` equals
    `DictamacVersion.unknown` (no embedded dictamac Info.plist in
    the test runner).
  - Drift guard: `Resources/Info.plist` is read off disk via
    `PropertyListSerialization`, and `CFBundleShortVersionString` ==
    `CFBundleVersion` is asserted. If a future agent bumps one but
    forgets the other (the exact bug class #32 exists to prevent),
    this test fails.

- `Tests/DictamacCLITests/DictamacParsingTests.swift` —
  `versionStringMatchesConfiguration` now asserts equality against
  `DictamacVersion.current` instead of the literal `"0.0.0-dev"`, so
  bumping the version in `Info.plist` doesn't require also touching
  this test.

- `Tests/DictamacMCPTests/InitializeHandlerTests.swift` —
  `initializeResultIncludesServerIdentity` and
  `initializeRegisteredOnServerProducesExpectedEnvelope` likewise
  assert against `DictamacVersion.current`.

## End-to-end verification

```
$ make build && make sign
…
Build complete!
.build/release/dictamac: replacing existing signature

$ .build/release/dictamac --version
0.0.0-dev

$ echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
    | .build/release/dictamac --mcp
{"id":1,"jsonrpc":"2.0","result":{"capabilities":{"tools":{}},
  "protocolVersion":"2025-06-18",
  "serverInfo":{"name":"dictamac","vendor":"jwulff","version":"0.0.0-dev"}}}
```

Both surfaces report `0.0.0-dev`, the value in
`Resources/Info.plist`. Bumping the plist is now the only edit
required to bump the published version.

## Files touched

- `docs/PLAN.md` — §6 stdin documentation (#44)
- `Resources/Info.plist` — realign `CFBundleShortVersionString` /
  `CFBundleVersion` to `0.0.0-dev` (#32)
- `Sources/DictamacCore/DictamacVersion.swift` — new constant (#32)
- `Sources/DictamacCLI/Dictamac.swift` — read version from
  `DictamacVersion.current` (#32)
- `Sources/DictamacMCP/MCPProtocol.swift` — read version from
  `DictamacVersion.current`; add `import DictamacCore` (#32)
- `Tests/DictamacCoreTests/DictamacVersionTests.swift` — new (#32)
- `Tests/DictamacCLITests/DictamacParsingTests.swift` — drift-free
  assertion (#32)
- `Tests/DictamacMCPTests/InitializeHandlerTests.swift` — drift-free
  assertion (#32)
- `changes/0056-plan-stdin-version-source.md` — this file

## Anti-patterns avoided

- No force unwraps; the `Bundle.main.infoDictionary?[…] as? String`
  lookup uses optional chaining and falls through to the explicit
  `unknown` sentinel.
- No new top-level directory.
- No `--no-verify` git operations.
- No touch on `CLAUDE.md` (Agent W's territory), `Makefile` /
  `README.md` (Agent X), or the `Mode.voiceMemo` path in
  `Dictamac.swift` (Agent U).
