# Wire CLI --voice-memo to VoiceMemosResolver

PR: TBD
Issues: Closes #56 (Refs #4)

## What changed

The CLI's `--voice-memo <query>` flag is no longer a stub. It now rides
the same shared `VoiceMemosResolver` + `AudioFileResolver` +
`Transcriber` pipeline that the MCP `transcribe_voice_memo` tool was
wired to in PR #54. The PLAN.md §5 / §7 U9 "thin shells over the same
core" invariant is restored: the same query string fed to either
transport produces the same transcript (or the same
`DictamacError`-mapped failure).

Files touched:

- `Sources/DictamacCLI/VoiceMemoHandler.swift` — new file. Hosts
  `runVoiceMemo(...)`, the testable seam parallel to
  `runResolveAndTranscribe` (file/stdin) and `runListVoiceMemos`
  (`--list-voice-memos`). Trims + validates the query, parses it via
  `VoiceMemoQuery.parse(_:)`, resolves through the injected
  `VoiceMemosResolver`, hands the memo's `assetPath` through the
  shared `AudioFileResolver`, transcribes, renders via
  `PlaintextFormatter` / `JSONFormatter`, and writes to stdout. Errors
  flow through `DictamacError.formattedStderrLine` + the right exit
  code so the stderr text matches the MCP envelope's
  `mcpToolErrorText` byte-for-byte (minus the trailing newline).
- `Sources/DictamacCLI/ModeDispatch.swift` — the `voiceMemo:` closure
  inside `ModeHandlers.production(...)` no longer routes through
  `StubMessages.voiceMemoNotImplemented(...)`. It now builds the
  voice-memos resolver via the shared `voiceMemosResolverFactory`
  closure (same factory the `--list-voice-memos` handler uses) and
  calls `runVoiceMemo(...)` with the production transcriber + audio
  resolver.
- `Sources/DictamacCLI/StubMessages.swift` — the
  `voiceMemoNotImplemented(query:)` constant is removed. The MCP stub
  message stays put — its handler still exits with the "see epic #5"
  message at the dispatch layer for legacy CLI paths that don't
  exercise the live MCP server, though the live MCP server itself is
  wired (see `Sources/DictamacCLI/ModeDispatch.swift`'s `mcp:` closure).
- `Tests/DictamacCLITests/VoiceMemoHandlerTests.swift` — new file. 12
  tests covering: plaintext happy path, JSON happy path, locale
  forwarding, whitespace-only/empty query → exit 2,
  `voiceMemoNotFound` → exit 66, `voiceMemoLibraryMissing` → exit 74,
  `permissionDenied` → exit 73 with deep-link surfaced,
  audio-resolver `fileNotFound` → exit 64, transcriber failure → exit
  code + cleanup invariant, cleanup on success, and a CLI/MCP parity
  check that asserts the CLI's stderr line equals the MCP envelope's
  `mcpToolErrorText` for the same `DictamacError`.
- `Tests/DictamacCLITests/StubHandlerTests.swift` — the stub-message
  test for `--voice-memo` is removed; a comment in its place points at
  the new `VoiceMemoHandlerTests.swift` so future readers can trace
  the migration.

## Why this shape

`runVoiceMemo(...)` is a top-level function (not a method on a struct
or actor) for the same reason `runResolveAndTranscribe` and
`runListVoiceMemos` are: the only state the production path needs
flows in via closure arguments. The dispatch site in
`ModeDispatch.swift` stays a one-liner, mirroring the MCP handler in
`Sources/DictamacMCP/ToolsCallHandler.swift::handleTranscribeVoiceMemo`
without sharing actor / class identity (which would force one
transport's concurrency story onto the other).

The handler intentionally does NOT call into
`runResolveAndTranscribe` even though the file-path branch ends up
doing similar work. The two have different inputs (a parsed
`VoiceMemoQuery` vs. an `AudioSource`), different error precedence
(voice-memo lookup runs first; an absent library throws 74 before any
audio resolution can fail), and different first-stage validation
(whitespace-only query → exit 2 vs. fileNotFound → exit 64).
Sharing the second half (audio resolve + transcribe + render +
cleanup) is tempting but would either (a) split the function into
small pieces that obscure the linear failure order, or (b) leak a
"how was this invoked?" enum into the helper. The MCP reference
implementation made the same call — see issue #56's notes section
referencing the `transcribe_voice_memo` MCP handler.

## End-to-end verification

Against a real Voice Memos library on the dev machine:

```
$ ./.build/release/dictamac --voice-memo ""
Argument error: --voice-memo requires a non-empty query.
EXIT: 2

$ ./.build/release/dictamac --voice-memo "   "
Argument error: --voice-memo requires a non-empty query.
EXIT: 2

$ ./.build/release/dictamac --voice-memo "absolutely-no-such-memo-12345xyz"
No Voice Memo matched query: absolutely-no-such-memo-12345xyz
EXIT: 66

$ ./.build/release/dictamac --voice-memo "yesterday"
Okay, here's the idea. Um, spec driven... everything. The idea is that, um,
[...full transcript...]
EXIT: 0

$ ./.build/release/dictamac --json --voice-memo "yesterday" | jq '.version, (.fullText | .[0:80]), (.segments | length)'
1
"Okay, here's the idea. Um, spec driven... everything. The idea is that, um, Ther"
45
EXIT: 0
```

The exit codes match the PLAN.md §4 contract (2 / 66) and mirror the
MCP envelope's `isError: true` + tool-error text for the same query
classes. The transcript on stdout is identical to what
`./.build/release/dictamac --mcp` would emit for a
`transcribe_voice_memo` call with the same query — the two transports
ride one `Transcriber` instance per invocation, so byte parity is
inherent rather than enforced.

## Out of scope

- Refactoring `runResolveAndTranscribe` to share more code with
  `runVoiceMemo` — deliberately kept separate for the reasons in "Why
  this shape" above. Issue can be filed if a third voice-memo entry
  point ever needs the same plumbing.
- The MCP `transcribe_voice_memo` handler itself — already wired in
  PR #54.
- Streaming partial transcripts as `SpeechTranscriber` produces them.
  The CLI still buffers the full transcript before writing stdout,
  matching `runResolveAndTranscribe`'s behaviour. Tracked in the
  PLAN.md "future work" notes.
