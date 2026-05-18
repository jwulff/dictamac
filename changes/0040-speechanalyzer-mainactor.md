# Wrap SpeechAnalyzer with MainActor lifecycle

PR: #40
Issues: Closes #19 (Refs #2)

## What changed

The on-device transcription core finally lands. Three things ship as
a set because they only make sense together:

- A new SPM target `DictamacSpeech` joins the package; it depends on
  `DictamacCore` and is imported by the `dictamac` executable.
- `DefaultTranscriber` (in `Sources/DictamacSpeech/`) implements the
  `Transcriber` protocol from PR #34. It wraps macOS 26's
  `SpeechAnalyzer` / `SpeechTranscriber` and pumps a file URL through
  the analyzer lifecycle, producing a populated `Transcript` with
  per-segment time ranges.
- The CLI entry point in `Sources/dictamac/main.swift` becomes a
  `ParsableCommand` (NOT `AsyncParsableCommand`) that hands work to a
  detached `Task {}` and then parks the process on `dispatchMain()`.
  The Task calls `Darwin.exit(_:)` once the transcript is rendered.

Two tests land:

- `DefaultTranscriberTests` — unit tests that don't touch the
  analyzer (existential conformance, missing-file error, contract on
  the model identifier string).
- `DefaultTranscriberIntegrationTests` — exercises the real analyzer
  end-to-end against a tiny synthesized `.m4a` fixture
  (`hello-world.m4a`, generated with `say` + `afconvert`, ~14 KB, no
  real speech). Asserts the transcript contains "hello" and "world"
  case-insensitively to tolerate per-run model variance.

## Why

