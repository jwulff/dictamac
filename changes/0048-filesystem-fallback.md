# Add filesystem fallback for Voice Memos

PR: TBD
Issues: Closes #20 (Refs #4)

## What changed

Two new files in `Sources/DictamacVoiceMemos/` and one test file
exercise a resilience seam for the Voice Memos epic:

- `VoiceMemoMetadata` — the shared shape returned by both the
  CloudRecordings SQLite reader (issue #17, landing in parallel) and
  this scanner. Five fields: `identifier`, `title`, `recordedAt`,
  `durationSeconds`, `assetPath`.
- `FilesystemRecordingsScanner` protocol +
  `DefaultFilesystemRecordingsScanner` implementation — walks a Voice
  Memos library directory non-recursively, opens each `*.m4a` via
  `AVAudioFile`, and surfaces one `VoiceMemoMetadata` per asset.
- 8 Swift Testing cases covering empty directories, xattr probe
  precedence, corrupt-file skipping, `.icloud` placeholder skipping,
  and the don't-throw-on-per-entry-failure invariant.

## Why

`docs/PLAN.md` §9 calls out `CloudRecordings.db schema changes in
macOS 27` as the most likely Voice Memos resilience break. The
filesystem scanner is the documented fallback: when the private SQLite
schema drifts (or the database is locked, or the file is missing
entirely), the scanner still surfaces every `.m4a` Voice Memos has
written. The trade-off is fidelity — we lose Apple-curated titles and
the canonical `recordedAt` timestamp — but the user keeps a working
`list_voice_memos` and `--voice-memo` flow until we ship a schema
update.

This issue ships the scanner; the merge/preference logic (which
prefers SQLite when present and falls back to the filesystem
otherwise) is scoped to a separate issue (#25-ish) and not part of
this PR.

## How

A few decisions worth flagging:

- **`recordedAt` probe order is xattr → `creationDate` →
  `contentModificationDate` → Unix epoch.** The xattr
  `com.apple.metadata:kMDItemContentCreationDate` is what Spotlight
  ingests and what Voice Memos sets on save — the closest thing to a
  "real" recording timestamp on disk. The filesystem dates are
  defensive fallbacks for assets Voice Memos didn't write (e.g. user
  drag-and-drop) or where the xattr was stripped by a file-transfer
  tool that doesn't preserve them. The Unix-epoch sentinel is exotic
  but keeps `recordedAtDate(for:)` total.
- **Title probe is xattr → filename stem.** Same rationale —
  `com.apple.metadata:kMDItemTitle` is what Voice Memos sets when the
  user renames a recording in-app; the filename stem (`New Recording
  42`) is the inert default.
- **`getxattr(2)` returning `-1` is not an error.** Missing xattr is
  the normal case (`errno == ENOATTR`) and the wrapper returns `nil`
  silently. The `PropertyListSerialization` decode is the only
  step that surfaces a "this xattr is malformed" signal — and even
  then we fall back rather than throw, because one weird xattr on one
  asset should never abort the whole scan.
- **Per-entry failures never abort the scan.** If
  `AVAudioFile(forReading:)` throws (zero-byte placeholder, unsupported
  codec, corrupt container), the scanner skips that entry, fires the
  injected `diagnosticSink` with a short warning, and continues with
  the remaining files. The `diagnosticSink` defaults to `nil` (silent
  skip); the CLI caller will wire it to `stderr` only under `--verbose`
  so stdout discipline is preserved.
- **Sorted output by path.** Directory enumeration order is
  filesystem-dependent (HFS+ vs APFS), so the scanner sorts results by
  path for deterministic test assertions and stable diagnostics.
- **`.icloud` placeholders are silently skipped.** Reading them would
  normally trigger an iCloud Files Provider download; the scanner
  declines to do that and filters by extension instead. iCloud
  download orchestration is out of scope for the epic (#4) — revisit
  when a user reports a real eviction. The doc-comment is the
  canonical record.
- **Recursion behavior is documented as "no".** Voice Memos as of
  macOS 26 writes all `.m4a` assets flat at the top of `Recordings/`.
  If a future macOS release nests by date, this changes; the doc
  comment is where that decision lives.

## Test strategy

The tests touch the real filesystem in a unique temp directory per
test, rather than mocking the file APIs. The xattr probe order and the
per-entry don't-throw invariant are filesystem-level behaviors, so a
mock would defeat the test's purpose (CLAUDE.md "Debugging Discipline
§2"). Fixtures are synthesized at runtime — 50ms of silent AAC-in-M4A
via `AVAssetWriter`, mirroring the pattern in
`Tests/DictamacCoreTests/AudioFileResolverTests.swift`. No real
recordings, no PII.

`setxattr(2)` is the test-only path to fake the Spotlight metadata
Voice Memos would normally set. A small helper writes a binary plist
into the xattr value to mirror what `PropertyListSerialization`
expects on read.

## Cross-PR coordination

The parallel agent on issue #17 produces a byte-identical
`Sources/DictamacVoiceMemos/VoiceMemoMetadata.swift` from the same
contract specified in the orchestrator prompt. Whichever PR merges
first wins; the second rebases trivially (the file is identical). If
the shape ever needs to change, the change goes in a separate PR so
both producers can pick it up in lockstep.

## Follow-ups

- Issue #17 (in flight): `CloudRecordingsReader` consuming the same
  `VoiceMemoMetadata` shape.
- Issue #25 (queued): merge/preference layer that prefers SQLite and
  falls back to filesystem, plus the `--list-voice-memos` CLI flag.
- An optional iCloud-download integration when a real user reports an
  evicted recording they need transcribed.
