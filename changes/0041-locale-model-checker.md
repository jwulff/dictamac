# Add LocaleModelChecker seam with progress + exit-67 mapping

PR: TBD
Issues: Closes #15 (Refs #2)

## What changed

PR #40 landed a minimum-viable inline `ensureLocaleModelAvailable`
private static inside `DefaultTranscriber` so the analyzer could make
progress at all. That helper handled exactly two cases (install if
not installed, reserve unconditionally) and produced no operator
feedback. The first-run download takes multiple seconds with the
process producing zero output — indistinguishable from a hang to both
agents and humans.

This PR replaces the inline helper with a proper protocol-driven
seam:

- **`LocaleModelChecker` protocol** (`Sources/DictamacSpeech/LocaleModelChecker.swift`) —
  one `ensureModelAvailable(for:progress:)` method. Concrete
  implementations decide how to query installed status, trigger
  installs, and surface progress.
- **`LocaleModelProgressSink` value type** (same file) — a `Sendable`
  closure wrapper representing "where progress lines go." Production
  default `LocaleModelProgressSink.standardError` writes directly to
  `FileHandle.standardError`. Tests inject a capture sink.
- **`SpeechAPILocaleModelChecker`** (`Sources/DictamacSpeech/SpeechAPILocaleModelChecker.swift`) —
  the production implementation. Drives `AssetInventory.status(forModules:)`,
  `assetInstallationRequest(supporting:)` /
  `downloadAndInstall()`, and `AssetInventory.reserve(locale:)`. Emits
  `"Downloading speech model for <bcp47>…\n"` and
  `"Speech model installed.\n"` lines on the slow path, no output on
  the fast path. Every failure mode (network unreachable, API error,
  `.unsupported`, `@unknown default`, reservation cap exceeded) maps
  to `DictamacError.speechAnalyzerUnavailable(reason:)` → exit code 67
  with a tailored manual-install hint pointing at System Settings →
  Language & Region.
- **`DefaultTranscriber`** now constructor-injects an `any LocaleModelChecker`
  (defaulting to `SpeechAPILocaleModelChecker()`) and a progress sink
  (defaulting to `.standardError`). The inline `ensureLocaleModelAvailable`
  private static is deleted; `transcribe(_:)` calls into the injected
  checker before constructing the analyzer.

Tests:

- **`Tests/DictamacSpeechTests/Mocks/MockLocaleModelChecker.swift`** —
  actor-backed stub with `.success(emit:)` and `.throwError(_:)`
  outcomes, mirroring the `MockTranscriber` shape in `Tests/DictamacCoreTests/Mocks/`.
- **`Tests/DictamacSpeechTests/LocaleModelCheckerTests.swift`** —
  covers the protocol seam:
  - already-installed → no progress output
  - missing + download → progress lines wired through the sink, each
    newline-terminated
  - network unreachable / `.unsupported` / `@unknown default` /
    reservation failure → exit 67 with the documented substrings in
    the reason string
  - `DefaultTranscriber` surfaces a checker failure verbatim with
    exit code 67 (ordering test: checker runs before the analyzer)
  - file resolution still precedes the checker — a missing file
    short-circuits before the bootstrap is consulted
- **`Tests/DictamacSpeechTests/SpeechAPILocaleModelCheckerIntegrationTests.swift`** —
  pins the real `SpeechAPILocaleModelChecker` against the
  already-installed en-US fast path on the developer machine. Asserts
  zero progress lines emitted; the test's failure message points at
  the underlying precondition (run the binary once to trigger first
  install) so a regression-vs-precondition diagnosis is obvious.

## Why

This is the riskiest first-run UX problem in the speech track per
PLAN.md §9 risks table:

> "First-run locale model download looks like a hang | likelihood:
> high | Detect missing locale assets before transcribing; clear
> stderr message with progress; document the one-time cost"

Without the seam:

- An agent invoking `dictamac` against a fresh install sees no output
  for several seconds and is forced to guess whether the binary is
  wedged or doing work. Agent retry logic (timeouts, kills, etc.)
  then either gives up too early or papers over the actual failure
  mode.