This is the actual on-device transcription. Every formatter and audio
loader that landed before it (PRs #34–#37) is plumbing whose only
reason to exist is to feed this implementation. Once `DefaultTranscriber`
is wired into the CLI surface, `dictamac path/to/audio.m4a` produces
a transcript on stdout — the headline behavior the project exists to
deliver.

The `SpeechAnalyzer` API has strict runtime requirements. Getting
them wrong silently hangs the process or crashes it with `SIGTRAP`
deep inside Apple code. We codify the proven pattern from sibling
project [steno](https://github.com/jwulff/steno) here so future
contributors don't pay the cost of rediscovering them.

## How — runtime traps codified

1. **`SpeechAnalyzer.start` / `analyzeSequence` MUST run on
   `@MainActor`.** Off the main actor, the framework crashes with
   `SIGTRAP`. `DefaultTranscriber.runAnalyzerLifecycle` hops onto
   `@MainActor` via `Task { @MainActor in … }.value` before touching
   the analyzer. This is the single most important line in the file;
   moving the call out of the `@MainActor` closure breaks
   transcription regardless of how the call is reached.

2. **The main RunLoop must be alive for results to be delivered.**
   The CLI entry point uses `ParsableCommand` (NOT
   `AsyncParsableCommand`) and calls `dispatchMain()` after launching
   the async transcription in a `Task {}`. The Task itself calls
   `Darwin.exit(_:)` once it has produced output (or failed) — there
   is no path that returns from `dispatchMain()`. `AsyncParsableCommand`
   combined with `dispatchMain()` also crashes; this is the steno
   project's hard-won lesson.

3. **Ad-hoc signing with the right entitlements is mandatory at
   runtime.** The packaging epic landed signing in PR #29
   (`disable-library-validation`, `allow-jit`). `swift run` skips
   signing and the binary hangs on first analyzer touch; always go
   through `make build` → signed binary. **Do NOT add
   `com.apple.developer.speech-recognition`** — it's a restricted
   entitlement requiring a provisioning profile, which CLI binaries
   can't embed, so AMFI will SIGKILL the binary. The current
   entitlements file is correct as-is.

## How — implementation notes worth flagging

- **`async let analyzed` for the analyzer drive.** Result iteration
  has to start before `analyzeSequence` / `finalizeAndFinish` finish
  because the analyzer's lifecycle methods can block until results
  are drained. Structured concurrency (`async let` + the for-await
  loop on the same task) keeps the two children scoped to the
  transcribe call; if either throws, both unwind cleanly without
  leaking a child task.

- **`finalizeAndFinishThroughEndOfInput()`, not `(through:
  .positiveInfinity)`.** PLAN.md §7 U5's sketch uses
  `finalizeAndFinish(through: .greatestFiniteMagnitude)`. In
  practice on macOS 26.3 the `(through:)` variant hangs forever for
  any time later than the analyzed audio — the framework appears to
  wait for input it will never receive. The end-of-input variant
  returns promptly once the analyzer has emitted its final results
  for the file we already passed via `analyzeSequence(from:)`.
  Steno's `stop()` path uses the same variant for its live path,
  which was the missing data point. PLAN.md should be updated to
  reflect the corrected pattern (filed as a follow-up).

- **Locale model must be both installed AND reserved.** Before
  driving the analyzer, the transcriber checks
  `AssetInventory.status(forModules: [transcriber])` and:
  - if `.supported` / `.downloading`, calls
    `assetInstallationRequest(supporting:)` →
    `downloadAndInstall()` to materialize the model;
  - calls `AssetInventory.reserve(locale:)` unconditionally to
    allocate a per-process slot.
  Without reservation the analyzer silently hangs and the Speech
  framework writes "Cannot use modules with unallocated locales"
  to the unified log but never throws. The downloaded-but-unreserved
  symptom is identical to the missing-model symptom — both manifest
  as a hung process. Issue #15 will replace this minimum-viable
  bootstrap with proper progress reporting and the exit-code-67
  offline-failure path.

- **Segment timing comes from `result.range: CMTimeRange`, not the
  AttributedString's `.audioTimeRange` attribute.** Per-character
  audio time ranges live in the AttributedString and are useful for
  fine-grained alignment (e.g. word-level highlighting), but the
  segment-level start/end we need for the v1 JSON schema is the
  outer `result.range`. We still pass `attributeOptions:
  [.audioTimeRange]` to the transcriber so the attribute is
  available downstream when future features (word timing in
  `--json`, future SRT/VTT output) want it.

- **Confidence is always `nil` for now.** `SpeechTranscriber.Result`
  on macOS 26 does not expose a per-segment confidence scalar in the
  public API. PLAN.md §6 explicitly handles the absent-confidence
  case ("treat absence as unknown") — `JSONFormatter` omits the key
  rather than emitting `null`. If a future SDK version surfaces
  confidence (or a per-character attribute we can aggregate), we
  populate it then.

- **Zero force unwraps.** Every optional is handled explicitly. Audio
  file open, CMTime → seconds conversion (`isNumeric`/`isFinite`
  guards), duration fallback chain (analyzed end → file frames →
  last segment end → 0), JSON encode errors propagated upstream —
  all explicit. Per the "Debugging Discipline" #3 rule in
  `CLAUDE.md`.

- **`Bundle.module` resource path for the fixture.** The fixture
  lives at `Tests/DictamacSpeechTests/Fixtures/hello-world.m4a` and
  is wired into the test bundle through SPM's
  `resources: [.copy("Fixtures")]` declaration. SPM resources must
  be inside the target's path, so the single source of truth is the
  test target; the end-to-end binary verification command in the PR
  description references the same path.

## Verified

- `swift build` clean, no warnings (except the pre-existing
  `CustomStringConvertible` always-succeeds warning in `DictamacError`
  — not touched by this PR).
- `swift test --filter DefaultTranscriberTests` passes 3 unit tests
  in well under a second.
- Binary verification: `make build` signs the release binary, then
  `.build/release/dictamac Tests/DictamacSpeechTests/Fixtures/hello-world.m4a`
  prints a plaintext transcript containing "hello" and "world" and
  exits 0. The PR description carries the exact transcript captured
  during verification.
- `DefaultTranscriberIntegrationTests` is structured to run via
  `swift test` on a host with the en-US speech model installed and
  the test runner granted Speech Recognition TCC permission. If the
  test runner can't satisfy those, the binary verification path is
  the canonical proof per the issue's acceptance criteria ("verified
  by an end-to-end run of the binary against the test fixture, not
  just a unit test").

## Follow-ups

- #15 — locale model detection (orthogonal; surfaces exit code 67
  when the model isn't installed, before the analyzer hangs)
- #13 — full CLI surface (the current `dictamac` command is the
  minimum needed for this issue's end-to-end verification; the
  proper argument parser with subcommands and `--mcp` / `--json` /
  `--voice-memo` ships under that issue)
- Confidence extraction: revisit when Apple exposes a per-segment
  confidence value in a future macOS / Speech SDK update
