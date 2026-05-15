# dictamac — Implementation Plan

A macOS CLI that transcribes audio files via Apple's macOS 26 SpeechAnalyzer. Single binary, two transports (CLI + MCP), with first-class support for Apple Voice Memos.

This document is the source of truth for what we are building and how. It assumes a senior Swift developer familiar with macOS development; references to other projects' code (notably [steno](https://github.com/jwulff/steno)) point at concrete, reusable implementations.

---

## 1. Overview & Motivation

Apple's macOS 26 SpeechAnalyzer / SpeechTranscriber API runs a high-quality on-device speech model that ships with the OS — no model download, no GPU, no Python. The model is exposed to apps but Apple does not provide a CLI for "give me a transcript of this audio file."

Voice Memos, specifically, transcribes recordings only when the app decides to. There is no public way to force-trigger transcription for a recording that hasn't been processed.

dictamac is a thin, agent-shaped wrapper that fills both gaps with one binary:

- `dictamac path/to/audio.m4a` — plaintext transcript to stdout
- `dictamac --voice-memo "yesterday's standup"` — find and transcribe a Voice Memo
- `dictamac --mcp` — the same functionality as an MCP stdio server, callable by AI agents

Primary consumer: AI agents that need to transcribe a file as part of a larger workflow. Humans get a clean stdout contract as a side effect.

---

## 2. Goals & Non-goals

### Goals

- **Agent-first ergonomics.** Stable stdout contract, predictable exit codes, structured JSON output on demand, MCP transport from day one.
- **Lightweight.** Single Swift binary, ad-hoc signed, no daemon, no on-disk cache, no model download. Fast cold start.
- **macOS-native.** Uses SpeechAnalyzer exclusively. No fallback to the legacy `SFSpeechRecognizer`. The runtime workaround for SpeechAnalyzer issues is to fix the environment (main RunLoop, `@MainActor`, signing), not downgrade APIs.
- **Voice-Memos-aware.** First-class support for the most common input shape: a `.m4a` in the Voice Memos library.

### Non-goals

