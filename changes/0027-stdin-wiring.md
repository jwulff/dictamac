# Wire stdin intake and unify file path through the resolver

PR: TBD
Issues: Closes #27 (Refs #3)

## What changed

Both the file-path and stdin handlers in `ModeHandlers.production(...)`
now route audio intake through `AudioFileResolver.resolve(source:)`
before invoking `Transcriber.transcribe(_:)`. The two handlers share a
single helper, `runResolveAndTranscribe(...)`, that:

1. Calls `resolver.resolve(source:)`. fileNotFound (exit 64) and
   audioDecodeFailed (exit 65) — including empty-stdin — originate here
   for both intake paths.
2. Builds a `TranscriptionRequest` with `.file(resolved.url)` for path
   inputs and `.stdin(resolved.url)` for stdin inputs.
3. Calls `transcriber.transcribe(request)`.
4. Renders the transcript with `JSONFormatter` or `PlaintextFormatter`
   and writes the rendered bytes to stdout.
5. Calls `resolved.cleanup()` on every exit path (success, decode
   failure, transcriber failure), then exits with the appropriate code.

The stdin handler is no longer a stub — `cat audio.m4a | dictamac -`
now produces the same stdout as `dictamac audio.m4a`. Empty stdin
(`:  | dictamac -`) and garbage bytes both map to exit code 65 with the
underlying error surfaced on stderr; a non-existent file path maps to
exit code 64.

The `StubMessages.stdinNotImplemented` constant and its associated test
have been removed; the new dispatcher-level behavior is exercised by
`Tests/DictamacCLITests/ResolverWiringTests.swift`.

## Why

Before this change, only the file-path handler did real work, and it
opened the file twice (once for existence/decode validation, once
inside `DefaultTranscriber`). The stdin handler was a stub that just
errored out. The architectural intent — and the seam tests already
assume — is that both intakes go through the same `AudioFileResolver`
seam, with errors mapped uniformly at that layer rather than
re-implemented per handler.

Consolidating the two paths also means future input kinds (e.g. URLs,
voice-memo lookups once epic #4 lands) only need to teach the resolver
a new `AudioSource` variant; the dispatcher loop stays unchanged.

## How

`runResolveAndTranscribe(source:resolver:transcriber:localeIdentifier:wantsJSON:verbose:writeStdout:writeStderr:exit:)`
is a top-level function in `Sources/DictamacCLI/ModeDispatch.swift`.
The `writeStdout` / `writeStderr` / `exit` parameters default to
`FileHandle.standardOutput`, `FileHandle.standardError`, and
`Darwin.exit(_:)` respectively; tests inject `Void`-returning closures
that record what production would have written so they can assert
without terminating the process. The function uses explicit `return`s
after every `exit(...)` so the test path stops at the first exit
rather than falling through into the success branch.

The function returns `async -> Void` (not `Never`) precisely so the
test injection works. In production the first `exit(_:)` call is
`Darwin.exit` and never returns; the explicit `return` afterward is
dead code that the compiler tolerates because the closure parameter
type is `(Int32) -> Void`. Documenting this contract in the function's
doc-comment so a future refactor doesn't accidentally tighten the
signature back to `Never` and break the test seam.

## Tradeoff: double-validation of the file path

`DefaultAudioFileResolver` opens the audio file with
`AVAudioFile(forReading:)` to validate decodability, then
`DefaultTranscriber` opens it again inside the transcription pipeline.
The redundancy is deliberate: collapsing the two opens would require
threading a pre-opened `AVAudioFile` through `TranscriptionRequest`,
which the CLI and MCP transports both depend on, and changes the
protocol seam shape for a negligible win (a second open on the same
file completes in a few milliseconds versus the multi-second
SpeechAnalyzer bootstrap that dominates the request lifetime). The
resolver's fail-fast is what produces the deterministic exit codes
agents rely on, so it stays. See the function's doc-comment for the
permanent record.

## swift-argument-parser dash positional

The literal-dash positional already worked out of the box: the parser
treats `-` as an ordinary positional value when the `@Argument` is
declared as `String?` (it only interprets `--option` and `-o` prefixes
as flags). The pre-existing `dashPositionalIsAcceptedAsStdinMarker`
test in `DictamacParsingTests` pinned this behavior in PR #42; this PR
just wires the resolved `.stdin` mode through to actual work.

## Test surface

- `Tests/DictamacCLITests/ResolverWiringTests.swift` — 9 new tests
  pinning the resolver-first dispatch invariants (file path goes
  through resolver, stdin goes through resolver, fileNotFound maps to
  64, empty stdin maps to 65, decode failure maps to 65, cleanup runs
  on success and failure, plaintext vs JSON output formatters).
- `Tests/DictamacCLITests/Mocks/MockAudioFileResolver.swift` and
  `Tests/DictamacCLITests/Mocks/MockTranscriber.swift` — actor-based
  test doubles, kept independent of the core test target so the CLI
  test target doesn't pull `DictamacCoreTests` into its build.
- End-to-end verification against the committed
  `Tests/DictamacSpeechTests/Fixtures/hello-world.m4a` confirms the
  release binary produces identical stdout for `dictamac fixture` and
  `cat fixture | dictamac -`.
