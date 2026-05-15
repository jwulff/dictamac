# Implement PlaintextFormatter with golden-string tests

PR: #35
Issues: Closes #16 (Refs #3)

## What changed

`DictamacCore` now has `PlaintextFormatter`, the stateless renderer
behind the CLI's stdout surface. Two entry points:

- `PlaintextFormatter.format(_:) -> String` — convenience for callers
  that just want the string.
- `PlaintextFormatter.write(_:to:)` — streams into any
  `TextOutputStream`, so MCP tool responses can capture the same bytes
  into a string buffer.

## Why

The default CLI mode emits plaintext to stdout. Per PLAN.md §3 / §4,
that stream is reserved exclusively for the transcript artifact —
nothing else may share it. The formatter is the choke point that
guarantees the contract; centralizing it in `DictamacCore` (not the
CLI module) means MCP can reuse the same shaping logic without
behavior drift when v0.2 lands the JSON-RPC transport.

The PLAN.md §6 invariant that "for any non-empty transcript the CLI
plaintext output is exactly `fullText + "\n"`" is non-negotiable —
otherwise the two transports drift apart byte-by-byte, and downstream
agents that compare them break.

## How

The interesting call: **the formatter is a one-liner over
`Transcript.fullText`.** That's not laziness — it's the design that
makes the §6 byte-alignment invariant hold by construction:

- `Transcript.fullText` already implements the full normalization
  algorithm from §7 U7 (trim per segment, drop whitespace-only,
  collapse internal whitespace, join with one ASCII space) minus the
  trailing newline. That code shipped with #10.
- `PlaintextFormatter.format(transcript)` returns `fullText + "\n"`.
- The MCP JSON formatter (#21, coming next) will emit `fullText`
  verbatim into the JSON `fullText` field.
- ⇒ Plaintext stdout and MCP `fullText` agree byte-for-byte except for
  the trailing newline.

Empty transcripts emit a bare `"\n"`, not `""`. Documented in a test
(`emptyTranscriptEmitsOnlyTrailingNewline`) so the decision stays
visible: the stdout contract ("one trailing newline, nothing else")
holds even when the transcript is empty, so empty-result pipes look
identical to non-empty ones to downstream consumers.

The `write(_:to:)` overload takes `inout some TextOutputStream` rather
than a class-typed buffer so callers can pass any value-typed buffer
(including `String` itself, which conforms to `TextOutputStream`).
That keeps the formatter free of allocation or buffering decisions —
the caller owns those.

## Follow-ups

None filed — the issue is fully closed. Next CLI-track issue:

- #21 JSONFormatter (now unblocked — and the `fullText` byte-alignment
  invariant means it's nearly as small as this one)
