---
title: "feat: Long-form transcription — JSONL streaming + time windowing"
type: feat
status: active
date: 2026-05-13
deepened: 2026-05-13
origin: docs/brainstorms/long-form-transcription-requirements.md
---

# feat: Long-form transcription — JSONL streaming + time windowing

## Overview

Add two related capabilities so dictamac is usable on long recordings:

1. **Time windowing** (CLI + MCP) — transcribe only `[start, end)` of an input file.
2. **JSONL streaming** (CLI only) — emit each finalized SpeechAnalyzer segment as a typed JSONL line on stdout, so callers see progress immediately and can bail early.

Both ship in v0.2 alongside MCP. The brainstorm bundled them because they share a design surface (timestamp semantics, source schema, format coherence) and a single agent contract.

---

## Problem Frame

MVP returns the full transcript only after SpeechAnalyzer finishes processing the entire input. For a typical Voice Memo this is fine; for a 1–2 hour meeting recording it's a UX cliff — nothing on stdout for tens of minutes, no way to bail early, no way to sample a specific section without paying for the whole transcription. See `docs/brainstorms/long-form-transcription-requirements.md` for the full problem framing.

---

## Requirements Trace

All R-IDs trace to the origin requirements document.

**Streaming output (CLI only)**
- R1. `--stream` flag enables typed JSONL output; ignores `--json` if also passed.
- R2. Stream begins with a `header` line before audio processing produces segments.
- R3. Each finalized SpeechAnalyzer result is emitted as one `segment` line; stdout flushed per line.
- R4. Stream ends with an `end` line containing `segmentCount`, `elapsedMs`, `reason: "complete"`.
- R5. SIGINT triggers a graceful `end` line with `reason: "interrupted"` and exit 130.
- R6. Mid-stream errors emit one `error` line followed by an `end` line with `reason: "error"`.

**Time windowing (CLI + MCP)**
- R7. CLI: `--start <T>` and `--end <T>` accept time strings; window is half-open `[start, end)`.
- R8. MCP: `transcribe_file` and `transcribe_voice_memo` accept numeric `startSeconds` / `endSeconds`.
- R9. Emitted timestamps are file-relative; window only changes which segments are emitted, not how they are timestamped.

**Agent contract stability**
- R10. JSONL uses `type` discriminator: `header`, `segment`, `end`, `error`. Unknown types are forward-compatible.
- R11. Single-result JSON: unchanged when no windowing requested; with windowing, `durationSeconds` reflects window length and a `window: {startSeconds, endSeconds}` field is added at the top level.

**MCP boundaries**
- R12. MCP does not stream; windowed calls return one JSON result after completion.
- R13. MCP windowing validates `0 <= startSeconds < endSeconds <= durationSeconds` pre-flight; failure returns `isError: true` with no transcription work.

**Composition rules**
- R14. `--stream` composes with `--voice-memo`, stdin (`-`), and `--locale` without special cases.
- R15. `--stream`, `--start`, `--end` compose freely.

**Origin actors:** A1 (long-recording human), A2 (CLI-mode agent), A3 (MCP-mode agent).
**Origin flows:** F1 (live-tail), F2 (bail early via SIGINT), F3 (MCP windowed sample).
**Origin acceptance examples:** AE1 (covers R1–R4, R9), AE2 (covers R5, R6), AE3 (covers R7, R9, R11), AE4 (covers R8, R12, R13).

---

## Scope Boundaries

Carried from origin Scope Boundaries:

- Volatile/interim SpeechAnalyzer results are out. Only finalized segments stream.
- MCP streaming is out — no progress notifications, no chunked tool responses.
- Resumable / append-on-restart is out. Interrupted callers re-run with `--start`.
- SRT/VTT output is out for this feature.
- `--watch`, `--from <video>`, word-level timestamps, confidence-threshold filter — all out.
- Negative-offset end anchors (`--end -30`) are out. Forward-counting only.

### Deferred to Follow-Up Work

- **First-run locale model download UX** (already a PLAN.md §9 risk). The streaming `header` line gives us a clean hook to surface this — but the user-facing "downloading model… X%" stream is out of scope for v0.2 and tracked separately.

---

## Context & Research

### Relevant Code and Patterns

