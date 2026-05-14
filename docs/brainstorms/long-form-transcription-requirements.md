---
date: 2026-05-13
topic: long-form-transcription
---

# Long-Form Transcription: Streaming Output + Time Windowing

## Problem Frame

dictamac MVP returns the full transcript only after `SpeechAnalyzer` finishes processing the entire input. For a typical Voice Memo this is fine. For a 1–2 hour meeting recording it's a UX cliff: nothing on stdout for tens of minutes, no way to bail early once it's obvious the audio is bad, no way to sample a specific section without paying for the whole transcription.

Two related capabilities address this together:

1. **Streaming output** — emit each finalized segment as a line of JSONL on stdout as soon as `SpeechAnalyzer` finalizes it.
2. **Time windowing** — transcribe only `[start, end)` of an input file instead of the whole thing.

They compose: stream JSONL of just the windowed slice. They are useful individually: streaming the whole file for live tailing; windowing without streaming for one-shot partial transcripts via MCP. We document them together because they share a design surface (timestamp semantics, source schema, format coherence) and a single agent contract.

---

## Actors

- A1. **Long-recording human.** Runs `dictamac` against a meeting/lecture/podcast recording in a terminal. Wants to see transcript text appear as it's processed, scrub for content, and `Ctrl-C` once they've seen enough.
- A2. **Agent (CLI mode).** Spawns `dictamac --stream` as a subprocess, parses JSONL line-by-line, can produce intermediate summaries or stop early. Treats the JSONL schema as a contract.
- A3. **Agent (MCP mode).** Calls `transcribe_file` / `transcribe_voice_memo` with `startSeconds`/`endSeconds` to request a single windowed slice; gets a single JSON object back. Does not stream over MCP.

---

## Key Flows

- F1. **Live-tail a long recording (human or agent, CLI)**
  - **Trigger:** `dictamac --stream long-meeting.m4a`
  - **Actors:** A1 or A2
  - **Steps:** Process spawns; emits `header` line within ~1 s; emits `segment` lines as they finalize; emits `end` line on natural completion; exits 0.
  - **Outcome:** Caller saw progress within seconds and consumed all segments incrementally.
  - **Covered by:** R1, R2, R3, R4, R10

- F2. **Bail early during streaming (human)**
  - **Trigger:** A1 hits `Ctrl-C` (SIGINT) mid-stream.
  - **Actors:** A1
  - **Steps:** Process catches signal; finishes the in-flight segment if one is pending; emits an `end` line with `reason: "interrupted"`; exits with a distinct non-zero code.
  - **Outcome:** Caller has a clean, well-terminated JSONL stream up to the interruption point.
  - **Covered by:** R5, R6

- F3. **Sample a window via MCP (agent)**
  - **Trigger:** A3 calls `transcribe_file` with `path`, `startSeconds: 1800`, `endSeconds: 2100`, `format: "json"`.
  - **Actors:** A3
  - **Steps:** Server validates window against file duration; runs the SpeechAnalyzer pipeline over just that window; returns a single JSON transcript whose `segments[]` carry timestamps relative to the file (not the window).
  - **Outcome:** Agent gets a 5-minute slice of transcript without paying for the full file.
  - **Covered by:** R7, R8, R9, R12

---

## Requirements

**Streaming output (CLI only)**

- R1. A `--stream` flag enables incremental output. Implies typed JSONL on stdout; ignores `--json` if also passed.
- R2. Stream begins with a single `header` line emitted before any audio processing completes. Header includes `version`, `locale`, `source`, and `durationSeconds` of the actual input window.
- R3. Each finalized `SpeechAnalyzer` result is emitted as one `segment` line. Stdout is flushed after each line. No buffering beyond a single line's worth.
- R4. Stream ends with a single `end` line containing `segmentCount`, `elapsedMs`, and `reason: "complete"` on natural completion.
- R5. On `SIGINT`, the process emits an `end` line with `reason: "interrupted"` after letting any in-flight segment finalize, then exits with a distinct code (proposal: 130, the conventional SIGINT exit).
- R6. On any mid-stream error, the process emits a single `error` line (`{type, code, message}`) followed by an `end` line with `reason: "error"`, then exits with the existing classified error code (§9 of PLAN.md).

**Time windowing (CLI + MCP)**

