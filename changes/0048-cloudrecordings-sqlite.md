# Read CloudRecordings.db SQLite metadata

PR: #48
Issues: Closes #17 (Refs #4)

## What changed

Three new files in `Sources/DictamacVoiceMemos/`:

- `VoiceMemoMetadata.swift` — shared value type returned by both this
  reader and the filesystem fallback scanner (issue #20). Five fields:
  `identifier`, `title`, `recordedAt`, `durationSeconds`, `assetPath`.
- `CloudRecordingsReader.swift` — `CloudRecordingsReader` protocol +
  `DefaultCloudRecordingsReader` production implementation. Opens
  `CloudRecordings.db` with `SQLITE_OPEN_READONLY` via the system
  `libsqlite3` (`import SQLite3`; no SPM dep). Projects the
  `ZCLOUDRECORDING` table by column name. Closes the handle via
  `defer` inside `recordings()` so each call is self-contained.
- `CloudRecordingsError.swift` — typed error enum with
  `sqliteUnavailable`, `sqliteOperationFailed(operation:code:reason:)`,
  `schemaUnrecognized`. These are caller-facing signals for the
  resolver to choose when to fall back to the filesystem scanner —
  deliberately NOT `DictamacError` cases (the resolver wraps these
  only if the filesystem path also fails).

15 Swift Testing cases in
`Tests/DictamacVoiceMemosTests/CloudRecordingsReaderTests.swift` cover:

- happy path: synthetic rows round-trip through `recordings()` with
  correct identifier, title, `recordedAt`, `durationSeconds`,
  `assetPath`
- missing file → `.sqliteUnavailable`
- present-but-empty database → empty array, no error
- column renamed (`ZDATE` → `ZRECORDEDAT`) → `.schemaUnrecognized`
- table renamed (`ZCLOUDRECORDING` → `ZRECORDING`) →
  `.schemaUnrecognized`
- error descriptions render the underlying reason verbatim
- relative vs absolute ZPATH resolution against the library URL
- skip behavior for rows with NULL/empty ZPATH, NULL ZDATE, NULL ZDURATION
- title fallback to filename stem when ZCUSTOMLABEL is NULL or empty
- garbage bytes at the database path surface as `sqliteOperationFailed`

Fixtures are synthesized at test time using `libsqlite3` directly
rather than committing a binary `.db` — this keeps the fixture builder
adjacent to the schema we assume and lets us scaffold drift variants
without committing multiple `.db` blobs. All fixture data is synthetic
(`test-recording-alpha`, paths under `/tmp/dictamac-synthetic/`); no
PII enters the repo per `CLAUDE.md` "Public Open Source Project".

## Why

`CloudRecordings.db` is the cheapest way to enumerate Voice Memos
metadata — title, creation date, duration, asset path — without
walking the filesystem and reading xattrs per-file. When it's present,
a single SQLite read returns the whole library; when it's absent or
the schema has drifted, the caller falls back to the filesystem
scanner (issue #20) without surfacing a user-visible error.

The key risk PLAN.md §9 calls out is that the schema is **private and
undocumented by Apple**. macOS 27 (or earlier) may rename `ZDATE`,
move the table, or restructure the projection entirely. The reader
treats this as expected, not exceptional: any missing column or
absent table throws `.schemaUnrecognized` with a precise reason
string, and the resolver (issue #23) silently falls back.

`schemaUnrecognized` and `sqliteUnavailable` being separate cases
matters because they have different operational meanings — "the file
doesn't exist" can happen on a fresh install (Voice Memos has never
been opened), while "the file exists but Apple changed the schema"
is a regression we'd want to know about via support channels. Keeping
them distinct lets future telemetry distinguish "this user just hasn't
used Voice Memos yet" from "we need to ship a fix."

## How

A few decisions worth flagging:

- **Schema warning is at the top of the file.** Required by issue #17
  acceptance criteria; also serves as a tripwire for future
  contributors reading the file cold. The warning explicitly points
  at the filesystem fallback as the resilience plan.
- **Table-existence probe runs before the projection prepare.** Using
  `SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?`
  with parameterized binding lets us emit a precise
  "expected table X not found" message instead of relying on SQLite's
  "no such table" string surfacing through `sqlite3_prepare_v2`. On
  failure of the actual projection, we also pattern-match the
  `sqlite3_errmsg` text for `no such column` / `no such table` so a
  column-rename surfaces as `schemaUnrecognized` rather than a
  generic `sqliteOpenFailed`.
- **Date conversion is explicit.** SQLite stores `NSDate` timestamps
  as seconds since `2001-01-01 00:00:00 UTC` (the Core Data epoch);
  the reader converts via `Date(timeIntervalSinceReferenceDate:)`.
  The same constant is repeated in the test fixture builder so the
  round-trip is exercised end-to-end.
- **Rows with empty/NULL paths are skipped silently.** A row with no
  `ZPATH` can't be resolved to an audio asset, so it's useless to the
  caller. Skipping rather than throwing matches the "treat SQLite as
  optimization" guidance — one bad row shouldn't poison an otherwise
  good library read.
- **Identifier is `Z_PK` as a string.** The protocol contract makes
  identifiers strings (Voice Memo filesystem entries will use the
  filename stem in #20); converting the SQLite integer PK preserves
  uniqueness without leaking the SQLite type through.
- **No `FileManager` injection.** Originally I tried injecting it to
  parallel the locator's style; Swift 6 strict concurrency rejects
  `FileManager` as `Sendable` so the class couldn't be `Sendable`.
  The reader just uses `FileManager.default.fileExists(atPath:)`
  directly — same pattern as the existing locator code.

## Schema verification

I did NOT verify column names against a live macOS 26
`CloudRecordings.db` for this PR — I relied on the assumptions
documented in `docs/PLAN.md` §7 U6 and the issue body
(`ZCLOUDRECORDING` table; `Z_PK`, `ZCUSTOMLABEL`, `ZDATE`,
`ZDURATION`, `ZPATH` columns). The fallback path (issue #20) is the
backstop if any of these are wrong on real macOS 26 installs.

Follow-up worth filing: a one-shot script to dump the real schema
from a live `CloudRecordings.db` and compare against
`expectedTableName` / `ExpectedColumns`. The schema-drift test
fixtures already simulate the failure mode, but a real schema dump
would let us pre-empt actual drift.

## Cross-PR coordination

Agent J is working issue #20 (filesystem fallback scanner) in
parallel and will produce a **byte-identical** copy of
`Sources/DictamacVoiceMemos/VoiceMemoMetadata.swift`. The exact text
was coordinated up-front; second-to-merge rebases the file as a
trivial keep-either-version pick.

Agent H is working issue #22 (MCP) in parallel, exclusively in
`Sources/DictamacMCP/` — no overlap with this PR's files.

`Package.swift` is unchanged: `DictamacVoiceMemos` already exists as
an SPM target (from PR #45) and `import SQLite3` is provided by the
system without an additional dependency.

## Follow-ups

- Issue #20: filesystem fallback scanner consuming the same
  `VoiceMemoMetadata` shape
- Issue #23 (resolver): orchestrate "try SQLite, catch any
  `CloudRecordingsError`, fall back to filesystem scanner"
- Schema-dump utility to verify the assumed column names against a
  live macOS 26 database (research issue)

## Review round 2 (post-ZPATH fix)

Copilot's second pass surfaced two substantive issues and a handful of
test-gap nits. Resolved in this branch:

- **NULL `ZDATE` / `ZDURATION` poisoning the index.**
  `sqlite3_column_double` returns `0.0` for `NULL` columns with no way
  to distinguish that from a real zero. A row with NULL `ZDATE` would
  silently be reported as recorded at the Core Data epoch
  (`2001-01-01`), poisoning recency ordering and any date filter;
  NULL `ZDURATION` would become a zero-length memo. The reader now
  calls `sqlite3_column_type` for both columns before reading and
  skips the row when either is `SQLITE_NULL`. Skipping mirrors the
  empty-`ZPATH` policy — partial metadata corrupts the index more
  than a missing entry, and SQLite is treated as an optimization that
  the filesystem scanner can always cover.
- **`sqliteOpenFailed` misused for prepare / bind / step failures.**
  The single case was being thrown for every SQLite primitive,
  conflating "couldn't open the file" with "couldn't prepare a query"
  or "row corruption during step." Renamed to
  `sqliteOperationFailed(operation: String, code: Int32, reason: String)`
  carrying the failing primitive's name and the raw SQLite result
  code. Diagnostics now read e.g. "CloudRecordings SQLite
  sqlite3_prepare_v2 failed (code 1): ..." instead of a misleading
  "open failed." All four primitives (`sqlite3_open_v2`,
  `sqlite3_prepare_v2`, `sqlite3_bind_text`, `sqlite3_step`) report
  through the one case with distinct `operation` strings.
- **Unused `referenceEpoch` constant removed.** Dead since the date
  conversion uses `Date(timeIntervalSinceReferenceDate:)` directly.
- **Test fixture teardown.** Each test now wraps fixture creation in
  a `Fixture` value with a `tearDown()` method called from a `defer`,
  mirroring the locator tests. Removes the `dictamac-cloudrecordings-fixture-*`
  leak under `NSTemporaryDirectory()` per run.
- **New test coverage** pins the behaviors above end-to-end:
  - `rowWithEmptyZPathIsSkipped`, `rowWithNullZPathIsSkipped` —
    skip policy for unusable paths.
  - `rowWithNullZDateIsSkipped`, `rowWithNullZDurationIsSkipped` —
    skip policy for NULL numerics that would otherwise fabricate
    metadata.
  - `titleFallsBackToFilenameStemWhenZCustomLabelIsNull` /
    `...IsEmpty` — title fallback covered for both NULL and empty
    `ZCUSTOMLABEL`.
  - `garbageBytesAtDatabaseURLThrowsSqliteOperationFailed` —
    `sqliteOperationFailed` is now exercised end-to-end by pointing
    the reader at 128 bytes of non-SQLite content.
  - `errorDescriptionsAreHumanReadable` updated to assert the new
    case's rendering includes operation name, code, and reason.