- `docs/PLAN.md` §5 — SpeechAnalyzer pipeline blueprint. The pseudocode there shows the unwindowed path (`analyzer.analyzeSequence(from: url)`) that this plan extends.
- `docs/PLAN.md` §4 — CLI surface (mutual-exclusivity rules for inputs and modes). New flags must respect these.
- `docs/PLAN.md` §6 — Existing JSON schema. Streaming JSONL and the new `window` field must remain coherent with this.
- `docs/PLAN.md` §8 — Phasing. This plan updates v0.2 / v0.3 entries.
- `docs/PLAN.md` §9 — Risk table. Add streaming-specific risks.
- Sibling project [steno](https://github.com/jwulff/steno):
  - `daemon/Sources/StenoDaemon/Engine/DefaultSpeechRecognizerFactory.swift` — analyzer lifecycle on `@MainActor`.
  - `daemon/Sources/StenoDaemon/Speech/SpeechRecognitionService.swift` — `for try await result in transcriber.results` pattern. Streaming reuses this directly — each loop iteration becomes one JSONL line emission.
  - The live-capture buffer-pump path (manual `AVAudioConverter` + `analyzer.start(input:)`) — the bounded-analysis path here mirrors it.

### Institutional Learnings

- None — `docs/solutions/` does not exist yet. Capture learnings during implementation.

### External References

- Apple — [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer), [SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber). Verify whether `analyzeSequence` accepts a time-range parameter directly during U2; if not, fall back to the manual buffer-feed path.
- [MCP specification](https://modelcontextprotocol.io/specification) — confirms `tools/call` is request/response. No streaming variant is in scope for this plan.

---

## Key Technical Decisions

- **One TranscriptionRequest carries an optional `AudioWindow`.** Both CLI and MCP populate the same struct, so the windowing semantics resolve in one place (the Speech layer), not in two transports.
- **`AudioWindow == nil` keeps the v0.1 fast path.** Whole-file transcription continues to use `analyzer.analyzeSequence(from: url)`. The manual buffer-feed path only runs when a window is set. This avoids regressing the simple case.
- **One `SpeechAnalyzer` instance per `TranscriptionRequest`, never reused across modes or requests.** `analyzeSequence(from:)` and `start(input:)` are not interchangeable on a single analyzer lifecycle. `TranscriberDriver.transcribe(request:)` constructs a fresh analyzer per call. An implementer reading this plan alongside the steno daemon (which holds a long-lived analyzer for live capture) should not hoist the analyzer into a shared singleton.
- **Buffer-pump timing convention: `AnalyzerInput.time` starts at `AVAudioTime(sampleTime: 0, atRate: sampleRate)` for the first buffer and advances monotonically.** The window offset is applied **post-hoc** by `TranscriberDriver` when constructing `TranscriptSegment` (add `window.startSeconds` to each `audioTimeRange` lower/upper bound). Do NOT set the first buffer's `sampleTime` to `startFrame` — that would file-relativize the analyzer's emitted ranges, and the formatter's offset would then double-count. This invariant is what R9 actually depends on; the U8 windowed integration test asserts it against the real analyzer, not just the stub.
- **`--stream` implies typed JSONL on stdout.** No plaintext streaming variant. Humans pipe through `jq -r '.text // empty'` if they want segment text only.
- **`--stream` and `--json` are mutually exclusive.** Passing both is a hard argument error (exit 2), not a soft override. Matches the rest of the CLI's strict-validation posture (e.g., U4's `start >= end` rejection) and protects agent consumers whose templating bugs would otherwise produce silently-mis-parsed output.
- **Streaming uses the same `for try await result in transcriber.results` loop the v0.1 pipeline already uses.** A `JSONLFormatter` that takes a stream-of-segments is added; the analyzer driver is shared between streaming and batch modes.
- **MCP windowing validates before doing any work.** Pre-flight check uses `AVURLAsset(url:).load(.duration)` (or `AVAudioFile.length / processingFormat.sampleRate` fallback). Cheap, avoids spinning up SpeechAnalyzer on guaranteed-bad input.
- **SIGINT handling uses `DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)`, NOT a raw `signal(2)` handler.** Raw `signal(2)` handlers run on a restricted async-signal-safe context where Swift runtime calls (including `Task.cancel()`) are undefined behavior; `DispatchSource` event handlers run on a normal dispatch queue where they are safe. The CLI installs `sigaction(SIGINT, SIG_IGN, …)` first to suppress the default handler, then arms the `DispatchSource` whose event handler calls `Task.cancel()` on the stored top-level task.
- **Cancellation contract: drain-then-end, single-writer ordering.** On SIGINT, the dispatch-source handler flips a cancellation flag (via `Task.cancel()`). The streaming `for try await` loop checks `Task.isCancelled` at the top of each iteration; any already-arrived finalized result is emitted as a normal `segment` line; then the loop breaks, the formatter emits `end(reason: "interrupted")`, and the process exits 130. There is exactly one writer (the main actor's stream loop), so no out-of-order interleaving is possible. The agent contract is: every `segment` line that gets emitted appears before `end`; an interrupted stream may have fewer segments than a complete one, but ordering is preserved.
- **Per-line write uses `fflush(stdout)` with `SA_RESTART` semantics on the dispatch source's signal handling.** `FileHandle.standardOutput.synchronizeFile()` is `fsync(2)` semantics and is the wrong call (fails on a pipe). `setvbuf(stdout, nil, _IOLBF, 0)` is set at startup so line buffering is on regardless of pipe vs TTY; `fflush(stdout)` is called after each JSONL line write as a belt-and-braces. Short writes / `EINTR` on `write(2)` are handled by `fwrite`'s built-in retry loop (`fwrite` already restarts on `EINTR`).
- **No new third-party deps.** Reuse `swift-argument-parser`, AVFoundation, Speech, Foundation, Dispatch.

---

## Open Questions

### Resolved During Planning

- _Time grammar:_ Float seconds + `HH:MM:SS` / `MM:SS` on CLI; MCP stays numeric. (Origin Key Decisions.)
- _Negative end-anchors:_ Out. (Origin Scope Boundaries.)
- _Where windowing lives in the pipeline:_ In the Speech layer, behind an optional `AudioWindow` on `TranscriptionRequest`. CLI and MCP are equally affected; neither transport owns the semantics.
- _Cancellation contract on SIGINT:_ Drain-then-end with single-writer ordering. The streaming loop checks `Task.isCancelled` at the top of each iteration; any already-arrived finalized result is emitted as a normal `segment` line; the loop then breaks and emits `end(reason: "interrupted")`. Promoted from origin's "Deferred to Planning" — this is a contract-shape decision, not an execution-time discovery. See Key Technical Decisions for the full mechanism.
- _Signal-handling mechanism:_ `DispatchSource.makeSignalSource`, not raw `signal(2)`. Promoted from origin's "Deferred to Planning" for the same reason — `signal(2)` + `Task.cancel()` is async-signal-unsafe by construction. See Key Technical Decisions.
- _Stdout buffering:_ `setvbuf(stdout, _IOLBF)` at startup + `fflush(stdout)` per JSONL line. `fwrite` handles `EINTR` retry. Resolved here; no need to discover at runtime.
- _`--stream` + `--json` precedence:_ Hard mutex (exit 2). Resolved (matches CLI's strict-validation posture).
- _Header `source` shape for stdin-fed runs:_ `{"type": "stdin"}` (no path, no identifier). U6's `emitHeader` contract documents it; U7 constructs it.

### Deferred to Implementation

- _Bounded-analysis API path:_ Verify during U2 whether SpeechAnalyzer exposes a native range-bounded `analyzeSequence` variant in macOS 26 SDK headers. Default plan is the manual `AVAudioConverter` + buffer-feed path (mirrors steno daemon). If a cleaner API exists, swap to it without changing the plan's per-unit interfaces.
- _Real `SpeechTranscriber.Result` finalization predicate:_ `docs/PLAN.md` §5 uses `result.isFinal`; verify against macOS 26 SDK headers during U2. If the actual gate is `reportingOptions: [.volatileResults]` plus a different predicate, adjust U2's filter and U7's stream loop accordingly. The contract direction (only finalized segments stream) is unchanged.
- _Duration source for MCP pre-flight:_ Prefer `AVURLAsset.load(.duration)`. Fall back to `AVAudioFile.length / sampleRate` if the URLAsset path is unreliable for Voice Memos `.m4a` containers. U5's test scenarios exercise the fallback path explicitly so the fallback isn't dead code.
- _Result ordering invariant:_ Origin assumes finalized segments arrive in audio-monotonic order. Add a debug-only assertion during U2; if violations show up in fixture runs, add a post-hoc sort in the formatter layer.

---

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

**Data flow (both modes share the analyzer driver; transports differ in how results are formatted):**

```
                  ┌──────────────────────────────────────────┐
                  │      TranscriptionRequest                │
                  │  {source, locale, window?, format}       │
                  └────────────────┬─────────────────────────┘
                                   │
                  ┌────────────────▼─────────────────────────┐
                  │      TranscriberDriver (@MainActor)      │
                  │                                          │
                  │  window == nil   ──►  analyzeSequence    │
                  │                       (whole file)       │
                  │                                          │
                  │  window != nil   ──►  AVAudioFile read   │
                  │                       [startFrame,       │
                  │                        endFrame),        │
                  │                       AVAudioConverter,  │
                  │                       analyzer.start +   │
                  │                       buffer pump        │
                  └────────────────┬─────────────────────────┘
                                   │
                                   ▼
                  for try await result in transcriber.results
                                   │
                            (finalized only)
                                   │
                ┌──────────────────┴───────────────────┐
                ▼                                      ▼
       BatchFormatter                          StreamingDriver
       (existing: text                         (new: JSONLFormatter
        / json,                                 emits header → segments
        whole result                            → end; flushes per line;
        at end)                                 SIGINT → end + exit 130)
                                                       │
                                                       ▼
                                                    stdout
```

**JSONL line shapes (typed, discriminator on `type`):**

```
{"type":"header","version":"1","locale":"en-US","durationSeconds":7203.4,
 "source":{"type":"file","path":"/abs/path/file.m4a"},
 "window":{"startSeconds":60,"endSeconds":90}}        // window only if set
{"type":"segment","startSeconds":3.2,"endSeconds":6.8,"text":"…","confidence":0.91}
…
{"type":"end","segmentCount":1843,"elapsedMs":412300,"reason":"complete"}
```

Error variant (mid-stream): one `error` line followed by one `end` line with `reason:"error"`.
Interrupt variant: one `end` line with `reason:"interrupted"`, exit 130.

**Updated batch JSON (when window is set), v1 additive — schema version is NOT bumped:**

```
{
  "version": "1",
  "locale": "en-US",
  "durationSeconds": 30,                    // window length, not file length
  "window": {"startSeconds": 60, "endSeconds": 90},  // NEW, present only when windowed
  "source": {…},
  "segments": [{"startSeconds": 60.0, …}, …],  // file-relative
  "fullText": "…"
}
```

---

## Implementation Units

- [ ] U1. **Time-grammar parser**

**Goal:** Parse CLI time strings (`90`, `90.5`, `1:30`, `1:30:00`) into `Double` seconds. Single, well-tested utility consumed by U4.

**Requirements:** R7.

**Dependencies:** None.

**Files:**
- Create: `Sources/dictamac/Core/TimeGrammar.swift`
- Test: `Tests/dictamacTests/Core/TimeGrammarTests.swift`

**Approach:**
- Accept three input shapes: bare number (with optional decimal), `M:SS[.fraction]`, `H:MM:SS[.fraction]`.
- Reject negatives (origin Scope Boundary).
- Return a typed `Result` or throw a `DictamacError.argumentError` with a clear message naming the offending input.

**Patterns to follow:**
- Pure-function style; no I/O. Mirrors the JSON formatter pattern described in `docs/PLAN.md` §7 (pure transforms, fully testable).

**Test scenarios:**
- Happy path: `"90"` → 90.0; `"90.5"` → 90.5; `"1:30"` → 90.0; `"1:30:00"` → 5400.0; `"0:00.250"` → 0.25.
- Edge case: leading zeros (`"00:30"` → 30.0); fractional in HH:MM:SS form (`"1:30:00.5"` → 5400.5); large values (`"99:59:59"` parses correctly).
- Error path: negative (`"-30"` rejected); malformed (`"1:2:3:4"`, `"abc"`, empty string); non-numeric components (`"a:30"`); colon-only (`":30"`, `"1:"`); MM:SS with seconds ≥ 60 (`"1:75"` rejected).

**Verification:**
- All test cases pass; argument errors carry the offending input verbatim in their message.

---

- [ ] U2. **Bounded audio analysis driver**

**Goal:** Add an `AudioWindow` type and a windowed analysis path in the Speech layer. When `window == nil`, keep the v0.1 `analyzer.analyzeSequence(from: url)` path. When `window != nil`, read `[startFrame, endFrame)` from `AVAudioFile`, convert to the analyzer's expected format via `AVAudioConverter`, and pump buffers into `analyzer.start(input:)`.

**Requirements:** R7, R8, R9. (R9 — timestamps stay file-relative because SpeechAnalyzer's `audioTimeRange` is measured from the start of the analyzer's input stream; this unit must compensate by adding `window.startSeconds` to each emitted segment when in the bounded path.)

**Dependencies:** U1 (for converting `Double` seconds to `AVAudioFramePosition`).

**Files:**
- Create: `Sources/dictamac/Audio/AudioWindow.swift`
- Create: `Sources/dictamac/Speech/TranscriberDriver.swift` (extracts the existing inline analyzer code into a reusable driver shared by batch + streaming)
- Modify: any existing top-level `transcribe` entry point so it delegates to `TranscriberDriver`
- Test: `Tests/dictamacTests/Speech/TranscriberDriverTests.swift` (uses the `SpeechAnalyzerProvider` stub from `docs/PLAN.md` §10)
- Test: `Tests/dictamacTests/Audio/AudioWindowTests.swift`

**Approach:**
- `AudioWindow` is `struct { startSeconds: Double; endSeconds: Double }` with validation (`start >= 0`, `end > start`).
- `TranscriberDriver.transcribe(request:)` constructs a **fresh `SpeechAnalyzer` per call** and branches on `request.window`:
  - `nil` → existing `analyzeSequence(from:)` path. No offset post-processing.
  - non-nil → load `AVAudioFile`, compute `startFrame = Int64(start * sampleRate)`, `endFrame = min(Int64(end * sampleRate), file.length)`, seek via `file.framePosition = startFrame`, read into `PCMBuffer` chunks, convert via `AVAudioConverter`, feed via `analyzer.start(input: stream)` and `inputBuilder.yield(buffer)`.
- **Timing convention for the bounded path:** the first `AnalyzerInput`'s `time` is `AVAudioTime(sampleTime: 0, atRate: sampleRate)`. Each subsequent buffer's `sampleTime` is the running frame count *from the start of the window*, NOT from the start of the source file. SpeechAnalyzer's `audioTimeRange` will then be measured from 0; the driver adds `window.startSeconds` to each emitted `TranscriptSegment.startSeconds` / `endSeconds` after the analyzer hands the result back. Doing both (file-relative input timing AND post-hoc offset) would double-count.
- After the loop, call `inputBuilder.finish()` and `analyzer.finalizeAndFinish(through: .greatestFiniteMagnitude)`.
- Analyzer instances are never reused. Construction + finalize + drop happen inside `transcribe(request:)`. See Key Technical Decisions ("One `SpeechAnalyzer` instance per `TranscriptionRequest`").

**Execution note:** Stub the analyzer behind `SpeechAnalyzerProvider` (planned in `docs/PLAN.md` §10) for unit tests. The stub cannot validate the timing-convention invariant — only the real analyzer in U8's integration test can — so U8's `Covers AE3` scenario must assert on emitted `startSeconds` values against the real fixture, not just on segment count.

**Technical design:** *(directional)* Buffer-pump shape — `currentSampleTime` starts at 0 and tracks *window-local* frames:
```
var currentSampleTime: AVAudioFramePosition = 0
while !done && filePos < endFrame {
    let framesToRead = min(chunkSize, endFrame - filePos)
    try file.read(into: buffer, frameCount: framesToRead)
    let converted = try converter.convert(buffer)
    let time = AVAudioTime(sampleTime: currentSampleTime, atRate: sampleRate)
    inputBuilder.yield(.init(buffer: converted, time: time))
    currentSampleTime += framesToRead
    filePos += framesToRead
}
inputBuilder.finish()
// Then in the results loop, file-relativize:
//   segment.startSeconds = range.lowerBound.seconds + window.startSeconds
//   segment.endSeconds   = range.upperBound.seconds + window.startSeconds
```

**Patterns to follow:**
- steno daemon's live-capture pump (`DefaultSpeechRecognizerFactory.swift` + the capture path) — adapt buffer source from microphone to file slice.
- `@MainActor` placement and `dispatchMain()` runtime guarantees from `docs/PLAN.md` §5 — do not deviate.

**Test scenarios:**
- Happy path (unit, stubbed analyzer): window 30–60 on a fake 120s input yields buffers covering exactly that range; segments emitted have `startSeconds >= 30 && endSeconds <= 60`.
- Edge case: window 0–full duration behaves identically to no window (file-relative timestamps match the unwindowed path within float tolerance).
- Edge case: window ending exactly at file end clamps `endFrame` to `file.length` without throwing.
- Edge case: zero-length / inverted window (`start >= end`) rejected at construction; `AudioWindow.init` throws.
- Error path: window `endSeconds` past file duration is caught by U5 (MCP pre-flight) and U4 (CLI validation); this unit assumes a validated window and clamps defensively but doesn't re-validate.
- Integration: `Covers AE3.` — feeding a real `.m4a` slice through the driver (via U8's integration harness) produces segments inside the window with file-relative timestamps.

**Verification:**
- Whole-file path: driver produces byte-identical batch JSON output for the unwindowed fixture before and after this refactor (regression guard for the v0.1 contract).
- Whole-file equivalence under windowing: a window covering the full duration yields a transcript whose `fullText` (after collapsing internal whitespace runs) equals the unwindowed `fullText`. **Segment-boundary parity is NOT required** — the bounded buffer-pump path can produce different segmentation than `analyzeSequence` even on the same audio, because the analyzer's silence/energy-based grouping sees the input differently. Text equivalence is the contract; boundary parity is not.
- Windowed runs produce segments whose `startSeconds`/`endSeconds` are file-relative within float tolerance (sampleRate-derived rounding error only).

---

- [ ] U3. **JSON result schema update — `window` field, durationSeconds semantics**

**Goal:** When a window is set, the batch JSON result reports `durationSeconds = window length` and adds a top-level `window: {startSeconds, endSeconds}` field. Schema `version` stays `"1"` (additive change, backward compatible per origin R11).

**Requirements:** R11.

**Dependencies:** U2 (windowed driver populates the window in `TranscriptionResult`).

**Files:**
- Modify: `Sources/dictamac/Core/TranscriptionResult.swift` (add optional `window` property)
- Modify: `Sources/dictamac/Format/JSONFormatter.swift` (emit `window` and adjusted `durationSeconds` when present)
- Test: `Tests/dictamacTests/Format/JSONFormatterTests.swift`

**Approach:**
- `TranscriptionResult` gains `let window: AudioWindow?`.
- `JSONFormatter` checks `result.window`: if non-nil, top-level `durationSeconds = window.endSeconds - window.startSeconds`, plus `window: {startSeconds, endSeconds}`. Otherwise unchanged.
- Use the existing deterministic encoder (`outputFormatting: [.prettyPrinted, .sortedKeys]` per `docs/PLAN.md` §7) — needed for snapshot tests.

**Patterns to follow:**
- Existing JSON schema convention from `docs/PLAN.md` §6.
- Snapshot-test pattern for JSON output (from `docs/PLAN.md` §10).

**Test scenarios:**
- Happy path: `Covers AE3.` Result with window 60–90 → top-level JSON has `durationSeconds: 30`, `window: {startSeconds: 60, endSeconds: 90}`, segments with `startSeconds >= 60` and `endSeconds <= 90`.
- Regression: result with no window produces byte-identical output to v0.1 fixture (snapshot test against a captured golden file).
- Edge case: window covering exactly the full file still emits the `window` field (presence is determined by request, not by whether the window is a strict subset).

**Verification:**
- Snapshot tests pass; v0.1 schema output unchanged when no window is requested.

---

- [ ] U4. **CLI `--start` / `--end` flags**

**Goal:** Add `--start <T>` and `--end <T>` to the CLI parser. Validate against file duration after audio is loaded. Pass the resulting `AudioWindow` into `TranscriptionRequest`. Compose with all input sources (path, stdin, `--voice-memo`).

**Requirements:** R7, R9, R14, R15.

**Dependencies:** U1, U2, U3.

**Files:**
- Modify: `Sources/dictamac/CLI/Command.swift` (or the equivalent root `ParsableCommand` once U3 of `docs/PLAN.md` is implemented)
- Test: `Tests/dictamacTests/CLI/WindowingFlagsTests.swift`

**Approach:**
- Define `@Option(name: .long) var start: String?` and `@Option(name: .long) var end: String?`.
- After argument parsing: if either is set, parse via `TimeGrammar`. After audio load, fetch file duration, clamp `end` if omitted (default to duration), default `start` to 0 if omitted. Construct `AudioWindow` and pass into the request.
- Reject invalid combinations explicitly: `start >= end`, `end > duration`, `start < 0` → `DictamacError.argumentError` → exit 2.
- Verify mutual-exclusivity rules from `docs/PLAN.md` §4 still hold: `--start`/`--end` work alongside positional path, stdin (`-`), and `--voice-memo`, but ignored in `--mcp` and `--list-voice-memos` modes (CLI parser surfaces a clear "ignored" notice on stderr if both are passed together; not an error).
- **`--stream` + `--json` mutex:** while U4's primary scope is windowing, this unit owns the argument-parser layer that U7 will extend. The mutual-exclusion check between `--stream` and `--json` is added here as a `validate()` method on the root command (per `swift-argument-parser` conventions). Conflict → `ValidationError` → exit 2. U7 only adds the `--stream` flag itself; the enforcement lives here.

**Patterns to follow:**
- `swift-argument-parser` `@Option` style from `docs/PLAN.md` §3.
- Error-mapping pattern from `docs/PLAN.md` §9 — one central function maps `DictamacError` to stderr + exit code.

**Test scenarios:**
- Happy path: `--start 30 --end 90` parses and produces an `AudioWindow(30, 90)`.
- Happy path: `--start 1:30 --end 1:30:00` parses correctly (HH:MM:SS grammar accepted via U1).
- Happy path (defaulting): `--end 90` alone defaults `start` to 0; `--start 30` alone defaults `end` to file duration.
- Edge case: `--start 90 --end 90` (zero-length) rejected with exit 2.
- Edge case: `--end 9999` against a 600s file rejected with exit 2 and a stderr message naming the actual duration.
- Edge case: `--start 30 --voice-memo "standup"` composes — window applied to the resolved Voice Memo file.
- Error path: `--start abc` rejected by U1's grammar parser; exit 2.

**Verification:**
- Composition with stdin, `--voice-memo`, and `--locale` works without special-case branches.
- `dictamac --start 60 --end 90 fixture.m4a` produces JSON identical to AE3 expectations.

---

- [ ] U5. **MCP windowing params + pre-flight duration validation**

**Goal:** Add optional numeric `startSeconds` and `endSeconds` to `transcribe_file` and `transcribe_voice_memo` MCP tool input schemas. Validate against file duration before any transcription work runs; on failure return MCP `isError: true` with a clear message.

**Requirements:** R8, R11, R12, R13.

**Dependencies:** U2, U3.

**Files:**
- Modify: `Sources/dictamac/MCP/Server.swift` and `Sources/dictamac/MCP/Tools.swift` (or equivalent MCP layer when U8 of `docs/PLAN.md` lands)
- Test: `Tests/dictamacTests/MCP/WindowingToolTests.swift`

**Approach:**
- Update both tools' `inputSchema` JSON: add `startSeconds` and `endSeconds` as optional `"type": "number"` properties.
- On `tools/call`: parse the args; if either is present, resolve the file path (for `transcribe_voice_memo` this means running the Voice Memos lookup first), then fetch duration via `AVURLAsset(url: …).load(.duration)`. If that path fails, fall back to `AVAudioFile.length / processingFormat.sampleRate`.
- Validate `0 <= startSeconds`, `startSeconds < endSeconds`, `endSeconds <= durationSeconds`. On failure: return MCP tool result with `isError: true` and a message naming the file's actual duration. No transcription work runs.
- Pass the validated `AudioWindow` through to the shared `TranscriberDriver` (U2).

**Patterns to follow:**
- MCP error response shape from `docs/PLAN.md` §5 ("Errors" subsection).
- `docs/PLAN.md` §9 central error-mapping function — MCP-mode failure mapping reuses it.

**Test scenarios:**
- Happy path: `Covers AE4.` (inverse) — call with valid window 60–90 against a fixture; response has the windowed JSON shape from U3.
- Error path: `Covers AE4.` — call with `endSeconds: 9999999` against a 600s file; response has `isError: true` and message including the actual duration. SpeechAnalyzer is not invoked (verify via test spy / call counter on the stubbed `SpeechAnalyzerProvider`).
- Error path: `startSeconds: -1` rejected with `isError: true`.
- Error path: `startSeconds: 90, endSeconds: 90` (zero-length) rejected.
- Edge case: `endSeconds` provided without `startSeconds` defaults `startSeconds` to 0 (parity with CLI).
- Happy path: omitting both params behaves identically to v0.2 pre-windowing tool calls (regression guard).
- Edge case: window applied via `transcribe_voice_memo` correctly resolves the Voice Memo first, then validates against its duration (not against the query string).
- Edge case (fallback path): with `AVURLAsset.load(.duration)` stubbed to return `CMTime.indefinite` (or zero), the duration check falls back to `AVAudioFile.length / processingFormat.sampleRate` and produces a usable duration. Without this scenario the fallback is dead code until a user hits the bug.

**Verification:**
- Pre-flight validation rejects bad windows without any SpeechAnalyzer invocation.
- Omitting window params produces byte-identical responses to the pre-windowing tool surface.

---

- [ ] U6. **Typed JSONL formatter**

**Goal:** A formatter that emits JSONL with `type`-discriminated lines (`header`, `segment`, `end`, `error`). One JSON object per `write` call. Designed to be driven by a stream of segments rather than a fully-materialized result.

**Requirements:** R3, R4, R6, R10, R11 (header shape mirrors batch JSON top-level).

**Dependencies:** U3 (so the segment line shape matches the batch JSON segment shape — they share the same `TranscriptSegment` encoder).

**Files:**
- Create: `Sources/dictamac/Format/JSONLFormatter.swift`
- Test: `Tests/dictamacTests/Format/JSONLFormatterTests.swift`

**Approach:**
- `JSONLFormatter` exposes four entry points: `emitHeader(_:)`, `emitSegment(_:)`, `emitEnd(reason: EndReason, segmentCount: Int, elapsedMs: Int)`, `emitError(_:)`.
- Each entry encodes one JSON object (compact, no pretty-printing — JSONL convention), appends `\n`, writes to the configured `TextOutputStream` (default: stdout), and flushes.
- Sort keys for snapshot-test determinism.
- `EndReason` is an enum (`complete`, `interrupted`, `error`) encoded as a lowercase string.
- **Header `source` shape varies by input type:**
  - File: `{"type": "file", "path": "<absolute path>"}`
  - Stdin: `{"type": "stdin"}` (no path field — stdin is drained to a temp file but the temp path is implementation detail; agents see `stdin` as the canonical source)
  - Voice Memo: `{"type": "voice-memo", "identifier": "<uuid>", "title": "<title>"}` (matches the batch JSON shape from `docs/PLAN.md` §6)

**Patterns to follow:**
- `JSONFormatter` from U3 / `docs/PLAN.md` §7 — same encoder configuration except `.prettyPrinted` is omitted (JSONL is one object per line).
- `TextOutputStream` abstraction so MCP could in principle capture this output too (not in scope for v0.2; the abstraction is the cheap win).

**Test scenarios:**
- Happy path: `emitHeader` produces a single line with `type: "header"`, `version: "1"`, all required fields, and (when set) the `window` object.
- Happy path (stdin source): `emitHeader` with a stdin source produces `"source":{"type":"stdin"}` (no path key).
- Happy path (voice-memo source): `emitHeader` with a voice-memo source produces `"source":{"type":"voice-memo","identifier":"…","title":"…"}`.
- Happy path: `emitSegment` produces a single line with `type: "segment"` and the same `startSeconds/endSeconds/text/confidence` shape as `JSONFormatter`'s segment encoding (parity test against a fixed `TranscriptSegment`).
- Happy path: `emitEnd(reason: .complete, segmentCount: 5, elapsedMs: 1234)` produces a single line with `type: "end"`, `reason: "complete"`, and the counters.
- Happy path: `emitError(code: 65, message: "...")` produces a single line with `type: "error"`, `code: 65`, `message`.
- Edge case: each emit writes exactly one trailing `\n` (no double newlines, no missing newlines). Verify via byte-count assertion.
- Edge case: `confidence` absent on segment input → JSON **omits** the `confidence` key entirely (not `null`). Matches origin "treat absence as unknown" and avoids forcing agents to distinguish `null` from "missing."
- Edge case: writing to a captured `TextOutputStream` (not stdout) works — needed for tests to capture output without spawning a subprocess.

**Verification:**
- Snapshot tests pass for each line type.
- Segment line shape is bit-identical to the inner-segment shape produced by `JSONFormatter` (other than ordering — keys are sorted in both).

---

- [ ] U7. **CLI `--stream` flag + signal handling**

**Goal:** `--stream` flag enables JSONL streaming mode. Header line emitted before the analyzer starts producing finalized results. Each finalized result triggers one segment line, flushed immediately. SIGINT cancels gracefully and emits an `end` line with `reason: "interrupted"`, exits 130. Mid-stream errors emit `error` + `end`, exit with classified code.

**Requirements:** R1, R2, R3, R4, R5, R6, R10, R14, R15.

**Dependencies:** U2 (shared driver, used in both batch and streaming modes), U6 (formatter).

**Files:**
- Create: `Sources/dictamac/CLI/StreamingDriver.swift` (orchestrates header → loop → end)
- Modify: `Sources/dictamac/CLI/Command.swift` — add `@Flag var stream: Bool`; route to `StreamingDriver` instead of `BatchDriver` when set
- Test: `Tests/dictamacTests/CLI/StreamingDriverTests.swift` (unit, stubbed analyzer)
- Test: `Tests/dictamacTests/Integration/StreamingIntegrationTests.swift` (subprocess, real fixture — overlaps with U8)

**Approach:**

*Startup:*
1. Argument parser rejects `--stream --json` as mutually exclusive (exit 2). No soft override.
2. At process start (before any output): `setvbuf(stdout, nil, _IOLBF, 0)` to force line buffering regardless of TTY/pipe.

*Signal handling (set up once, before the analyzer starts):*
3. `sigaction(SIGINT, SIG_IGN, …)` suppresses the default `SIGINT` handler. (Raw `signal(2)` handlers cannot safely call into the Swift runtime.)
4. Construct `DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)`. The event handler calls `Task.cancel()` on the stored top-level task (held in an `actor`-isolated or `@MainActor` holder). The dispatch source runs on the main queue, not the signal stack, so Swift-runtime calls are safe.
5. Activate the dispatch source. It stays alive for the lifetime of the streaming run.

*Streaming flow (drain-then-end, single-writer ordering):*
6. Resolve audio source and window (same path U4 uses).
7. Emit `header` line via `JSONLFormatter`. `fflush(stdout)`.
8. Iterate `for try await result in transcriber.results`:
   - At the top of each iteration, check `Task.isCancelled`. If set, `break` (don't throw — we want to fall through to a clean `end` line).
   - For each finalized result, emit `segment` line via `JSONLFormatter`. `fflush(stdout)`.
9. On natural exit from the loop (no cancellation): emit `end(reason: .complete, segmentCount, elapsedMs)`. Exit 0.
10. On cancellation-driven exit: emit `end(reason: .interrupted, segmentCount, elapsedMs)`. Exit 130.
11. On any thrown `DictamacError` (mid-stream): emit `error(code, message)`, then `end(reason: .error, segmentCount, elapsedMs)`. Exit with the mapped code.

*Single-writer invariant:* `JSONLFormatter` is only called from the main actor's streaming loop. The `DispatchSource` handler does not write; it only flips cancellation. This guarantees: every `segment` line that the formatter emits appears before `end`; an interrupted stream may have fewer segments than a complete one, but ordering is preserved.

*Stdio robustness:* `fwrite` retries internally on `EINTR`. With line buffering forced via `setvbuf`, plus per-line `fflush`, partial-write scenarios reduce to "the kernel may briefly hold bytes in pipe buffers" — which is fine, agents reading line-by-line still get whole lines because `fwrite` does not return until the buffer is drained or hard-errored. `PIPE_BUF` atomicity is not the relevant invariant for a single-writer process; line-buffered + flushed writes are.

**Execution note:** Implement the success path first against the fixture and stubbed analyzer to confirm header → segment(s) → end ordering and flushing. Then add `DispatchSource` SIGINT handling and exercise it in the U8 integration suite against the real analyzer.

**Technical design:** *(directional)*

```
// Startup
setvbuf(stdout, nil, _IOLBF, 0)
var sigaction = sigaction(__sigaction_u: SIG_IGN, sa_mask: 0, sa_flags: 0)
sigaction(SIGINT, &sigaction, nil)

let streamTask = Task { @MainActor in
    let formatter = JSONLFormatter(stream: FileHandle.standardOutput)
    formatter.emitHeader(...); fflush(stdout)
    var count = 0
    let started = Date()
    do {
        for try await r in transcriber.results where r.isFinal {
            if Task.isCancelled { break }                          // drain-then-end
            formatter.emitSegment(r → TranscriptSegment + offset)
            fflush(stdout)
            count += 1
        }
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        if Task.isCancelled {
            formatter.emitEnd(reason: .interrupted, count: count, elapsedMs: elapsed)
            fflush(stdout); exit(130)
        }
        formatter.emitEnd(reason: .complete, count: count, elapsedMs: elapsed)
        fflush(stdout); exit(0)
    } catch let err as DictamacError {
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        formatter.emitError(code: err.exitCode, message: err.description)
        formatter.emitEnd(reason: .error, count: count, elapsedMs: elapsed)
        fflush(stdout); exit(Int32(err.exitCode))
    }
}

let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSource.setEventHandler { streamTask.cancel() }
sigintSource.activate()
dispatchMain()    // existing entry-point requirement from docs/PLAN.md §5
```

**Patterns to follow:**
- `@MainActor` placement from `docs/PLAN.md` §5 — analyzer remains on main; SIGINT handler runs on the C signal stack and only does `Task.cancel()`.
- Error mapping from `docs/PLAN.md` §9 — reuse the central function for the mid-stream `error` line.
- `dispatchMain()` runtime model — streaming must work with the same entry-point shape.

**Test scenarios:**
- Happy path (unit, stub): `Covers AE1.` Driver against a stubbed analyzer yielding 3 segments produces exactly 5 lines: header, 3 × segment, end. End has `segmentCount: 3` and `reason: "complete"`.
- Happy path (integration, fixture): `Covers AE1.` Against the en-US fixture, `dictamac --stream fixture.m4a` outputs JSONL whose first line is `type: "header"` within 2 seconds (or whatever the natural fixture latency is — document and assert what's actually achievable for the fixture), at least one `segment` line, and a final `type: "end"`.
- Edge case: empty audio (silence) → header, no segments, end with `segmentCount: 0`.
- Edge case: `--stream --start 30 --end 60` produces a header whose `window` field is populated and segments whose timestamps are in [30, 60).
- Error path (argument): `--stream --json` is rejected by the argument parser before any output; exit 2; stderr names the conflict. (Hard mutex, no soft override.)
- Error path: missing input file → `error` line with `code: 64`, then `end(reason: "error")`, exit 64. (Confirms error-line emission even when failure happens before analyzer starts.)
- Error path: corrupt audio (mid-decode failure) → `error` line, `end(reason: "error")`, exit 65.
- Interrupt path (unit, stub): drain-then-end ordering — stub analyzer yields 2 segments, then test fires `Task.cancel()` and yields a 3rd segment that should NOT be emitted (the cancellation check at the loop top catches it). Output is: header, 2 × segment, end(reason: "interrupted"), segmentCount: 2. Exit code path not exercised in unit; covered in integration.
- Interrupt path (integration): `Covers AE2.` Subprocess started with `dictamac --stream long.m4a` (or a slowed-down fixture), SIGINT delivered via `Process.interrupt()` after a fixed delay; last line is `end(reason: "interrupted")`, exit 130. **This test ships green and is not skippable** — the design uses `DispatchSource` (async-signal-safe) and drain-then-end ordering, so signal delivery is deterministic on macOS runners.
- Edge case (ordering invariant under cancellation): the integration subprocess test reads the full stdout stream and asserts that no `segment` line appears AFTER the `end` line. Guards against the spawned-onCancel-Task race that an earlier version of the design risked.
- Edge case (byte-level): each emitted line is flushed before the next is generated — verify with a piped subprocess test that consumes line-by-line with a deadline between reads.
- Edge case: long segment lines (text > 512 bytes, pushing past macOS `PIPE_BUF`) are still emitted as single complete lines — agent-side line reader sees no fragmentation.

**Verification:**
- Streaming run against the fixture produces a well-formed JSONL sequence (header, ≥1 segment, end) where each line is independently parseable as JSON.
- SIGINT during streaming does not leave a half-written JSONL line.
- `--stream` does not regress batch (`--json` and plaintext) output for the same fixture.

---

- [ ] U8. **Integration tests**

**Goal:** End-to-end coverage of AE1–AE4 against the committed en-US fixture, including a subprocess-based MCP integration that closes the windowing surface.

**Requirements:** R1–R15 (coverage closure).

**Dependencies:** U2, U3, U4, U5, U6, U7.

**Files:**
- Create: `Tests/dictamacTests/Integration/StreamingIntegrationTests.swift`
- Create: `Tests/dictamacTests/Integration/WindowingIntegrationTests.swift`
- Create: `Tests/dictamacTests/Integration/MCPWindowingIntegrationTests.swift`
- Modify: `Tests/Fixtures/` — confirm the en-US fixture from `docs/PLAN.md` §10 is present (committed during MVP work); if not, this unit must add it. Fixture is 5–10 s of clear speech.

**Approach:**
- Each integration test spawns the built binary as a subprocess (consistent with MCP test pattern from `docs/PLAN.md` §10).
- Streaming tests pipe stdout and parse line-by-line as JSON.
- MCP tests send `initialize` + `tools/list` + `tools/call` payloads on stdin, parse responses on stdout.
- SIGINT test (if shipped) signals the subprocess via `Process.interrupt()` after a fixed delay and asserts on the trailing output.

**Patterns to follow:**
- Subprocess + JSON-RPC harness from `docs/PLAN.md` §10 MCP test.
- Snapshot tests for stable output via `outputFormatting: .sortedKeys`.

**Test scenarios:**
- `Covers AE1.` `dictamac --stream fixture.m4a` produces header (within reasonable latency) + ≥1 segment + end(complete).
- `Covers AE3.` `dictamac --json --start 1 --end 4 fixture.m4a` produces JSON with `durationSeconds: 3`, `window: {1, 4}`, all segments in `[1, 4)`. **Asserts file-relative timestamps against the real analyzer** (the buffer-pump timing-convention invariant from U2 can only be validated here, not in U2's stubbed unit test).
- `Covers AE3.` `dictamac --stream --start 1 --end 4 fixture.m4a` produces header with `window`, segments in `[1, 4)`, end(complete).
- `Covers AE4.` MCP `transcribe_file` with `endSeconds: 9999999` returns `isError: true` and does not transcribe.
- MCP `transcribe_file` with valid window returns JSON matching the windowed batch schema (parity with CLI `--json --start --end` output).
- Composition: `dictamac --stream -` (stdin) produces streaming output with header `source: {"type": "stdin"}`. Composition: `dictamac --stream --locale en-US fixture.m4a` works.
- Schema regression: `dictamac --json fixture.m4a` (no window, no stream) output is byte-identical to the v0.1 snapshot (guards against accidental schema change).
- Argument-parser regression: `dictamac --stream --json fixture.m4a` exits 2 with a stderr message naming the `--stream`/`--json` mutex; no analyzer is started.
- Whole-file equivalence under windowing: `dictamac --stream --start 0 --end <duration> fixture.m4a` and `dictamac --stream fixture.m4a` produce the same concatenated `fullText` after whitespace normalization. **Segment boundaries are NOT asserted equal** (see U2 verification).
- `Covers AE2.` SIGINT during a streaming run leaves a well-terminated stream: subprocess started with `dictamac --stream fixture.m4a` (or a long fixture if needed for timing), `Process.interrupt()` after a controlled delay, captured stdout parses as valid JSONL, last line is `end(reason: "interrupted")`, no `segment` line appears after `end`, exit 130. **This test ships green; the design (DispatchSource + drain-then-end) makes signal delivery deterministic.**

**Verification:**
- All integration tests pass on local macOS 26 + on the CI runner described in `docs/PLAN.md` §10.
- A consumer reading the JSONL stream byte-by-byte with `JSONDecoder` and `\n` framing never sees a partial line.

---

- [ ] U9. **PLAN.md update**

**Goal:** Update `docs/PLAN.md` to reflect the v0.2-scope expansion: move `--stream` from v0.3 to v0.2, add windowing under v0.2, extend §6 with the JSONL schema, update §2 Non-goals, add streaming-specific entries to §9 Risk table.

**Requirements:** Documentation alignment (no R-IDs; this is the durable plan that the codebase ships against).

**Dependencies:** None (can run in parallel with all functional units), but most useful after U6/U7 are designed so the §6 update reflects the actual JSONL line shapes shipped.

**Files:**
- Modify: `docs/PLAN.md`

**Approach:**
- §2 Non-goals: remove the `--stream` line ("Streaming partial transcripts to stdout…"); leave the SRT/VTT line as-is. Note: "Volatile/interim results" stays a non-goal (origin Scope Boundary), so add it explicitly if not already covered.
- §4 CLI Surface: add `--stream`, `--start`, `--end` to the listed examples.
- §5 MCP Surface: extend the `transcribe_file` and `transcribe_voice_memo` schemas to include `startSeconds` / `endSeconds`. Add a note that MCP does not stream.
- §6 JSON Transcript Schema: add a `window` field description for the additive case; cross-link to the new §6.1 (or extend §6) covering the JSONL line schema (`header`, `segment`, `end`, `error`).
- §8 Phased Rollout: move "Streaming partial output" from v0.3 to v0.2. Add "Time windowing (`--start`/`--end`; MCP `startSeconds`/`endSeconds`)" under v0.2. Remove from v0.3 (and any pending design notes that are now resolved).
- §9 Open Questions & Risks: add (a) "SIGINT-during-stream leaves partial line" → mitigation "explicit per-line flush + cancellation-aware finalize", (b) "AVURLAsset.duration unreliable for some `.m4a` Voice Memos" → mitigation "fallback to AVAudioFile.length/sampleRate".

**Test scenarios:**
- Test expectation: none — pure documentation. Reviewer eyeballs the diff for completeness against this plan's Requirements Trace.

**Verification:**
- `docs/PLAN.md` has no remaining references to `--stream` as a v0.3 / "plausible later" item.
- §6 documents both the batch JSON additive `window` field and the typed JSONL line schema.

---

## System-Wide Impact

- **Interaction graph:** Both transports (CLI, MCP) and the analyzer driver are touched. New surface area lives in two layers — flag/schema parsing (transports) and a windowed analysis path (driver). Streaming is CLI-only, so MCP is unaffected by signal handling and flushing concerns.
- **Error propagation:** `DictamacError` enum gets one new case via U4/U5 validation paths (`argumentError(...)` covers both, no new case strictly needed). Streaming adds a new emit path (`error` JSONL line) that wraps the same enum and converts to JSONL before exit. The central error-mapping function from `docs/PLAN.md` §9 stays the single source of truth.
- **State lifecycle risks (SIGINT mid-stream):** The mitigation is the drain-then-end cancellation contract plus single-writer ordering, NOT pipe-write atomicity. Mechanism: the `DispatchSource` SIGINT handler runs on the main queue and only flips `Task.isCancelled`; the streaming loop checks the flag at the top of each iteration and breaks cleanly before emitting `end`. Because there is exactly one writer (the main actor's loop), no JSONL line can be split mid-write by another thread, and no `segment` line can appear after `end`. `fwrite` handles `EINTR` retry internally, so a signal arriving mid-syscall does not produce a short write.
- **API surface parity:** CLI `--start`/`--end` and MCP `startSeconds`/`endSeconds` must remain semantically equivalent — same `AudioWindow` validation, same file-relative timestamp invariant. U2 owns the shared semantics so they cannot drift.
- **Integration coverage:** AE1–AE4 are the four cross-layer checkpoints. U8 covers all four. AE2 (SIGINT) ships green — the design (DispatchSource + drain-then-end) makes signal-delivery behavior deterministic across local and CI macOS runners.
- **Unchanged invariants:**
  - Plaintext output (no `--json`, no `--stream`) is byte-identical for unwindowed runs. Windowed plaintext runs still emit text only — no JSONL framing on the plaintext path.
  - Batch JSON for unwindowed runs is byte-identical to v0.1.
  - MCP responses for tool calls with no windowing params are byte-identical to the pre-windowing v0.2 contract.
  - Exit codes for non-streaming failure paths are unchanged from `docs/PLAN.md` §4.
  - `dispatchMain()` + `@MainActor` runtime model is preserved.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Manual buffer-feed path (U2) introduces subtle bugs vs. `analyzeSequence` | Default to whole-file path when `window == nil`; U8 integration test asserts `fullText` equivalence (not segment-boundary equivalence) between windowed-whole-file and unwindowed runs |
| Buffer-pump timing convention is implemented inconsistently (file-relative input timing + post-hoc offset would double-count) | Explicit invariant in Key Technical Decisions and U2 Approach: feed buffers with `sampleTime` starting at 0; offset applied post-hoc by formatter. U8's `Covers AE3` scenario asserts emitted `startSeconds` against the real analyzer |
| `AVURLAsset.load(.duration)` returns `CMTime.indefinite` or zero for some Voice Memos `.m4a` files | Fallback to `AVAudioFile.length / processingFormat.sampleRate`; U5 test scenario forces this branch so the fallback is exercised, not dead code |
| Raw `signal(2)` + `Task.cancel()` is async-signal-unsafe (heap allocations, runtime locks) | Use `DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)`; event handler runs on a normal dispatch queue context where Swift runtime calls are safe |
| In-flight finalized result is dropped, OR appears AFTER the `end` line, on cancellation | Drain-then-end cancellation contract: single-writer streaming loop checks `Task.isCancelled` at the top of each iteration; cancellation propagation is decided in this plan, not deferred to implementation. U7 + U8 assert no `segment` line appears after `end` |
| Long segment lines (text + envelope > `PIPE_BUF`) cause short writes under signal | `fwrite` already retries on `EINTR`; line buffering forced via `setvbuf(_IOLBF)`; per-line `fflush`. Single-writer process means `PIPE_BUF` atomicity is not the relevant invariant — write ordering and `EINTR` retry are |
| First-run locale model download is invisible to streaming consumers (looks like a hang) | Existing PLAN.md §9 risk; streaming `header` line gives a clean future hook to surface model-download progress — out of scope here but easy to add later |
| Segment ordering not strictly monotonic in real outputs | Debug-only assertion in U2; if it fires in fixture runs, add post-hoc sort in the formatter |
| `--stream` + `--json` ambiguity confuses agent scripts | Hard mutex at the argument-parser layer (U4) — `ValidationError` → exit 2. No soft override |

---

## Documentation / Operational Notes

- README example block should be extended in a follow-up PR (not blocking this plan) with a `--stream` example and a `--start`/`--end` example.
- No new TCC permissions, no new entitlements, no new dependencies — install/distribution unchanged.
- No on-disk state, no migration. Schema `version` stays `"1"` (additive change).
- Homebrew distribution unaffected.

---

## Sources & References

- **Origin document:** [docs/brainstorms/long-form-transcription-requirements.md](../brainstorms/long-form-transcription-requirements.md)
- Architectural plan: [docs/PLAN.md](../PLAN.md)
- External: [Apple SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer), [SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber), [MCP specification](https://modelcontextprotocol.io/specification)
- Sibling project for reusable patterns: [steno](https://github.com/jwulff/steno) — specifically the daemon's analyzer factory and live-capture buffer pump
