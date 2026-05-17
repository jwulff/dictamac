# Load audio from stdin via temp file

PR: TBD
Issues: Closes #12 (Refs #2)

## What changed

The `.stdin` branch of `DefaultAudioFileResolver` now actually works.
`cat audio.m4a | dictamac -` is a real input mode, not a placeholder
that throws "see issue #12".

Concretely:

- `DefaultAudioFileResolver` gained an injectable `stdinProvider`
  closure that returns a `FileHandle`. Production defaults to
  `FileHandle.standardInput`; tests pass the read end of a `Pipe()`.
  The same injection seam also accepts a `diagnosticSink` for
  stderr-bound warnings (cleanup failures) and a test-only
  `tempFileObserver` for leak-detection assertions.
- The resolver's protocol return type changed from `URL` to a new
  `ResolvedAudio` value type that bundles the URL with a `cleanup()`
  hook. The `.path` branch's cleanup is a no-op (we don't own that
  file); the `.stdin` branch's cleanup deletes the staged temp file.
  Cleanup is idempotent (one-shot atomic flag), non-throwing, and
  routes any deletion failures to the resolver's `diagnosticSink`
  rather than failing the surrounding transcription.
- Empty stdin (zero bytes drained) surfaces as
  `DictamacError.audioDecodeFailed` (exit 65) carrying
  `AudioResolverError.stdinEmpty`, whose `errorDescription`
  bridges through `LocalizedError` so the stderr message says
  exactly "stdin was empty — no bytes were piped in" rather than
  the generic AVFoundation codec error against a zero-byte file.
- Garbage bytes flow through `AVAudioFile(forReading:)` validation
  identically to the corrupt-file branch — same exit code 65, same
  error shape. The temp file is deleted before the error propagates;
  the success path defers deletion to the caller via `cleanup()`.
- The previous `AudioResolverError.stdinNotYetImplemented` marker is
  gone — its only purpose was to keep the "issue #12" pointer
  visible until #12 landed, and it has now landed.

## Why

Reading audio from stdin unlocks the pipeline-style agent use case the
project was built for: `curl ... | ffmpeg ... | dictamac -`. The MVP
deliberately drains the whole pipe to a temp file rather than streaming,
because `SpeechAnalyzer.analyzeSequence(from:)` is a file-mode API —
streaming intake would need a different SpeechAnalyzer surface and is
explicitly deferred (see "Out of scope" below).

The `ResolvedAudio` cleanup hook captures the central contract issue #12
asked for: the transcription pipeline calls `resolve(source:)`, holds the
URL through the SpeechAnalyzer call, then invokes `cleanup()` on the way
out. On the `.path` branch that's a no-op; on the `.stdin` branch it
deletes the staged temp file. Both branches use the same call shape, so
the eventual SpeechAnalyzer wrapper (issue #19) doesn't need to know
which branch it's holding.

## How

A few design choices worth flagging:

- **Cleanup belongs on the returned value, not the protocol.** The
  alternative — adding a `cleanup(_:)` method to the
  `AudioFileResolver` protocol — would mean the SpeechAnalyzer wrapper
  has to hold a reference to the resolver after the resolve call
  completes, which leaks resolver state across the seam. A
  self-contained `ResolvedAudio` value carries its own cleanup closure
  and crosses actor boundaries cleanly.
- **Cleanup is idempotent.** `cleanup()` may be called more than once
  (defer + explicit, or error-recovery paths) so a private
  `AtomicFlag` short-circuits subsequent calls. Calling cleanup on
  an already-deleted file is also fine — `removeTempFile` catches
  `CocoaError.fileNoSuchFile` and treats it as success.
- **Cleanup failures never throw.** Issue #12's contract says cleanup
  must not fail the surrounding transcription if the transcript was
  already produced. Failures route to the injected `diagnosticSink`
  (stderr by default), formatted as a `dictamac: warning:` line.
- **`AVAudioFile` validation runs against the temp file too.** Same
  decode-validation pass as the `.path` branch — codec errors,
  truncated containers, and wrong-container situations all surface
  as exit 65 with the underlying AVFoundation error preserved. On
  validation failure we delete the temp file before the error
  propagates so there's no leak on the error path.
- **`.m4a` is documented as the default container.** PLAN.md §7 U4
  says "default to `.m4a` if container detection is inconclusive —
  `AVAudioFile` will tell us if it's wrong". We don't sniff magic
  bytes; if the user pipes a `.wav` in, AVAudioFile reads it fine
  regardless of extension. If they pipe garbage, AVAudioFile throws
  and we return exit 65. Container detection is an explicit
  out-of-scope item.
- **`readToEnd()` returning nil is treated as empty.** Per
  `FileHandle.readToEnd()` docs the optionality represents "no
  bytes available". Both `nil` and `Data()` route to
  `AudioResolverError.stdinEmpty` — empty is empty regardless of
  which signal the OS produces.

## Test coverage

Six new tests under `AudioFileResolverTests`:

- `stdinEmptyMapsToAudioDecodeFailedWithExitCode65` — zero-byte pipe →
  exit 65 + "stdin" + "empty" in the message
- `stdinValidM4APipedThroughResolves` — a synthesized silent `.m4a`
  fixture piped through an injected `FileHandle` resolves to a temp
  URL under `NSTemporaryDirectory()` with extension `.m4a`; cleanup
  removes it
- `stdinGarbageBytesMapToAudioDecodeFailedWithExitCode65` — 128 random
  bytes → exit 65 and the temp file the resolver staged is deleted
  before the error propagates (via `tempFileObserver` leak-check)
- `stdinSuccessfulResolveCleansUpWhenCleanupCalled` — 8 sequential
  resolves with unique temp paths, all cleaned up
- `stdinThrownErrorAlsoCleansUpTempFile` — explicit assertion that the
  temp file is gone after the resolver throws
- `stdinCleanupFailureDoesNotThrow` — double-call cleanup, and cleanup
  after the file has been deleted out from under us, both complete
  silently

The existing `.path` tests were updated to use `.url` / `.cleanup()`
through the new `ResolvedAudio` shape; behavior unchanged.

The placeholder `stdinDecodeFailedUnderlyingSurfacesIssuePointer` test
is removed — its only purpose was to assert the "see issue #12" error
message that no longer exists.

## Follow-ups

- #19 — SpeechAnalyzer pipeline (now consumes the `.cleanup()` hook in
  its `defer`)
- #13 — CLI root command (parses `-` argv → `.stdin` source)
- Streaming intake (out of scope, no issue yet) — would replace the
  drain-to-temp-file approach with a `SpeechAnalyzer.start(inputSequence:)`
  variant that consumes an `AsyncSequence<AVAudioPCMBuffer>`. The
  current shape is correct for the file-mode SpeechAnalyzer call we
  actually use today.