- R7. CLI accepts `--start <T>` and `--end <T>`. Either may be omitted; `--start` defaults to 0 and `--end` defaults to the file duration. Window is half-open `[start, end)`.
- R8. MCP tools `transcribe_file` and `transcribe_voice_memo` accept optional `startSeconds` and `endSeconds` number params with the same semantics.
- R9. All emitted `startSeconds` / `endSeconds` in segments and the `durationSeconds` in the header/result are **file-relative**, not window-relative. The window only changes which segments are emitted, not how they are timestamped.

**Agent contract stability**

- R10. The JSONL line schema uses a discriminator field `type` with values: `header`, `segment`, `end`, `error`. Unknown types must be treated as forward-compatible additions, not errors.
- R11. The single-result JSON schema (§6 of PLAN.md) is unchanged when no windowing is requested. When windowing is requested, the result's `durationSeconds` reflects the window length and a new `window: {startSeconds, endSeconds}` object is added at the top level.

**MCP boundaries**

- R12. MCP servers do not stream tool output for this feature. Streaming is a CLI-only capability in this round. MCP responses for windowed calls return a single JSON object after the windowed transcription completes.
- R13. MCP windowing validates `0 <= startSeconds < endSeconds <= durationSeconds` against the file's actual duration before running. On failure, returns an MCP tool error (`isError: true`) with a clear message; no transcription work is done.

**Composition rules**

- R14. `--stream` composes with `--voice-memo`, stdin input (`-`), and `--locale` without special cases.
- R15. `--stream`, `--start`, and `--end` compose freely. `--stream --start 1800 --end 2100` streams JSONL covering just that window.

---

## Acceptance Examples

- AE1. **Covers R1, R2, R3, R4, R9.** Given a 2-hour `.m4a`, when running `dictamac --stream meeting.m4a`, the first line on stdout is a `header` object within 2 seconds of launch (i.e. before any segments), `segment` lines appear over time with monotonically non-decreasing `startSeconds` rooted at 0, and a final `end` line with `reason: "complete"` appears after the last segment.

- AE2. **Covers R5, R6.** Given a streaming run interrupted at 30 minutes with `Ctrl-C`, the last two lines of output are (a) the most recent `segment` line whose `endSeconds <= 1800.x`, and (b) an `end` line with `reason: "interrupted"`. Exit code is 130.

- AE3. **Covers R7, R9, R11.** Given `dictamac --json --start 60 --end 90 meeting.m4a`, the returned JSON has `durationSeconds: 30`, a `window: {startSeconds: 60, endSeconds: 90}` field, and all `segments[].startSeconds >= 60` and `segments[].endSeconds <= 90`.

- AE4. **Covers R8, R12, R13.** Given an MCP `transcribe_file` call with `endSeconds: 9999999` against a 600-second file, the response is `isError: true` with a message naming the actual file duration; no transcription runs.

---

## Success Criteria