- A human in the same situation has the same problem with worse
  patience.
- The previous helper had no offline-failure path at all; a missing
  model with no network would simply propagate whatever
  `downloadAndInstall()` threw, with no exit-code-67 mapping and no
  hint about how to recover.

The protocol seam also unlocks test coverage for the failure modes
that are otherwise impossible to exercise locally (you can't easily
simulate "no network" or "future SDK status" against a real
developer laptop with the model installed).

## How — runtime traps preserved

The most expensive trap from PR #40 is preserved verbatim in the
production checker:

- **`AssetInventory.reserve(locale:)` is MANDATORY.** Without the
  per-process reservation, `SpeechAnalyzer.analyzeSequence` hangs
  forever — the framework writes "Cannot use modules with unallocated
  locales" to the unified log but never throws, so the symptom is a
  silent hang. The previous comment block was the only documentation
  of this; it's now in the new file's type-level doc and the
  `ensureModelAvailable` body.
- **Reservation is idempotent and re-issued every invocation.** No
  state persists between invocations (CLAUDE.md invariant). A process
  that previously released the reservation cleanly re-acquires it on
  the next run.

## How — design choices worth flagging

- **Closure-backed `LocaleModelProgressSink`, not a protocol.** A
  `Sendable` closure is the lightest seam that satisfies the test +
  production cases (capture-into-actor in tests; direct stderr write
  in production). A full protocol would buy nothing the closure
  doesn't already provide; the callsite shape is `progress("line")`
  either way via `callAsFunction`.
- **The probe `SpeechTranscriber` is short-lived.** `AssetInventory.status(forModules:)`
  needs a `Module` instance, not a bare locale. The checker
  constructs a temporary `SpeechTranscriber` for the status query
  and discards it; the real transcriber that drives the analyzer is
  constructed downstream in `DefaultTranscriber.transcribe(_:)`. This
  keeps the protocol surface locale-based rather than module-based,
  which is what every caller wants.
- **Stdout discipline enforced by construction.** The progress sink
  is a value type with a `standardError` static accessor and no
  stdout convenience. There's no way to accidentally route progress
  output to stdout without writing your own sink — which would
  trigger code review.
- **Newlines are caller-responsibility.** The sink writes verbatim;
  the production checker appends `"\n"` itself. Tests assert each
  line is newline-terminated. This matches the byte-precise shape of
  `DictamacError.formattedStderrLine` (also `description + "\n"`).
- **File resolution precedes the bootstrap.** `transcribe(_:)`
  resolves the URL and opens the audio file before invoking the
  checker. A missing file short-circuits with exit 64 without ever
  touching `AssetInventory` — there's no point downloading a 100 MB
  speech model only to fail on the audio path. The
  `fileResolutionPrecedesModelBootstrap` test pins this ordering.

## Verified

- `swift build` clean, no new warnings.
- `swift test` passes 96 tests in 10 suites (~0.2s).
- Binary verification: `make build` → signed release binary →
  `.build/release/dictamac Tests/DictamacSpeechTests/Fixtures/hello-world.m4a`
  prints `Hello, world, this is a test.` on stdout, no stderr output,
  exits 0. PR #40's end-to-end behavior is preserved.
- `SpeechAPILocaleModelCheckerIntegrationTests.alreadyInstalledEnUSEmitsNoProgressAndDoesNotThrow`
  passes against the real `AssetInventory` on this developer machine,
  confirming the fast-path produces zero stderr noise.

## Follow-ups

- `--list-locales` (not in scope for #15) would let an operator query
  which locale models are installed without running a transcription.
  Worth filing if user feedback requests it.
- Periodic re-poll during long downloads (e.g.
  `"Downloading speech model for en-US… (15s elapsed)"`) would let an
  operator distinguish "still downloading" from "network stalled."
  `AssetInstallationRequest` does not currently expose progress
  callbacks via its public API; if Apple adds one in a future SDK,
  revisit.
- PLAN.md §7 U5's third critical runtime property bullet could be
  updated to point at this checker directly. Filed as a follow-up
  rather than landed here so this PR stays scoped to the
  implementation.
