# Implement JSONFormatter matching the v1 schema

PR: #36
Issues: Closes #21 (Refs #3)

## What changed

`DictamacCore` now has `JSONFormatter` — the renderer behind CLI
`--json` and MCP `format: "json"` tool responses. Two entry points:

- `JSONFormatter.format(_:) -> String` — convenience overload.
- `JSONFormatter.write(_:to:)` — streams into any `TextOutputStream`.

Plus five committed snapshot files under
`Tests/DictamacCoreTests/__Snapshots__/` and a local
`assertSnapshot(_:named:)` helper that anchors to `#filePath` (no
Bundle.module resource wiring).

## Why

`--json` is the agent-friendly output mode and the long-term stable
contract for downstream consumers. The §6 schema is versioned
(`"version": "1"`) and must serialize deterministically — otherwise a
field-reorder or key-shape regression silently breaks every consumer.
Snapshot tests catch those regressions before they reach the agent.

## How

A few decisions worth flagging:

- **The schema shape lives on `Transcript`, not the formatter.** The
  Codable conformance (#10) is the single source of truth for §6:
  confidence omission, discriminated source union, `fullText`
  computation. `JSONFormatter` adds encoder configuration —
  `[.prettyPrinted, .sortedKeys]` + one trailing newline — and
  nothing else. If schema bytes drift, the fix is in the type, not
  the formatter.

- **`#filePath`-anchored snapshots, not `Bundle.module` resources.**
  Wiring up `resources: [.copy("__Snapshots__")]` in Package.swift
  would have worked, but every snapshot regression diff would then be
  split across two locations (test source vs. resource bundle).
  Anchoring to `#filePath` keeps regression evidence and test source
  in the same diff hunk. Trade-off: snapshots are only readable from
  a source-tree test run (not a pre-built test bundle). That's fine —
  our CI runs `swift test`, not pre-built bundles.

- **Forward-slash escaping (`\/`) is preserved in snapshots.** The
  spec's encoder configuration (`[.prettyPrinted, .sortedKeys]`)
  doesn't include `.withoutEscapingSlashes`, so the current
  Foundation default applies. Snapshots capture the actual bytes —
  parseable as valid JSON, slightly less human-readable. If the team
  later prefers unescaped slashes, add the option and regenerate;
  this PR sticks to the literal acceptance criterion.

- **Forced `try!` in `format(_:)` keeps the API non-throwing.**
  Encoding an in-memory `Transcript` only fails on programmer error
  (e.g. non-finite `Double`), and an honest crash beats a silent
  empty-string fallback. The narrow surface (no user data shape can
  reach the encoder without going through the typed model first)
  makes this safe.

- **Mixed-confidence snapshot exists deliberately.** A single payload
  with both shapes catches the most likely regression (synthesized
  Codable accidentally writing `"confidence": null`) in the most
  obvious diff. The two-segment snapshot is more useful than two
  one-segment snapshots.

## Follow-ups

None filed. With `PlaintextFormatter` (#35) and `JSONFormatter` (this
PR) both in, the CLI track is unblocked through the formatter step.
Next on the critical path:

- #11 Load audio from file path via AVAudioFile
- #19 Wrap SpeechAnalyzer with MainActor lifecycle (depends on #11)
- #13 Build CLI root command with flag parsing and mode dispatch
  (depends on the formatters and #11)