- For a 2-hour `.m4a`, the first `segment` line appears on stdout within 5 seconds of launch (or whatever SpeechAnalyzer's natural finalization cadence is — the constraint is "no artificial buffering delay between Apple's emit and our line write").
- An agent built against the typed-JSONL schema today still parses cleanly after we add new line types or fields in a future minor release.
- The existing non-streaming `--json` output for the full file is byte-identical before and after this feature ships (no regressions to the MVP contract).
- A new contributor reading `docs/brainstorms/long-form-transcription-requirements.md` plus PLAN.md can implement this without asking product questions.

---

## Scope Boundaries

- **Volatile/interim results are out.** Only finalized segments stream. SpeechAnalyzer's volatile/in-progress results are not exposed in v0.x; revisit only if there is real demand.
- **MCP streaming is out.** No progress notifications, no chunked tool responses. MCP gets windowing only.
- **Resumable / append-on-restart is out.** If a stream is interrupted, the caller re-runs from the beginning (optionally with `--start` to skip the prefix). No on-disk checkpoint format.
- **SRT/VTT output is out** for this feature. Existing v0.3 entry covers that separately.
- **`--watch` directory mode, `--from <video.mp4>` extraction, word-level timestamps, confidence-threshold filter** — all out. Surfaced during this brainstorm but filed as separate follow-ups.
- **Negative-offset end anchors (`--end -30`) are out.** Grammar stays boringly forward-counting. Revisit only if a real "trim known-bad tail" workflow shows up.

---

## Key Decisions

- **Typed JSONL line schema with `type` discriminator.** Self-describing, forward-compatible, error-tolerant mid-stream. Decided over bare-segment lines despite extra agent parsing cost.
- **File-relative timestamps under windowing.** Round-tripping into the original file (search, citation, jump-to-time) is the dominant use case. Window-relative timestamps would force every consumer to add an offset they don't have.
- **`--stream` implies JSONL.** No plaintext streaming. Humans who want line-by-line text can pipe through `jq -r '.text // empty'`. Avoids a second format permutation.
- **Streaming is CLI-only; MCP gets windowing only.** Cleanest agent contract; MCP's request/response model is preserved; cost is bounded.
- **Phasing: bundle both into v0.2.** Original PLAN.md scheduled `--stream` for v0.3 and didn't list windowing. Windowing belongs with MCP (v0.2) because MCP needs it for long-file use cases. Streaming shares enough design surface (JSONL schema, source typing) that splitting introduces churn. Update PLAN.md §8 to move both features to v0.2.
- **Time grammar accepts both float-seconds and `HH:MM:SS` / `MM:SS` on the CLI.** Examples: `--start 90`, `--start 90.5`, `--start 1:30`, `--start 1:30:00`. MCP stays numeric seconds only (no string parsing across the JSON-RPC boundary). Cheap ergonomics win for humans without leaking ambiguity into the agent contract.

---

## Dependencies / Assumptions

- **Assumption — SpeechAnalyzer can be fed a bounded audio range.** `analyzer.analyzeSequence(from: url)` accepts a full URL; windowing likely requires the manual AVAudioConverter + buffer-feed path (the same path steno uses for live capture) where we read a `[startFrame, endFrame)` slice via `AVAudioFile.read(into:)` and feed buffers. To verify during planning.
- **Assumption — SpeechAnalyzer's `for try await result in transcriber.results` loop yields finalized segments in audio-monotonic order.** True today in our experience; confirm in planning and add a sort fallback if not.
- **Dependency — `confidence` may be absent on segments** (already flagged in PLAN.md §6). Streaming inherits the same nullable semantics; document it.
- **No new third-party dependencies.** Implementation reuses `swift-argument-parser`, AVFoundation, and our existing SpeechAnalyzer pipeline.

---

## Outstanding Questions

### Resolve Before Planning

_None. All user decisions resolved during brainstorm — see **Key Decisions** and **Scope Boundaries**._

### Deferred to Planning

- [Affects R7, R8][Technical] Exact API path for bounded analysis: manual buffer feed via `AVAudioConverter` (mirrors steno daemon) vs. any cleaner Apple-provided affordance for `analyzeSequence` over a sub-range. Decide during planning after reading the SpeechAnalyzer headers.
- [Affects R5][Technical] SIGINT handling concretely: `Task.cancel()` propagation through the SpeechAnalyzer pipeline, ensuring the in-flight `result` is allowed to complete before we emit the `end` line. Likely a `withTaskCancellationHandler` wrapper; pin down during planning.
- [Affects R3][Technical] Whether `setlinebuf(stdout)` is sufficient or we need explicit `fflush` after each line for the JSONL stream to behave under all stdio configurations (e.g. when stdout is a pipe to an agent).
- [Affects R13][Technical] How MCP gets the file's `durationSeconds` cheaply for pre-flight window validation without decoding the full file. `AVURLAsset.duration` should suffice; verify it works for `.m4a` from Voice Memos with Apple's specific muxer.

---

## Next Steps

`-> /ce-plan` for structured implementation planning. Suggested first planning actions:

1. Verify the bounded-range analysis path (Dependencies / Assumptions, first bullet) by reading the SpeechAnalyzer / SpeechTranscriber headers and the steno daemon's manual buffer-feed code.
2. Sequence MCP windowing (R7, R8, R11, R12, R13) before CLI streaming (R1–R6) — windowing is the smaller surface and shakes out the time-window plumbing that streaming reuses.
3. Update `docs/PLAN.md` §8 to move `--stream` from v0.3 to v0.2 alongside the new windowing entries, and update §2 Non-goals to reflect the typed-JSONL decision.
