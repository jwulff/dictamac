# Add --list-voice-memos CLI mode with shared schema

PR: TBD
Issues: Closes #25 (Refs #4)

## What changed

The CLI `--list-voice-memos` mode is now real — replacing the
"not yet implemented" stub from #42. Five files in `Sources/` and
three test files cover:

- `Sources/DictamacVoiceMemos/DurationString.swift` — pure parser
  shared by `--since` (CLI) and `list_voice_memos.since` (MCP).
  Accepts shorthand (`7d`, `2w`, `1m`) and ISO dates (`YYYY-MM-DD`).
  Rejects empty input, unknown suffixes, malformed dates, and
  `0d` / `0w` / `0m`. Errors are typed (`DurationStringError`) so the
  CLI maps to exit 2 and the MCP transport (forthcoming) maps to
  JSON-RPC `-32602`.
- `Sources/DictamacVoiceMemos/VoiceMemoListing.swift` — agent-facing
  projection of `VoiceMemoMetadata` matching the
  `list_voice_memos` schema (PLAN.md §5):
  `{title, recordedAt, durationSeconds, identifier}`. Defining it
  once in the voice-memos target prevents the CLI and MCP transports
  from drifting on field set or key names.
- `Sources/DictamacVoiceMemos/VoiceMemosResolver.swift` — protocol
  + `VoiceMemoQuery` + `TimeAnchor` placeholder file with the real
  signatures. The `parse(_:)` body is a `fatalError` stub; issue
  #23 fills it in and adds `DefaultVoiceMemosResolver`. See the
  coordination note below.
- `Sources/DictamacCLI/ListVoiceMemosHandler.swift` — the testable
  handler seam parallel to `runResolveAndTranscribe(...)`. Parses
  `--since` via `DurationString` (default `30d`), clamps `--limit`
  to `[1, 100]` (default `30`), calls
  `VoiceMemosResolver.list(since:limit:)`, defensively re-sorts
  reverse-chronologically, and renders columnar plaintext or JSON.
  `writeStdout` / `writeStderr` / `exit` are injectable so tests
  drive it without touching `Darwin.exit(_:)`.
- `Sources/DictamacCLI/ProductionPlaceholderVoiceMemosResolver.swift`
  — a no-op `VoiceMemosResolver` that surfaces a structured exit-1
  error message pointing at issue #23. Used as the default factory
  in `ModeHandlers.production(...)` until #23's
  `DefaultVoiceMemosResolver` lands; the orchestrator deletes this
  file on the rebase.

Wiring:

- `Sources/DictamacCLI/ModeDispatch.swift` — replaces the
  `listVoiceMemos` stub with a real call to `runListVoiceMemos`,
  threading a `voiceMemosResolverFactory` closure (default: the
  placeholder).
- `Sources/DictamacCLI/StubMessages.swift` —
  `listVoiceMemosNotImplemented` constant deleted; the matching
  stub-handler test goes with it.
- `Package.swift` — `DictamacCLITests` gains a `DictamacVoiceMemos`
  dependency so the handler tests can import `VoiceMemosResolver`
  and friends.

Tests (35 new cases):

- `Tests/DictamacVoiceMemosTests/DurationStringTests.swift` — 18
  cases pinning every shorthand + ISO + invalid-input branch and
  the relative-date math for each unit.
- `Tests/DictamacVoiceMemosTests/VoiceMemoListingTests.swift` — 3
  cases pinning the `init(from:)` projection and the JSON wire
  shape against the MCP `list_voice_memos` schema.
- `Tests/DictamacCLITests/ListVoiceMemosHandlerTests.swift` — 14
  cases covering plaintext output (columnar, tab-separated,
  reverse-chronological, defensive re-sort), JSON output (array
  shape decodable back into `[VoiceMemoListing]`), empty results
  (exit 0 with no body / `[]` for JSON), `--since` parsing
  (defaults to `30d`, invalid → exit 2), `--limit` clamping (`[1,
  100]`), and resolver-error pass-through (permission-denied →
  exit 73, library-missing → exit 74).
- `Tests/DictamacCLITests/Mocks/MockVoiceMemosResolver.swift` —
  lock-guarded final class mock that records each
  `list(since:limit:)` call so the handler tests can assert what
  parameters the handler computed.

Total: 285 tests across 27 suites, up from 251.

## Why

