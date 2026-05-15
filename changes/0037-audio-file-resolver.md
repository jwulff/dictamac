# Load audio from file path via AVAudioFile

PR: #37
Issues: Closes #11 (Refs #2)

## What changed

The file-path intake stage now exists in `DictamacCore`. Three new
types land together because they only make sense as a set:

- `AudioSource` — `.path(String)` for argv input, `.stdin` for the
  dash convention. The stdin branch is rejected with a clear error
  until #12 implements it.
- `AudioFileResolver` — `Sendable` protocol seam over
  `resolve(source:) async throws -> URL`.
- `DefaultAudioFileResolver` — opens the URL with
  `AVAudioFile(forReading:)` to confirm decodability before handing
  it downstream. Captures sample-rate / channel-count via an
  optional injected reporter closure for the CLI's eventual
  `--verbose` plumbing.

Plus the foundational `DictamacError` enum, narrowly scoped to the
two cases this stage produces (`.fileNotFound` → exit 64,
`.audioDecodeFailed` → exit 65). The enum grows one case per landed
feature; adding cases is non-breaking, renaming/removing is.

## Why

The file path is the primary input shape for both `dictamac
path/to/audio.m4a` and the MCP `transcribe_file` tool. It must
validate decodability up-front so failures surface as the stable
exit codes from PLAN.md §4 — agents react programmatically; humans
get readable stderr. If we waited until the SpeechAnalyzer
invocation to discover a bad codec, the failure shape would be
"undefined SpeechAnalyzer error" instead of "exit 65 with the
specific decode error on stderr".

The processing-format capture is the same idea: we already pay the
cost of opening the file with `AVAudioFile`, so we may as well
record the format while we have it. The CLI's eventual `--verbose`
mode wants this info; capturing it now means we don't reopen the
file later.

## How

A few decisions worth flagging:

- **Protocol returns `URL`, format capture is a side channel.** The
  literal acceptance criterion is `async throws -> URL` — keep the
  protocol minimal so non-resolver implementations (mocks, future
  voice-memo resolver) don't have to invent a `ProcessingFormatSummary`
  they can't produce. Format goes through an optional reporter
  closure on the concrete type. CLI's `--verbose` mode wires a stderr
  printer; tests use a thread-safe box.
- **`ProcessingFormatSummary` is a `Sendable` value type.**
  `AVAudioFormat` is an NSObject class and not `Sendable`. Extracting
  the two fields the verbose path actually needs (sample rate, channel
  count) keeps the cross-actor surface clean without `@unchecked`.
- **`AudioResolverError.stdinNotYetImplemented` is carried inside
  `DictamacError.audioDecodeFailed`.** When #12 lands, the stdin path
  in `DefaultAudioFileResolver.resolve` switches to the real
  implementation and this marker disappears. Until then, premature
  stdin wire-ups surface as a recognizable error with a
  `localizedDescription` that names the responsible issue (`#12`).
- **Synthesized fixtures only.** WAV via `AVAudioFile(forWriting:)`,
  M4A via `AVAssetWriter` (AVAudioFile only writes linear PCM
  containers), corrupt file via 64 random bytes. The CLAUDE.md rule
  forbids committed recordings; runtime synthesis keeps fixtures
  reproducible without binary blobs.
- **Tilde expansion happens before `FileManager.fileExists`.** Without
  it, an obviously-present file at `~/foo.m4a` surfaces as
  `.fileNotFound` because `FileManager` doesn't expand `~`. The fix
  is one `(path as NSString).expandingTildeInPath` call; the
  surprise potential of leaving it out is high enough that an
  explicit test pins the behavior.

## Follow-ups

- #12 — stdin intake via temp file (the rejection branch this PR
  added is the placeholder)
- #15 — locale model detection (orthogonal to file loading but lands
  another `DictamacError` case: exit code 67)
- #19 — SpeechAnalyzer pipeline (consumes the resolved URL produced
  by this stage)
- #13 — CLI root command (wires the resolver, the formatters, and
  whatever Transcriber implementation lands first)
