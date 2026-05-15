# Define Transcriber protocol and transcript model types

PR: #34
Issues: Closes #10 (Refs #2)

## What changed

`DictamacCore` now defines the single seam every downstream component
will depend on: a `Transcriber` protocol over a `TranscriptionRequest` →
`Transcript` pipeline, plus the v1 JSON schema from PLAN.md §6 baked
into the Codable conformances. Both the CLI and MCP transports will
plug into the protocol — never the concrete `SpeechAnalyzer`-backed
implementation that lands later in the speech track.

Also includes `MockTranscriber` in `Tests/.../Mocks/` so every
downstream test target can reuse one shared stub. The placeholder
source/test files from the scaffolding PR (#29) are removed.

## Why

Per the project's protocol-first rule, no concrete service can be
written until the seam it sits behind exists. Issue #10 was the
"unblock the speech track" prerequisite — until the protocol and the
schema-bound types exist, #11 (file loading), #12 (stdin), #15 (locale
model detection), #19 (SpeechAnalyzer wrapper), and #21
(`JSONFormatter`) can't land cleanly.

The §6 JSON schema is the public contract MCP agents consume. Embedding
it in the type's own Codable conformance means future contributors
can't accidentally drift the wire format by editing a formatter in
isolation — the encoding lives with the type.

## How

A few decisions worth flagging:

- **`confidence` is omitted, not `null`, when unknown.**
  `TranscriptSegment.encode` uses `encodeIfPresent` so the JSON key
  disappears entirely. PLAN.md §6 is explicit about this — Swift's
  synthesized Codable for `Double?` writes `null`, which would be a
  schema drift bug. A dedicated test asserts the key is absent.

- **`TranscriptSource` as a discriminated union.** Two cases (`.file`,
  `.voiceMemo`) encode as `{type, path}` and `{type, identifier, title}`
  respectively. Hand-rolled `encode(to:)` / `init(from:)` so the
  `"voice-memo"` discriminator (kebab-case in JSON, camelCase in Swift)
  stays correct. Unknown discriminators raise `DecodingError` rather
  than silently mis-parse.

- **`Transcript.fullText` is computed, not stored.** It applies the
  PlaintextFormatter normalization (PLAN.md §7 U7) — trim, drop
  whitespace-only segments, collapse internal whitespace, join with one
  space — minus the trailing newline that the CLI plaintext surface
  adds. This keeps `cli stdout` and `mcp json.fullText` byte-aligned by
  construction; the formatter (landing in #16) gets to be a one-liner
  over `fullText`.

- **`MockTranscriber` is an actor, not a struct with `@unchecked
  Sendable`.** The protocol requires `Sendable`; an actor satisfies
  that without an unchecked escape hatch, and the recorded-requests
  state needs isolation anyway since downstream concurrency tests will
  hit it from arbitrary tasks.

- **`TranscriptionRequest.Source` carries a URL for both `.file` and
  `.stdin`.** The stdin path is materialized to a temp file before
  request construction, so the `Transcriber` only ever sees local file
  URLs that `AVAudioFile(forReading:)` can open — no `FileHandle`
  shape in the request itself. The Voice-Memos identifier/title for
  the output's `source` descriptor lives on `Transcript.source`, not
  the request — the resolver that finds a Voice Memo will build the
  request from a file URL and rewrite the result's source on the way
  back out.

## Follow-ups

None filed — the issue is fully closed. Next speech-track issues
(#11 file loading, #12 stdin, #15 locale model detection, #19
SpeechAnalyzer wrapper) can now land independently against the same
protocol.