`--list-voice-memos` is the discovery surface — agents (and humans
piping to `awk -F'\t'`) list memos in reverse-chronological order
with their titles, dates, durations, and identifiers, then feed an
identifier back into `--voice-memo` or
`transcribe_voice_memo.query`. The same metadata shape powers the
MCP `list_voice_memos` tool. The schema is defined once in
`DictamacVoiceMemos` so the two transports cannot drift.

## Design notes

### Tab-separated plaintext columns

The plaintext output is `identifier <tab> recordedAt-ISO8601
<tab> durationSeconds <tab> title`, one line per memo, with a
trailing newline after the last line (empty body for zero
results). Tabs (rather than spaces or pipes) let agents pipe the
output into `awk -F'\t'` without escaping the delimiter inside
multi-word titles. Tabs / newlines inside titles are sanitized
to spaces so each row stays parseable.

### `1m` is approximate

`1m` resolves to exactly 30 days because calendar arithmetic
against a wall-clock month is timezone- and DST-sensitive, and
the `--since` filter only needs to be "roughly a month back".
Users who need calendar-exact months should pass an ISO date.
This is documented in `DurationString.swift`.

### Defensive sort in the handler

The resolver protocol documents that `list(since:limit:)` returns
reverse-chronological order, but the CLI re-sorts before
rendering. A silent contract violation in the resolver shouldn't
produce a user-visible bug — the cost of a second sort over ≤100
elements is negligible.

### `since`-as-text plumbed all the way through to the handler

`Mode.listVoiceMemos(since:limit:)` carries the raw `--since`
string verbatim from the parser to the handler. Parsing happens
in `runListVoiceMemos`, not in `Dictamac.resolveMode()`, so
invalid `--since` values produce the same `argumentError`-shaped
exit-2 message regardless of whether they slipped past the
parser's mutual-exclusivity check.

## Parallel agent coordination (#23)

Agent M is implementing issue #23 (`DefaultVoiceMemosResolver`
+ the real `VoiceMemoQuery.parse(_:)` body) in parallel. Both
agents produce a byte-identical
`Sources/DictamacVoiceMemos/VoiceMemosResolver.swift` placeholder
file so the merge of whichever PR lands second is trivial:

- This PR (#25) ships the placeholder with `parse(_:)` =
  `fatalError(...)` plus the protocol shape + `TimeAnchor` /
  `VoiceMemoQuery` enums, then wires the CLI handler against the
  protocol using a placeholder resolver
  (`ProductionPlaceholderVoiceMemosResolver`) that surfaces a
  structured exit-1 error.
- Agent M's PR (#23) ships the same file with the real
  `parse(_:)` body, plus `DefaultVoiceMemosResolver` and its
  tests.

On second-PR merge the orchestrator:

1. Keeps the contract file from whichever PR landed first (they
   are byte-identical, so the merge is a no-op).
2. Drops `ProductionPlaceholderVoiceMemosResolver.swift` and the
   `voiceMemosResolverFactory:` default in
   `ModeHandlers.production(...)`, replacing it with a direct
   `DefaultVoiceMemosResolver(...)` construction.

The `voiceMemosResolverFactory` parameter on
`ModeHandlers.production(...)` is the rebase seam — it lets the
orchestrator wire the real resolver without touching the handler
implementation or the dispatch boundary.

## E2E check

Local run on this host (no `DefaultVoiceMemosResolver` wired
yet):

```
$ ./.build/release/dictamac --list-voice-memos --since 7d --limit 3
EXIT=1  STDERR=Internal failure: DefaultVoiceMemosResolver not
yet wired — see issue #23 (Voice Memos resolver).
$ ./.build/release/dictamac --list-voice-memos --since garbage
EXIT=2  STDERR=Argument error: --since: unrecognized duration:
"garbage" — expected shorthand like 7d / 2w / 1m or an ISO date
(YYYY-MM-DD)
```

The full end-to-end (real resolver lists real memos) flow lights
up once #23 lands and the orchestrator rebases the factory.

## Out of scope

- `DefaultVoiceMemosResolver` + `VoiceMemoQuery.parse(_:)` body —
  issue #23.
- The MCP `list_voice_memos` tool wiring — that's epic #5; this
  issue only delivers the CLI mode + the shared `VoiceMemoListing`
  / `DurationString` shapes the MCP epic will import.
- Pagination beyond `--limit` — out of scope for v0.2.