- Live mic / system audio capture. ([steno](https://github.com/jwulff/steno) covers that.)
- Speaker diarization. Not exposed by Apple's public API; out of scope until/unless Apple adds it.
- SRT / VTT subtitle output in the MVP. The focus is agent-consumable, not human subtitle workflow. Plausible v1.x add.
- Streaming partial transcripts to stdout. Plausible later flag (`--stream`); MVP returns the full result at completion.
- Multi-language auto-detection. Single locale per invocation; defaults to system locale.
- Pre-macOS-26 fallback or non-macOS support.
- Becoming a steno subcommand or bundling into steno's binary.

---

## 3. Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                       dictamac (binary)                      │
│                                                              │
│   ┌─────────────────────┐    ┌──────────────────────────┐    │
│   │   CLI transport     │    │   MCP transport          │    │
│   │   (argv parsing,    │    │   (JSON-RPC over         │    │
│   │    stdout/stderr,   │    │    stdin/stdout)         │    │
│   │    exit codes)      │    │                          │    │
│   └─────────────────────┘    └──────────────────────────┘    │
│              \                       /                       │
│               \                     /                        │
│                ▼                   ▼                         │
│        ┌──────────────────────────────────┐                  │
│        │       TranscriptionRequest       │                  │
│        │  (source, locale, format)        │                  │
│        └──────────────────────────────────┘                  │
│                       │                                      │
│         ┌─────────────┴─────────────┐                        │
│         ▼                           ▼                        │
│ ┌───────────────┐         ┌─────────────────────┐            │
│ │ VoiceMemos    │         │  AudioFileResolver  │            │
│ │ Index         │         │  (path or stdin)    │            │
│ └───────────────┘         └─────────────────────┘            │
│         │                           │                        │
│         └───────────┬───────────────┘                        │
│                     ▼                                        │
│             ┌─────────────────┐                              │
│             │  Transcriber    │  (SpeechAnalyzer wrapper)    │
│             └─────────────────┘                              │
│                     │                                        │
│         ┌───────────┴───────────┐                            │
│         ▼                       ▼                            │
│   ┌──────────────┐       ┌──────────────┐                    │
│   │ Plaintext    │       │ JSON         │                    │
│   │ formatter    │       │ formatter    │                    │
│   └──────────────┘       └──────────────┘                    │
└──────────────────────────────────────────────────────────────┘
```

Key invariants:

- The two transports (CLI / MCP) are **thin shells** over the same core. Behavior parity is a hard requirement, enforced by tests.
- **Errors go to stderr; transcript content goes to stdout.** Stdout is reserved for the artifact a caller would pipe.
- **Exit code 0 on success, non-zero on any failure.** Specific codes by failure class (see §9).
- **No state persisted between invocations.** No daemon, no cache file. The locale model is the only on-disk state, and that's owned by the OS.

---

## 4. CLI Surface

```bash
# Default: transcribe a file to stdout
dictamac path/to/audio.m4a

# JSON output with timestamps + confidence
dictamac --json path/to/audio.m4a

# Locale override (default: system locale)
dictamac --locale en-US path/to/audio.m4a
dictamac --locale ja-JP recording.wav

# Voice Memos lookup (returns most recent match)
dictamac --voice-memo "yesterday's standup"
dictamac --voice-memo "walk"
dictamac --voice-memo 2026-05-12       # ISO date — most recent on that day

# List Voice Memos
dictamac --list-voice-memos                    # default: 30 most recent
dictamac --list-voice-memos --since 7d
dictamac --list-voice-memos --limit 5

# Read audio from stdin
cat audio.m4a | dictamac -

# MCP stdio server mode
dictamac --mcp

# Misc
dictamac --version
dictamac --help
dictamac --verbose path/to/audio.m4a    # stderr gets per-step timing
```

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Generic / unclassified error |
| 2 | Argument parsing error |
| 64 | No audio file at the given path |
| 65 | Audio decode failed (unsupported codec, corrupt file) |
| 66 | Voice Memos query returned no match |
| 67 | SpeechAnalyzer unavailable (running on macOS < 26 or model not installed) |
| 73 | Required TCC permission missing (Speech Recognition, or Files & Folders for Voice Memos) |
| 74 | Voice Memos library not found at any known path |

These codes are stable across versions; tests assert their values.

### Output Streams

- **stdout** — transcript content (plaintext, or JSON if `--json`). One trailing newline. Nothing else.
- **stderr** — diagnostics, progress (with `--verbose`), errors, deep-links for TCC prompts.

---

## 5. MCP Surface

`dictamac --mcp` speaks MCP over stdio per the Model Context Protocol specification, JSON-RPC 2.0 transport.

### Server Identity

- Name: `dictamac`
- Version: from package version, e.g. `0.1.0`
- Vendor: `jwulff`
- Capabilities: `tools` only (no resources, no prompts, no sampling)
- Protocol version: pinned to `"2024-11-05"` in the `initialize` response (the current widely-deployed MCP spec version as of the project's start). Bumping this string requires updating the MCP integration test snapshot in `Tests/DictamacMCPTests/` so the new version is exercised end-to-end.

### Tools

#### `transcribe_file`

Transcribe an audio file at a given absolute path.

```json
{
  "name": "transcribe_file",
  "description": "Transcribe an audio file via Apple's on-device SpeechAnalyzer. Returns plaintext by default, or a structured transcript with timestamps when format=\"json\".",
  "inputSchema": {
    "type": "object",
    "properties": {
      "path": {"type": "string", "description": "Absolute path to the audio file."},
      "locale": {"type": "string", "description": "BCP-47 locale (e.g. en-US). Defaults to system locale."},
      "format": {"type": "string", "enum": ["text", "json"], "default": "text"}
    },
    "required": ["path"]
  }
}
```

Returns: tool result `content` is a single `text` item containing either the plaintext transcript or a JSON-stringified transcript object (see §6 for schema).

#### `transcribe_voice_memo`

Resolve a Voice Memo by query, transcribe, return the same result shape as `transcribe_file`. The query grammar in §7 U6 (`--voice-memo` table) is the **same** grammar exposed by MCP's `transcribe_voice_memo.query`; the implementation lives in `DictamacCore` and is imported by both transports.

```json
{
  "name": "transcribe_voice_memo",
  "description": "Find a Voice Memo by title or date and transcribe it. The Voice Memos app does not always auto-transcribe; this tool transcribes on demand.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "query": {"type": "string", "description": "Substring match against Voice Memo titles, or time anchor (today, yesterday, this morning), or ISO date (YYYY-MM-DD), or an identifier from list_voice_memos."},
      "locale": {"type": "string"},
      "format": {"type": "string", "enum": ["text", "json"], "default": "text"}
    },
    "required": ["query"]
  }
}
```

#### `list_voice_memos`

List Voice Memos with metadata so the agent can pick one to transcribe.

```json
{
  "name": "list_voice_memos",
  "description": "List Voice Memos in reverse chronological order with their titles, recording dates, and durations.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "since": {"type": "string", "description": "Duration string (7d, 2w, 1m) or ISO date. Default: 30d."},
      "limit": {"type": "integer", "minimum": 1, "maximum": 100, "default": 30}
    }
  }
}
```

Returns: JSON array of `{title, recordedAt, durationSeconds, identifier}`. The `identifier` can be passed back as `transcribe_voice_memo.query` for exact match.

### Errors

Tool errors use MCP's `isError: true` shape, not JSON-RPC-level errors:

```json
{
  "content": [{"type": "text", "text": "Voice Memos library not found at any known path. Searched: ~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/, ~/Library/Application Support/com.apple.voicememos/Recordings/"}],
  "isError": true
}
```

This gives the agent a structured failure message it can react to, rather than a protocol-level fault.

---

## 6. JSON Transcript Schema

When `format=json` (CLI `--json`, or MCP `format: "json"`), stdout receives a single JSON object:

```json
{
  "version": "1",
  "locale": "en-US",
  "durationSeconds": 184.3,
  "model": "SpeechAnalyzer/macOS26",
  "source": {
    "type": "file",
    "path": "/absolute/path/to/audio.m4a"
  },
  "segments": [
    {
      "startSeconds": 0.0,
      "endSeconds": 3.2,
      "text": "Hey everyone, thanks for jumping on.",
      "confidence": 0.94
    }
  ],
  "fullText": "Hey everyone, thanks for jumping on. ..."
}
```

Notes:

- `version` is a string ("1"), bumped on incompatible changes
- `fullText` is `segments[].text` joined with single spaces — provided so callers can pick their granularity without re-concatenating
- For Voice Memos, `source.type` is `"voice-memo"` with `identifier` and `title` instead of `path`
- `confidence` may be absent on segments where SpeechAnalyzer doesn't expose it; treat absence as "unknown"
- "Absent" means the JSON key is **omitted entirely** from the segment object (NOT `null`). `JSONFormatter` must drop the key when confidence is unknown; tests must assert key omission, not a `null` value.
- `fullText` for zero segments is the empty string `""`. The CLI plaintext output for zero segments is a single newline `"\n"` — the universal stdout contract in §4 ("one trailing newline, nothing else") applies even when the transcript is empty, so empty-transcript runs behave identically to non-empty ones for downstream consumers.

---

## 7. Implementation Units

Each unit is independently testable. Numbered for cross-reference; not necessarily merge order.

### U1 — Project skeleton

- Swift Package Manager (`Package.swift`) with one executable target `dictamac`
- Swift tools-version 6.0+; macOS 26 deployment target
- Dependency: `swift-argument-parser` (latest stable)
- `Makefile` with targets: `build`, `build-debug`, `sign`, `install`, `test`, `run`, `clean`
- `Resources/Info.plist` with `CFBundleIdentifier = com.dictamac.cli` and TCC usage descriptions
- `Resources/dictamac.entitlements`

### U2 — Code signing & entitlements

Match the proven steno daemon pattern. Entitlements:

```xml
<dict>
    <key>com.apple.security.device.audio-input</key><true/>
    <key>com.apple.security.cs.disable-library-validation</key><true/>
    <key>com.apple.security.cs.allow-jit</key><true/>
