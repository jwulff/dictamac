# Add full CLI flag surface with mode dispatch

PR: #42
Issues: Closes #13 (Refs #3)

## What changed

The `dictamac` command's argv surface now matches PLAN.md §4 in full:

- Positional `path` (file) or `-` literal-dash (stdin marker)
- `--locale <BCP-47>` (default `en-US`)
- `--json`
- `--voice-memo <query>`
- `--list-voice-memos`
- `--since <duration>` / `--limit <n>` (gated to `--list-voice-memos`)
- `--mcp`
- `--verbose`
- `--version` / `--help` (Argument Parser–provided)

A single `Mode` enum is resolved after parsing in `Dictamac.resolveMode()`
and routed to a `ModeHandlers` value via `dispatch(mode:handlers:)`.
Only the file-path handler does real work today; the four remaining
modes (`stdin`, `--voice-memo`, `--list-voice-memos`, `--mcp`) are
stub handlers that write a clear "not yet implemented — see #N"
message to stderr and exit with code 2. Each stub points at the
issue/epic that owns the real implementation (#27 / #4 / #4 / #5).

## Why

Every other CLI-track issue depends on a working argument-parser root
command. Without it the CLI has no shape and downstream formatter,
error-mapping, and Voice Memos / MCP work has nowhere to land. The
parser surface is the contract every other piece of the CLI track
plugs into; landing it first means the rest of the track can proceed
in parallel.

The mutual-exclusivity rules from PLAN.md §7 U3 are enforced in pure
code (`resolveMode()`) so they're testable without standing up the
real transcription pipeline or touching process exit.

## How — packaging choice

**`DictamacCLI` is a new library target; the `dictamac` executable is
a one-line wrapper.** Two reasons:

1. SPM executable targets are awkward to import from tests. Extracting
   the command into a library lets `Tests/DictamacCLITests/` use a
   normal `@testable import DictamacCLI` and exercise the
   `Dictamac.parse(_:)` programmatic surface for every flag
   combination.
2. The dispatch seam (`ModeHandlers`) is injectable. Tests build a
   recorder-backed handler set and assert which mode the parser
   resolved without spawning a subprocess.

The executable's `main.swift` is now three lines: import the library,
call `Dictamac.main()`. The concurrency-shape rationale (PR #40 —
`ParsableCommand` + `Task {}` + `dispatchMain()`) moved into the
library and is preserved verbatim — `AsyncParsableCommand` would
break SpeechAnalyzer's main-RunLoop requirement.

## How — implementation notes worth flagging

- **`resolveMode()` is the single decision point.** Every
  mutual-exclusivity rule from PLAN §7 U3 lives here as plain Swift
  `if`s. The function returns a `Mode` value or throws
  `DictamacCLIError.argumentError`, which `Dictamac.run()` bridges to
  `DictamacError.argumentError` so the central exit-2 mapping in
  `DictamacError.exit()` does the actual termination. No process-exit
  paths exist outside `DictamacError.exit()` (validation) and
  `Darwin.exit(_:)` (the file-path success path inherited from PR #40).

- **`DictamacCLIError` is a thin wrapper, not a parallel error
  hierarchy.** It exists purely so `resolveMode()` can be a `throws`
  pure function callable from unit tests (which can't tolerate the
  test runner exiting). The `asDictamacError` bridge routes the
  message through the same `DictamacError.argumentError` path the
  rest of the codebase uses for argv failures.

- **Stub handlers go through `DictamacError.argumentError`, not
  `fatalError`.** The issue body suggested `fatalError("not yet
  implemented")` as one option; `DictamacError.argumentError` is
  better because it preserves the stderr-and-exit-2 contract (a
  `fatalError` would crash with a stack trace on stdout/stderr and
  set a different exit code). When the real epic lands, the stub
  message goes away and the handler does real work — the dispatcher
  doesn't change.

- **`StubMessages` centralizes the "see #N" pointers.** Each
  unimplemented mode has one constant (or one function for
  parameterized messages). When epic #4 or #5 land, the constants
  disappear with the stub handlers — easy to grep for.

- **`--since` and `--limit` are gated to `--list-voice-memos`
  in `resolveMode()`, not via Argument Parser's transformation API.**
  Argument Parser doesn't have a declarative "only valid with flag X"
  facility, so the check runs after parsing. The error message names
  the conflicting flag so the user can correct it.

- **`--version` testing without naming the internal error type.**
  `ArgumentParser` raises `ParserError.versionRequested` through an
  internal `CommandError` envelope when `--version` parses. Neither
  type is part of the public API, so the version test asserts the
  parser refuses to return a parsed value (good — it routes the flag
  through `.main()`) and that `Dictamac.message(for:)` renders the
  expected string. `Dictamac.main()` itself prints that string to
  stdout and exits 0 (Argument Parser's standard behavior, exercised
  manually via `dictamac --version` and pinned in the PR description).

## Verified

- `swift test` — 126 tests in 11 suites, all passing (41 of those
  are new `DictamacCLITests`).
- `make build` — clean release build, ad-hoc signed.
- `.build/release/dictamac --version` → `0.0.0-dev` on stdout, exit 0.
- `.build/release/dictamac --help` → help text listing every flag.
- `.build/release/dictamac Tests/DictamacSpeechTests/Fixtures/hello-world.m4a`
  → regression: still prints "Hello, world, this is a test." with the
  signed binary; PR #40's behavior is preserved.
- Stub behaviors: `--mcp` / `--list-voice-memos` / `--voice-memo X`
  / `-` each write their "not yet implemented" message to stderr and
  exit 2; stdout stays empty.
- Mutual-exclusivity checks: `--list-voice-memos foo.m4a`,
  `--since 7d foo.m4a`, `--limit 5 foo.m4a`, no-args invocation all
  return exit 2 with a clear stderr message.

## Follow-ups

- #27 — actual stdin (`-`) audio pipeline (replaces the stub handler).
- Epic #4 — `--voice-memo` query resolution + `--list-voice-memos`
  including `--since` / `--limit` (replaces those stub handlers).
- Epic #5 — `--mcp` JSON-RPC stdio server (replaces the stub handler).
