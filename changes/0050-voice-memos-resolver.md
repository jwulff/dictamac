# Parse and resolve Voice Memo queries

PR: #50
Issues: Closes #23 (Refs #4)

## What changed

Three new files in `Sources/DictamacVoiceMemos/` and two new test
files plus three mocks compose the per-issue orchestration layer for
Voice Memos:

- `VoiceMemosResolver.swift` — declares `TimeAnchor`, `VoiceMemoQuery`
  (with the `parse(_:)` classifier), and the `VoiceMemosResolver`
  protocol. The file follows a byte-identical contract shared with the
  parallel agent on issue #25 so the CLI `--list-voice-memos` PR
  rebases cleanly.
- `DefaultVoiceMemosResolver.swift` — production implementation that
  combines the library locator (#14), the SQLite reader (#17), and the
  filesystem scanner (#20) into a single query-aware resolver. Falls
  back from SQLite to filesystem on any `CloudRecordingsError`,
  emitting an optional `diagnosticSink` message so `--verbose` users
  can see why the optimized path didn't fire.
- `VoiceMemoQueryTests.swift` + `DefaultVoiceMemosResolverTests.swift`
  — 35 Swift Testing cases covering the parser branches, every query
  form, every fallback path, library-locator error propagation, and
  the `list(since:limit:)` shape.
- Three test-only mocks under `Tests/DictamacVoiceMemosTests/Mocks/`
  for the library locator, SQLite reader, and filesystem scanner.

## Why

The query grammar is the user-facing API for selecting a Voice Memo —
it powers BOTH the CLI `--voice-memo <query>` flag AND the MCP
`transcribe_voice_memo.query` tool input. The resolver lives in
`DictamacVoiceMemos` so both transports depend on the same parser and
the same orchestration; behaviour drift between CLI and MCP is a hard
non-goal (PLAN.md §3 "thin shells over the same core").

The orchestration is also where the SQLite-vs-filesystem precedence
rule lives: the SQLite reader (#17) is the optimized path, the
filesystem scanner (#20) is the resilience plan documented in
PLAN.md §9 ("CloudRecordings.db schema changes in macOS 27"). This PR
wires them together for the first time.

## How

A few decisions worth flagging:

- **Identifier shape detection uses two anchored regexes.** A canonical
  UUID (`8-4-4-4-12` hex, case-insensitive) or an all-digits string
  (matching SQLite `Z_PK` stringified primary keys) classifies as
  `.identifier`. Anything else falls through to `.fuzzyTitle`. The
  patterns are anchored — `2026-05-12-extra` is NOT a UUID and NOT
  a date, so it falls through to fuzzy intentionally.
- **Identifier miss falls back to fuzzy.** If the user types
  `--voice-memo 42` and no memo has identifier `42`, the resolver
  re-runs the same input as a fuzzy-title search. Documented in the
  `.identifier` case of `resolve(_:now:)` so CLI users typing a
  half-remembered identifier still land somewhere useful.
- **Half-open day ranges using `Calendar.current.startOfDay` +
  `Calendar.date(byAdding: .day, value: 1, to:)`.** This handles DST
  transitions correctly (24h days collapse to 23 or 25 hours twice a
  year). Using a flat 86_400-second offset would be off-by-one on
  those days. The `this morning` anchor uses `[00:00, 12:00)` per
  PLAN.md §7 U6 and the issue brief — a memo recorded at exactly noon
  is excluded, matching the explicit half-open interval semantics.
- **Tie-break is `max(by: recordedAt <)`.** Every query form that can
  match more than one memo (time anchors, ISO date, fuzzy title)
  resolves to the most recent. Stable secondary ordering beyond the
  timestamp is unspecified — `ZDATE` is sub-second so collisions are
  vanishingly rare in practice.
- **All `CloudRecordingsError` cases trigger filesystem fallback.**
  `sqliteUnavailable` (no DB file) and `schemaUnrecognized` (Apple
  changed the schema) are the documented falls; `sqliteOperationFailed`
  (corrupt headers, lock contention, mid-write reads) is treated the
  same. A corrupt-or-locked DB is operationally indistinguishable from
  "missing" for our purposes — the user still gets results.
- **Whitespace normalization on the fuzzy substring compare.** Per
  CLAUDE.md and the issue brief: trim outer whitespace, lowercase, and
  collapse internal whitespace before substring match. A query of
  `"standup   notes"` (with stray internal spaces) still finds a memo
  titled `"Standup notes"`.
- **`now` is injected through every date-sensitive code path.** The
  resolver never reads `Date()` internally; the caller passes `now` to
  `resolve(_:now:)` and the test suite uses a fixed 2026-05-12 14:30
  reference instant. This is the only way the time-anchor tests stay
  green across timezones and DST transitions.
- **`list(since:limit:)` short-circuits on `limit <= 0`.** A
  non-positive limit is meaningless; we return `[]` instead of relying
  on `Array.prefix`'s clamping behaviour. Documented in the function
  body.

## Test strategy

The tests use test-only mocks for the locator, SQLite reader, and
filesystem scanner — no real `~/Library/...` access, no real
`CloudRecordings.db`. The mocks live in
`Tests/DictamacVoiceMemosTests/Mocks/` per CLAUDE.md's "Mocks live in
`Tests/.../Mocks/`" rule. Each mock is `Sendable` and either always
succeeds with canned data or always throws a canned error — enough to
exercise every code path in the resolver without scripting multi-call
behaviour.

The reference instant is `2026-05-12 14:30:00 system-timezone`, built
through `Calendar.current` so the assertions agree with the
production code's calendar arithmetic regardless of where the test
runs.

## Cross-PR coordination

The parallel agent on issue #25 (`--list-voice-memos` CLI mode)
produces a byte-identical `VoiceMemosResolver.swift` from the same
contract specified in the orchestrator prompt. Whichever PR merges
first wins; the second rebases trivially because the protocol/enum
file is identical between agents. The `parse(_:)` body is identical
on both sides (same algorithm spec); the `DefaultVoiceMemosResolver`
implementation is exclusive to this PR (only this issue's brief
specifies its shape).

## Follow-ups

- Issue #25 (queued): wire the resolver into the CLI's
  `--voice-memo` and `--list-voice-memos` modes.
- Issue #26 (queued): wire the resolver into the MCP
  `transcribe_voice_memo` and `list_voice_memos` tools.
- The fuzzy ranker is intentionally simple — case-insensitive
  substring + recency tie-break. A future v0.3 issue can add
  tokenisation, prefix scoring, or fuzzy-distance metrics if the
  shipped behaviour proves insufficient.