</dict>
```

**Do NOT use `com.apple.developer.speech-recognition`.** It is a restricted entitlement requiring a provisioning profile. CLI binaries cannot embed profiles, so AMFI will SIGKILL the binary on launch. SpeechAnalyzer does not need this entitlement.

Build pipeline:

1. `swift build -c release` with `-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Resources/Info.plist` to embed the plist (use `-Xlinker`, NOT `-Xswiftc` — `swiftc` rejects `-sectcreate` as an unknown argument; it is a linker flag)
2. `codesign --sign - --options runtime --entitlements Resources/dictamac.entitlements --force .build/release/dictamac`

`swift run` SKIPS code-signing and will crash with SIGTRAP. Always use `make run`.

### U3 — CLI parser

`swift-argument-parser` root command. Mutual-exclusivity rules:

- `--mcp` is a top-level mode; it ignores all other content flags
- `--list-voice-memos` is a top-level mode; no audio input expected
- Exactly one input source must be present (unless in `--mcp` or `--list-voice-memos` mode):
  - Positional path argument
  - `-` (literal dash) reads audio from stdin
  - `--voice-memo <query>`

Flags:

- `--json` — emit JSON instead of plaintext
- `--locale <BCP-47>` — locale override
- `--since <duration>` — for `--list-voice-memos`
- `--limit <int>` — for `--list-voice-memos`
- `--verbose` — per-step timing to stderr
- `--version`, `--help`

### U4 — Audio loading

Two intake paths:

- **File path**: `AVAudioFile(forReading: url)`, capture `processingFormat` for diagnostics. Reject early if file missing (exit 64) or `AVAudioFile` throws (exit 65 with the underlying error on stderr).
- **Stdin**: `FileHandle.standardInput.readToEnd()` drains bytes into a temp file in `NSTemporaryDirectory()` with an appropriate extension (default to `.m4a` if container detection is inconclusive — `AVAudioFile` will tell us if it's wrong). `defer` cleanup.

### U5 — SpeechAnalyzer pipeline

The core. Reuses the pattern from [steno's daemon](https://github.com/jwulff/steno/blob/main/daemon/Sources/StenoDaemon/Engine/DefaultSpeechRecognizerFactory.swift).

```swift
@MainActor
func transcribe(url: URL, locale: Locale) async throws -> Transcript {
    let transcriber = SpeechTranscriber(
        locale: locale,
        transcriptionOptions: [],
        reportingOptions: [],
        attributeOptions: [.audioTimeRange]
    )
    let analyzer = SpeechAnalyzer(modules: [transcriber])

    async let analyzed: Void = {
        try await analyzer.analyzeSequence(from: url)
        try await analyzer.finalizeAndFinish(through: .greatestFiniteMagnitude)
    }()

    var segments: [TranscriptSegment] = []
    for try await result in transcriber.results {
        guard result.isFinal else { continue }
        let range = result.range(of: .audioTimeRange)
        segments.append(TranscriptSegment(
            startSeconds: range?.lowerBound.seconds ?? 0,
            endSeconds: range?.upperBound.seconds ?? 0,
            text: result.text,
            confidence: result.confidence
        ))
    }
    try await analyzed
    return Transcript(segments: segments, locale: locale, ...)
}
```

**Critical runtime properties** (proven in steno — do not deviate without a strong reason):

1. **`SpeechAnalyzer.start()` / `analyzeSequence` MUST run on `@MainActor`.** Crashes with SIGTRAP otherwise.
2. **The main RunLoop must be alive.** Entry point uses `ParsableCommand` (NOT `AsyncParsableCommand`) plus `dispatchMain()` after launching the async work in a `Task {}`.
3. **The locale model must be installed.** First run downloads it; subsequent runs are immediate. Detect via the SpeechTranscriber installed-locales API and surface a clear stderr message during the first-run download so an agent (or human) sees what's happening.

`analyzer.analyzeSequence(from: url)` handles format conversion internally for file input. The manual `AVAudioConverter` step in steno's daemon is only needed on the live-streaming path.

`.volatileResults` is appropriate for live-streaming pipelines like steno's daemon; for file transcription we want only final results, so omit it (`reportingOptions: []`).

### U6 — Voice Memos discovery

The Voice Memos library lives at one of:

- `~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/`
- `~/Library/Application Support/com.apple.voicememos/Recordings/`

Exact location depends on macOS version and iCloud sync settings. The discovery code:

1. Probes both candidate paths; picks the first that exists
2. Reads metadata from `CloudRecordings.db` (SQLite) when present: title, creation date, duration, asset path
3. Falls back to a filesystem scan of `*.m4a` files when the SQLite file is unavailable or unreadable, using extended attributes for title/date

Query grammar for `--voice-memo` / MCP `transcribe_voice_memo.query`:

| Form | Behavior |
|------|----------|
| Bare string | Fuzzy substring match against title; return most recent match |
| `today`, `yesterday`, `this morning` | Time-anchored; return most recent in that window |
| ISO date `2026-05-12` | Return recordings on that date (most recent if multiple) |
| Identifier (from `list_voice_memos` output) | Exact match |

The Voice Memos library is sandboxed; accessing it may require Files & Folders TCC permission. Surface this clearly with exit code 73 + a stderr message including the deep-link to System Settings.

The filesystem-fallback scanner walks `*.m4a` files **recursively** — Voice Memos may nest recordings inside per-iCloud-account or per-date subdirectories. Skip hidden files and the `.Trash` directory.

The TCC deep-link for the Files & Folders Sandbox prompt is `x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders` — surface this on stderr when exit code 73 fires from a Voice Memos access denial. Verify the URL against a live macOS 26 system before relying on it in production messaging.

The `CloudRecordings.db` schema is private and may change in future macOS versions. **Treat SQLite as an optimization, not a contract.** The filesystem fallback is the resilience plan.

### U7 — Output formatters

Two formatters, both pure functions of `Transcript`:

- `PlaintextFormatter` — produces the plaintext transcript with these exact steps, in order, so the output is unambiguous:
    1. For each segment, take `segment.text` and trim leading/trailing whitespace (Unicode whitespace per `CharacterSet.whitespacesAndNewlines`).
    2. **Filter out segments whose trimmed text is empty** — this includes both originally-empty segments and whitespace-only segments (e.g. `" "`, `"\t"`, `"\n"`), which trim to `""`. These dropped segments do NOT participate in the join, so they cannot introduce double spaces between surviving neighbors.
    3. Collapse runs of internal whitespace within each remaining trimmed segment to a single ASCII space.
    4. Join the resulting (non-empty) segments with a single ASCII space `" "`.
    5. Append exactly one trailing newline `"\n"` (always, including when the joined string is empty — see §6 zero-segment note).
  This guarantees no double spaces in the output regardless of segment-internal whitespace or the presence of whitespace-only segments, and no timestamps appear in plaintext.
- `JSONFormatter` — emits the schema in §6 using `JSONEncoder` with `outputFormatting: [.prettyPrinted, .sortedKeys]` for human-readable, deterministic output (matters for snapshot tests).

Both write to a passed-in `TextOutputStream` so MCP can capture the formatted result into a tool response.

### U8 — MCP server (JSON-RPC stdio)

Implement MCP stdio transport directly — no third-party Swift MCP SDK dependency. The surface is small and well-specified.

Loop:

1. Read JSON-RPC requests line-buffered from stdin via `FileHandle.standardInput`
2. Dispatch by method name:
   - `initialize` → respond with server identity + capabilities (`tools` only)
   - `tools/list` → respond with the three tool schemas (§5)
   - `tools/call` → dispatch to the core transcription pipeline; serialize the result
3. Write responses to stdout, one JSON object per line, flush after each
4. Diagnostics and non-protocol errors go to stderr; the JSON-RPC channel stays clean

Tool error responses use the MCP `isError: true` content shape (§5). Bad params raise JSON-RPC `-32602`; method-not-found raises `-32601`.

Pin the MCP protocol version explicitly in the `initialize` response. Bump deliberately when adopting newer protocol revisions.

### U9 — Error handling

A single `DictamacError` enum covers the recoverable failure classes:

```swift
enum DictamacError: Error, CustomStringConvertible {
    case argumentError(String)
    case fileNotFound(URL)
    case audioDecodeFailed(URL, underlying: Error)
    case voiceMemoNotFound(query: String)
    case speechAnalyzerUnavailable(reason: String)
    case permissionDenied(domain: String, deepLink: URL?)
    case voiceMemoLibraryMissing(searched: [URL])
    case internalFailure(Error)
}
```

A central mapping function turns each case into:

- A stderr message (the human-readable description, with deep-links where applicable)
- An exit code (CLI mode)
- An MCP tool-error response (MCP mode)

Both transports use the SAME mapping function; behavior parity between CLI and MCP for the same failure is a hard requirement.

### U10 — Tests

Framework: Swift Testing (matches steno).

Coverage required for MVP:

- **Unit** — each formatter (snapshot tests for JSON, golden-string for plaintext), Voice Memos query parser, error code mapping, argument parser edge cases
- **Integration** — end-to-end transcription against a small public-domain audio fixture committed to `Tests/Fixtures/`. One required fixture: 5–10 seconds of clear en-US speech as `.m4a`.
- **MCP** — spawn the binary in `--mcp` mode in a subprocess; send `initialize` + `tools/list` + a `transcribe_file` call against the fixture; assert response shape and content.

Mocking: a `SpeechAnalyzerProvider` protocol allows unit tests to stub the actual SpeechAnalyzer. The integration test exercises the real one.

CI:

- macOS 26+ GitHub Actions runner (or self-hosted if not yet available)
- Pre-install the en-US locale model in a setup step
- Run `make test`

### U11 — Build & install

`Makefile`:

```make
.PHONY: build build-debug sign install test run clean

