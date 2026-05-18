# Define DictamacError enum and central exit-code mapping

PR: #38
Issues: Closes #24 (Refs #3)

## What changed

Expanded the narrow scaffolding `DictamacError` from PR #37 — which
only covered `.fileNotFound` and `.audioDecodeFailed` — into the full
enum required by PLAN.md §7 U9. Six new cases land in
`Sources/DictamacCore/DictamacError.swift`:

- `.argumentError(String)` → exit 2
- `.voiceMemoNotFound(query: String)` → exit 66
- `.speechAnalyzerUnavailable(reason: String)` → exit 67
- `.permissionDenied(domain: String, deepLink: URL?)` → exit 73
- `.voiceMemoLibraryMissing(searched: [URL])` → exit 74
- `.internalFailure(any Error)` → exit 1

The existing `.fileNotFound` (64) and `.audioDecodeFailed` (65) keep
their codes. The `exitCode` computed property is now exhaustive over
all eight cases, with a Swift Testing table-driven test
(`exitCodeTableMatchesPlanSection4`) pinning every code to the PLAN.md
§4 contract.

Two new emission helpers land on `DictamacError`:

- `writeStderrLine(to: FileHandle = .standardError)` — writes
  `description + "\n"` to the supplied handle. Default lets the CLI
  call site stay terse; tests inject a `Pipe().fileHandleForWriting`
  to capture bytes without touching the real stderr.
- `exit() -> Never` — calls `writeStderrLine()` then
  `Foundation.exit(exitCode)`. This is the canonical CLI error-exit
  path; the MCP transport will reuse `description` directly when
  constructing `{isError: true, content: [...]}` tool responses.

The `formattedStderrLine` String property exposes the exact bytes
those helpers would emit, so tests can assert the surface without any
I/O.

## Why

Both transports (CLI now, MCP in a later epic) need to map the same
failure classes to a stable presentation — and the §4 exit-code table
is a hard external contract: agents react to numeric codes
programmatically. Scattering the mapping across call sites makes
CLI/MCP drift inevitable. PLAN §7 U9 calls out that "both transports
use the SAME mapping function; behavior parity ... is a hard
requirement", so this lives in `DictamacCore` (not `Sources/dictamac/`)
even though only the CLI consumes the `exit()` helper today.

The `permissionDenied` case carries an optional `deepLink: URL?`
because the §4 spec, CLAUDE.md, and PLAN §7 U6 all promise that exit
73 includes the `x-apple.systempreferences:...` URL on stderr so users
can grant the permission in one click. Surfacing the URL through the
error type itself means each producer site picks the right URL
(Speech Recognition vs Files & Folders) once — there's no central
table to drift from the deep-link conventions.

The CLI helper is named `.exit()` rather than `.die()` or
`.terminate()` to match the conventional Swift surface (`fatalError`,
`exit`, `Process.run().terminationStatus`). It returns `Never` so the
compiler enforces that no statement follows.

## How

A few decisions worth flagging:

- **`permissionDenied(domain:deepLink:)` keeps `deepLink` optional.**
  Some TCC denials surface without a known deep-link target (or while
  the URL is still being verified on macOS 26, per PLAN §7 U6's
  "Verify the URL against a live macOS 26 system" note). The
  `description` formatter conditionally appends the URL only when
  present; tests pin both branches.
- **`writeStderrLine` takes a `FileHandle`, not a `TextOutputStream`.**
  Stdout discipline (CLAUDE.md / PLAN §4) is enforced by *which* file
  descriptor receives the bytes — a `TextOutputStream` is a Swift
  abstraction that hides the destination. A direct `FileHandle`
  parameter, defaulted to `.standardError`, makes the discipline
  visible at the call site and trivially testable with `Pipe`.
- **`exit()` calls `Foundation.exit`, not `Darwin.exit`.** Foundation
  re-exports the libc symbol on every Apple platform and matches the
  rest of the codebase's `import Foundation` style. Tests never
  invoke `.exit()` — it would terminate the test runner — so the
  formatter (`formattedStderrLine`) and the writer
  (`writeStderrLine`) are exercised separately.
- **Drop the `CustomStringConvertible` branch in `message(for:)`.**
  The Swift 6 compiler warns that the `as? CustomStringConvertible`
  cast always succeeds (every Swift value bridges through the
  protocol). `String(describing:)` already routes through
  `CustomStringConvertible.description` when present, so the explicit
  branch was redundant *and* warning-generating. Replacing it with a
  comment that explains the omission keeps the
  `LocalizedError → String(describing:)` chain intact.

## Follow-ups

- The CLI root command (#13) will wire its error handler to
  `DictamacError.exit()`; the entry point for that is owned by the
  CLI track and depends on this enum being available.
- The MCP transport (#5 epic) will consume `description` to build
  `{isError: true, content: [{type: "text", text: ...}]}` tool
  responses, mapping non-zero `exitCode` failures to MCP's
  protocol-level error envelope shape.
- Voice Memos library discovery (#14) will populate the
  `voiceMemoLibraryMissing.searched` URLs at the actual probe sites.
- The Files & Folders TCC deep-link string is documented in
  CLAUDE.md / PLAN §7 U6 but not enforced at the type level — when
  the Voice Memos epic lands, consider whether a `TCCDomain` enum is
  worth the indirection.
