# Discover Voice Memos library path

PR: #45
Issues: Closes #14 (Refs #4)

## What changed

A new SPM target `DictamacVoiceMemos` lands, scoped to one file for
now: `Sources/DictamacVoiceMemos/VoiceMemosLibraryLocator.swift`. It
exposes:

- `VoiceMemosLibraryLocator` protocol — `func locate() throws -> VoiceMemosLibraryLocation`
- `VoiceMemosLibraryLocation` value type carrying both the chosen URL
  and the full ordered `probedPaths` list (for diagnostics)
- `DefaultVoiceMemosLibraryLocator` — production implementation
- `DefaultVoiceMemosLibraryLocator.filesAndFoldersDeepLink` — the
  `Privacy_FilesAndFolders` System Settings URL embedded in
  `permissionDenied` errors

The locator probes two candidate paths under `$HOME`, in order:

1. `Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/`
   (modern macOS, iCloud-sync world)
2. `Library/Application Support/com.apple.voicememos/Recordings/`
   (older macOS / pre-iCloud)

Three failure modes resolve deterministically to `DictamacError` cases:

- **First existing readable candidate** → `VoiceMemosLibraryLocation`
- **No candidate exists** → `DictamacError.voiceMemoLibraryMissing(searched:)`
  (exit code 74) with both probed URLs in the array
- **A candidate exists but is unreadable** → `DictamacError.permissionDenied(domain: "Files & Folders", deepLink: …Privacy_FilesAndFolders)`
  (exit code 73). The deep-link goes verbatim into the formatted stderr
  line so a linkifying terminal lets the user grant access in one
  click.

`Package.swift` gains the `DictamacVoiceMemos` library target +
matching test target. The `DictamacCLI` library now depends on
`DictamacVoiceMemos` so future CLI handlers (`--list-voice-memos` in
issue #25, `--voice-memo` in #21/#22) can consume the locator without
re-plumbing the manifest.

Seven Swift Testing cases (`Tests/DictamacVoiceMemosTests/`) cover:

- both candidates present → Group Containers wins
- only Application Support present → fallback wins
- only Group Containers present → primary wins
- neither present → exit-74 with the full probe list
- Group Containers present but `chmod 000` → exit-73 with the
  Files & Folders deep-link embedded
- Application Support present but `chmod 000` → same exit-73 path
- default-init smoke test asserting candidate-path shape

Each fixture tears down deterministically — `chmod 700` restoration
runs before `removeItem` so the temp dir actually goes away even when a
test simulated a TCC denial.

## Why

This is the foundational locator for the Voice Memos epic. Everything
else in #4 (`CloudRecordings.db` reader, `*.m4a` fallback walker,
fuzzy/time-anchored query parser, `--list-voice-memos` JSON output,
MCP `transcribe_voice_memo`) needs a library directory URL to start
from. Until something hands that URL back, none of those issues are
even unblocked.

Voice Memos is sandboxed on macOS 26 and the library path moved with
the iCloud transition — different machines pick different paths
depending on history. A static "use this one path" wouldn't survive
beyond developer machines that happen to match.

The TCC angle is the **bigger** reason this needed a dedicated issue.
PLAN.md §9 calls out that agent-spawned processes may not surface the
Files & Folders UI prompt at all — the OS just returns `EPERM` and the
process has no way to ask the user. That makes the stderr deep-link
the **only** user escape hatch for the agent-driven path, which is
dictamac's primary consumer per CLAUDE.md. Surfacing the right URL
(`Privacy_FilesAndFolders`, **not** the Speech Recognition URL — those
two map to different exit-73 paths) is therefore high-stakes; a wrong
or missing link means an agent prints "permission denied" and the user
has no obvious next step.

PLAN.md §7 U6 specifies `Privacy_FilesAndFolders` and CLAUDE.md
mirrors it; the issue body mentioned `Privacy_AppBundles` as a maybe.
I went with `Privacy_FilesAndFolders` because:

1. Both PLAN.md and CLAUDE.md agree on it
2. `Privacy_AppBundles` opens a different System Settings pane (the
   one for individual app deep-links into per-app sandbox folders),
   not the Files & Folders TCC pane the locator's denial actually maps
   to
3. Apple's developer docs for `NSFileReadNoPermissionError` from a
   sandboxed source point users to the Files & Folders pane

Verified the URL string matches the existing convention used in
`DictamacError.permissionDenied(domain:deepLink:)` from PR #38 and
documented in CLAUDE.md "Required TCC permissions".

## How

A few decisions worth flagging:

- **`isReadable` is two checks, not one.** The detector calls
  `FileManager.isReadableFile(atPath:)` first (cheap, catches
  `chmod 000` which is how tests simulate denial), then
  `contentsOfDirectory(at:)` (catches real TCC denials where the
  kernel returns `EPERM` even when the POSIX permission bits look
  open — Apple's sandbox layer is invisible to `isReadableFile`).
  Either failing means "we can't list this directory." This is the
  trap the parent task warned about: `isReadableFile` alone would miss
  real TCC denials in production while still passing tests. Doing
  both is cheap and covers both cases.
- **`probedPaths` always returns the full list, even on success.**
  Costs nothing and lets `--verbose` callers print "tried A then B;
  chose B" without re-deriving the candidates. Issue #25's
  `--list-voice-memos` will probably surface this.
- **`homeProvider` is `@Sendable () -> URL`, defaulting to
  `NSHomeDirectory()`.** `URL(fileURLWithPath: NSHomeDirectory())`
  matches what the rest of the codebase uses (see `AudioFileResolver`'s
  tilde-expansion) and respects `$HOME` overrides in `swift test`
  runs, which keeps the smoke test deterministic across machines.
- **The locator is a `struct`, not a `class`.** No mutable state, no
  identity needed — just function-shaped behavior. Sendability is
  inferred from the `@Sendable` closure capture.
- **No `--list-voice-memos` wiring.** That's #25, which depends on
  the SQLite reader (#15? — TBD) and the `*.m4a` fallback. Wiring
  this into the CLI now would force the CLI to handle a half-built
  pipeline.

## Cross-PR coordination

Issue #18 (MCP stdio loop) lands in parallel and also edits
`Package.swift` to add a new SPM target (`DictamacMCP`). Whichever PR
merges first wins; the second rebases the manifest. The conflict is
mechanical — both PRs append to the `targets:` array without touching
each other's lines — so the resolution is to keep both target +
test-target stanzas. No semantic overlap: `DictamacVoiceMemos` depends
only on `DictamacCore` and is consumed by `DictamacCLI`; `DictamacMCP`
is a separate transport with no overlap.

## Follow-ups

- Issue #15-ish: a SQLite reader for `CloudRecordings.db` consuming a
  `VoiceMemosLibraryLocation.url`
- Issue #25: CLI `--list-voice-memos` mode wiring the locator into the
  CLI dispatch
- Issue #21/#22: query parser + `--voice-memo` resolve
- An optional second deep-link case for the Privacy Full Disk Access
  pane (`Privacy_AllFiles`) when we discover real-world TCC denials
  the Files & Folders prompt doesn't cover. Park for now; revisit when
  the first real-user denial reports come in.
- Consider lifting `Privacy_FilesAndFolders` (and the Speech
  Recognition URL) into a `TCCDomain` enum in `DictamacCore` once a
  third producer site appears. With only two call sites today the
  indirection adds no value; the open coding is fine.