build:
	swift build -c release \
		-Xlinker -sectcreate -Xlinker __TEXT \
		-Xlinker __info_plist -Xlinker Resources/Info.plist
	$(MAKE) sign BINARY=.build/release/dictamac

build-debug:
	swift build \
		-Xlinker -sectcreate -Xlinker __TEXT \
		-Xlinker __info_plist -Xlinker Resources/Info.plist
	$(MAKE) sign BINARY=.build/debug/dictamac

sign:
	codesign --sign - --options runtime \
		--entitlements Resources/dictamac.entitlements \
		--force $(BINARY)

test:
	swift test

install: build
	mkdir -p ~/.local/bin
	cp .build/release/dictamac ~/.local/bin/

run: build-debug
	.build/debug/dictamac $(ARGS)

clean:
	swift package clean
	rm -rf .build dist
```

### U12 — Distribution

Homebrew formula at `jwulff/homebrew-tap/Formula/dictamac.rb`. Two staging options:

- **Build-from-source formula** — simpler, slower install. The right MVP choice.
- **Bottled binary** — faster install; requires releasing a signed tarball per macOS version per CPU architecture.

Plan: build-from-source for v0.1 → v0.x. Bottle once the binary stabilizes and there's signal it's worth maintaining.

Release flow:

1. Tag `vX.Y.Z` on `main`
2. CI builds release binary on macOS 26+
3. Tarball + SHA256 attached to the GitHub release
4. Update the tap formula to reference the new URL + SHA
5. `brew upgrade dictamac` from the tap

---

## 8. Phased Rollout

### MVP (v0.1)

The minimum to ship and announce.

- U1, U2, U3 — project skeleton, signing, CLI parser
- U4, U5 — audio loading, SpeechAnalyzer pipeline
- U6 — Voice Memos discovery (fuzzy + recency only; no ISO-date or identifier yet)
- U7 — plaintext + JSON formatters
- U9 — error codes and central mapping
- U10 — unit + one integration test (en-US)
- U11 — Makefile build/install
- Partial U12 — build-from-source Homebrew formula, no bottle

**Not in MVP:** `--mcp`, `--list-voice-memos`, ISO-date queries, multi-locale CI.

### v0.2 — MCP transport

- U8 — MCP server
- `--list-voice-memos` mode + the MCP tool (the CLI flag is a thin reuse)
- Voice Memos identifier-based exact-match query
- MCP integration tests

### v0.3 — Polish

- Streaming partial output (`--stream` flag; corresponding MCP behavior pending design)
- SRT / VTT output formats
- Bottled Homebrew distribution
- Multi-locale CI coverage
- Public documentation site or expanded README with example agent integrations

### Out of scope (no planned work)

- Speaker diarization
- Multi-language auto-detection
- Live audio capture — use [steno](https://github.com/jwulff/steno)
- Non-macOS platforms

---

## 9. Open Questions & Risks

| Risk | Likelihood | Mitigation |
|------|------------|-----------|
| Voice Memos `CloudRecordings.db` schema changes in macOS 27 | medium | Filesystem fallback path; treat SQLite as optimization, not contract |
| First-run locale model download looks like a hang | high | Detect missing locale assets before transcribing; clear stderr message with progress; document the one-time cost |
| MCP protocol version drift | medium | Pin protocol version in `initialize`; bump deliberately with test coverage |
| `AVAudioFile` codec gaps (legacy `.caf`, exotic containers) | low | Integration tests cover `.m4a` and `.wav`; document supported formats; rely on AVFoundation's broad coverage |
| TCC prompt for Voice Memos library invisible to agent-spawned process | medium | Exit code 73 with deep-link in stderr; agent relays to user |
| `.mcp` flag adds complexity that goes unused | low | The transport adapter is ~200 lines around a shared core; cost is bounded |

---

## 10. Reference Material

- [Apple — SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer)
- [Apple — SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber)
- [Model Context Protocol specification](https://modelcontextprotocol.io/specification)
- [Swift Argument Parser](https://github.com/apple/swift-argument-parser)
- [steno](https://github.com/jwulff/steno) — sibling project, same SpeechAnalyzer integration. Direct references for reusable patterns:
  - `daemon/Sources/StenoDaemon/Engine/DefaultSpeechRecognizerFactory.swift` — analyzer lifecycle on `@MainActor`
  - `daemon/Sources/StenoDaemon/Speech/SpeechRecognitionService.swift` — result iteration pattern
  - `daemon/Resources/StenoDaemon.entitlements` — entitlements template
  - `Makefile` — build / sign pattern (debug + release variants)
- Prior art for an Apple-native CLI without SpeechAnalyzer: [sveinbjornt/hear](https://github.com/sveinbjornt/hear) — production-grade UX but on legacy `SFSpeechRecognizer`. Useful CLI-shape reference; do NOT copy the API choice.
