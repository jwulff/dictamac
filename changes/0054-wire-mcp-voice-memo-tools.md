# Wire MCP voice-memo tools to VoiceMemosResolver

PR: TBD
Issues: Closes #50 (Refs #5)

## What changed

The two voice-memo MCP tools (`transcribe_voice_memo` and
`list_voice_memos`) are no longer stubs. They now ride the same shared
`VoiceMemosResolver` that the CLI's `--voice-memo` / `--list-voice-memos`
flags use, so behaviour parity holds across the two transports.

Files touched:

- `Sources/DictamacMCP/ToolsCallHandler.swift` — the two stub handlers
  (which returned a tagged `isError: true` envelope pointing at this
  issue) are replaced with real implementations:
  - `transcribe_voice_memo` parses the query through
    `VoiceMemoQuery.parse(_:)`, resolves it via
    `VoiceMemosResolver.resolve(_:now:)`, hands the resolved memo's
    `assetPath` through the same `AudioFileResolver` + `Transcriber`
    pipeline `transcribe_file` uses, and renders plaintext or JSON per
    `format`.
  - `list_voice_memos` parses `since` via `DurationString` (default
    `30d`), clamps `limit` to `[1, 100]` (default `30`), calls
    `VoiceMemosResolver.list(since:limit:)`, and JSON-encodes the
    result as `[VoiceMemoListing]` — the same wire shape the CLI's
    `--list-voice-memos --json` mode emits.
  - The shared `voiceMemoStubMessage` constant and its callers are
    removed.
- `Sources/DictamacMCP/ProductionMCPHandlers.swift` — the
  three-argument `register(on:transcriber:audioResolver:)` overload is
  promoted to a four-argument `register(on:transcriber:audioResolver:voiceMemosResolver:)`
  since the handler now needs the resolver. The handshake-only
  `register(on:)` overload is unchanged (existing tools/list tests
  keep using it).
- `Sources/DictamacCLI/ModeDispatch.swift` — the `Mode.mcp` branch now
  passes a `VoiceMemosResolver` instance constructed via the shared
  `voiceMemosResolverFactory` closure. This is the same factory the
  `--list-voice-memos` CLI handler uses, so a future test override
  flows through both transports.
- `Package.swift` — `DictamacMCP` and `DictamacMCPTests` now depend on
  `DictamacVoiceMemos` so the handler can take a `VoiceMemosResolver`
  parameter without an additional protocol seam.
- `Tests/DictamacMCPTests/Mocks/MockVoiceMemosResolver.swift` — new.
  Test-only stub implementation of `VoiceMemosResolver` plus a
  `VoiceMemoMetadataFixture.canned(...)` builder. Kept independent of
  the CLI test target's similar mock so the MCP target stays isolated.
- `Tests/DictamacMCPTests/ToolsCallTests.swift` — the three stub
  voice-memo tests are replaced with 14 new tests covering happy
  paths (plaintext + JSON), locale forwarding, query parsing, default
  argument application, limit clamping, the `-32602` paths
  (missing/empty/wrong-type query, invalid `since` duration, wrong
  arg types), and the `DictamacError → isError` envelope mappings for
  `voiceMemoNotFound`, `voiceMemoLibraryMissing`, and
  `permissionDenied`. The existing end-to-end stdout-discipline test
  is updated to pass a `MockVoiceMemosResolver`.

## Why

PR #52 (#26) landed the MCP `tools/call` dispatcher but only fully
wired `transcribe_file`. The other two tools were tagged stubs
pointing at this issue so an agent or future-me could see clearly
where the wiring work lived. With the Voice Memos resolver (#51) and
the CLI listing handler (#53) now on `main`, the dependency that
gated this work is unblocked — both MCP tools can ride the same core
the CLI uses without a new protocol seam.

Behaviour parity matters here because both transports are
documented (PLAN.md §5 + §7 U9) as thin shells over the same core:
the same query string fed to `--voice-memo` and to MCP's
`transcribe_voice_memo.query` must resolve to the same memo, and the
same failure must produce the same human-readable text on both
transports. Reusing `VoiceMemoQuery.parse(_:)`, the shared
`VoiceMemosResolver` protocol, `DurationString`, and `VoiceMemoListing`
(plus the existing `DictamacError.mcpToolErrorText` parity seam) is
how that parity is enforced rather than asserted.

## Test plan

`swift test` exercises the wiring at the protocol seam:

- `transcribeVoiceMemoResolvesAndTranscribes` — happy path; asserts
  the parsed query reached the VM resolver, the memo's `assetPath`
  reached the audio resolver, and the transcript flowed back into the
  MCP envelope.
- `transcribeVoiceMemoReturnsJSONWhenFormatIsJson` — `format=json`
  produces the §6 transcript schema text.
- `transcribeVoiceMemoForwardsLocaleArgument` — locale flows through.
- Three `-32602` tests for missing/empty/wrong-type query.
- Two `DictamacError → isError` envelope tests
  (`voiceMemoNotFound`, `voiceMemoLibraryMissing`).
- `listVoiceMemosReturnsJSONArrayOfListings` — decodes the response
  text back through the shared `[VoiceMemoListing]` Codable, pinning
  the schema rather than the byte-level formatting.
- `listVoiceMemosAppliesDefaultsWhenArgsMissing` — default
  `since=30d` / `limit=30`.
- Clamp tests at both bounds (`limit=0` → 1, `limit=1000` → 100).
- `listVoiceMemosInvalidSinceRaisesInvalidParams` — bad duration
  string surfaces as `-32602`, not as an `isError` envelope.
- Two `DictamacError → isError` envelope tests
  (`voiceMemoLibraryMissing`, `permissionDenied`).

End-to-end: piping `initialize` + `list_voice_memos` through the
release binary against a real Voice Memos library returns the
expected JSON array of listings (verified locally; the e2e contract
also passes for `transcribe_voice_memo` with a non-matching query —
the resolver throws `voiceMemoNotFound`, which the handler maps to a
clean `isError: true` envelope with the same text the CLI would
write to stderr).

## Anti-pattern audit

- No force unwraps added.
- No new top-level directories.
- No `TODO:` comments left without a filed issue (the stub message
  pointing at this issue is gone).
- Stdout discipline preserved: the MCP transport still writes only
  JSON-RPC responses to stdout; nothing else moved.
- The existing `transcribe_file` handler from #52 is untouched.
- The voice-memos resolver (`Sources/DictamacVoiceMemos/`) is
  untouched — this PR only consumes the existing types.
