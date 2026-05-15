# dictamac — macOS CLI for on-device transcription

---

## STOP — READ THIS BEFORE ANY CODE CHANGES

**Before modifying any code file, you MUST:**

1. Create a feature/fix branch — NEVER commit directly to `main`.
2. Create a worktree for the branch (see "Git Worktree Workflow" below).
3. Open a PR on first push.

---

## Public Open Source Project

**This is a public repository on GitHub: https://github.com/jwulff/dictamac**

Everything committed here is visible to the world. NEVER commit:

- API keys, tokens, or secrets of any kind
- Passwords or credentials
- Private URLs or internal server addresses
- Personal information (emails, phone numbers, addresses)
- `.env` files or environment configurations with secrets
- Signing certificates or private keys (`.p12`, `.pem`, `.key`)
- Audio fixtures containing recognizable speech, real names, or PII —
  use synthesized or scrubbed audio for tests
- Database dumps or files containing user data

If you accidentally commit sensitive data, it is **not** enough to delete
it in a new commit — the data remains in git history. You must rewrite
history or consider the secret compromised.

When in doubt, add it to `.gitignore` first.

---

## What This Is

A single macOS binary that transcribes audio files via Apple's macOS 26
`SpeechAnalyzer` / `SpeechTranscriber` API, with two transports:

- **CLI** — `dictamac path/to/audio.m4a` → plaintext to stdout
- **MCP** — `dictamac --mcp` → JSON-RPC stdio server exposing
  `transcribe_file`, `transcribe_voice_memo`, `list_voice_memos`

Primary consumer is AI agents that need transcription as part of a larger
workflow. Humans get a clean stdout contract as a side effect.

Full spec: [docs/PLAN.md](docs/PLAN.md). Treat that document as the source
of truth for behavior; this file is the source of truth for **how we
work**.

---

## Architecture (one-screen summary)

```
            argv / JSON-RPC
                  │
       ┌──────────┴──────────┐
       ▼                     ▼
 CLI transport         MCP transport
       │                     │
       └─────────┬───────────┘
                 ▼
       TranscriptionRequest
                 │
       ┌─────────┴─────────┐
       ▼                   ▼
 VoiceMemosIndex     AudioFileResolver
       │                   │
       └─────────┬─────────┘
                 ▼
            Transcriber           (SpeechAnalyzer wrapper)
                 │
       ┌─────────┴─────────┐
       ▼                   ▼
  Plaintext formatter   JSON formatter
```

Invariants enforced by tests:

- The two transports are **thin shells** over the same core. Behavior
  parity is non-negotiable.
- **stdout = transcript content. stderr = everything else.**
- **Exit code 0 on success, non-zero otherwise.** Specific codes per
  failure class — see `docs/PLAN.md` §9.
- **No state persisted between invocations.** No daemon, no cache file.
  The locale model is the only on-disk state, owned by the OS.

---

## Tech Stack

- **Swift 6.x** with strict concurrency
- **swift-argument-parser** for the CLI surface
- **macOS 26+ `SpeechAnalyzer` / `SpeechTranscriber`** — exclusively. No
  fallback to legacy `SFSpeechRecognizer` (see "Anti-Patterns").
- **Swift Testing framework** (`import Testing`) for unit tests
- **Ad-hoc code signing** with entitlements for SpeechAnalyzer; no
  Apple Developer account required
- **MCP** via JSON-RPC 2.0 over stdio
- **No Python, no GPU, no model download** — the speech model ships with
  the OS

---

## TDD Is Paramount

**Every feature starts with a failing test.**

### Red-Green-Refactor

1. **RED**: write a failing test that defines the expected behavior.
2. **GREEN**: write the minimum code that makes it pass.
3. **REFACTOR**: clean up while keeping tests green.

### Design for Testability

- **Protocol-first.** Define interfaces before implementations.
- **Dependency injection.** All services passed in, never instantiated
  internally. Mocks for `Transcriber`, `VoiceMemosIndex`,
  `AudioFileResolver` live in `Tests/.../Mocks/`.
- **No singletons.** Everything injectable.
- **Pure functions** where possible — formatters and CLI parsing should
  be deterministic and side-effect-free.

---

## Repository Structure

The implementation will land roughly like this (current state: docs +
plan only):

```
dictamac/
├── CLAUDE.md
├── README.md
├── LICENSE
├── Package.swift               # SPM manifest
├── Makefile                    # Build, sign, test, run (start here)
├── Resources/                  # Entitlements + Info.plist for signing
├── Sources/
│   ├── DictamacCore/           # TranscriptionRequest, formatters, errors
│   ├── DictamacSpeech/         # SpeechAnalyzer wrapper, @MainActor glue
│   ├── DictamacVoiceMemos/     # Library discovery + index
│   ├── DictamacMCP/            # MCP server (tools, schemas)
│   └── dictamac/               # @main entry point + CLI command
├── Tests/
│   ├── DictamacCoreTests/
│   ├── DictamacSpeechTests/
│   ├── DictamacVoiceMemosTests/
│   ├── DictamacMCPTests/
│   └── Fixtures/               # Tiny synthesized audio fixtures only
├── changes/                    # One file per merged PR (the "why")
├── docs/
│   ├── PLAN.md                 # Implementation plan / spec
│   ├── brainstorms/
│   └── plans/
└── .githooks/                  # pre-push (tests + attestation), post-checkout
```

If you find yourself adding a new top-level directory, document why in
the PR description.

---

## Build & Test Commands

Once the Makefile lands, these are the expected targets (kept in sync
here so new contributors and agents have a single reference):

```bash
make build            # Release build, ad-hoc signed binary
make test             # swift test ./...
make run              # Build + run with sample args
make sign             # Ad-hoc sign the release binary with entitlements
make install          # Copy signed binary to ~/.local/bin
make clean            # Remove build artifacts
```

### Why ad-hoc signing matters

`SpeechAnalyzer` requires specific entitlements
(`disable-library-validation`, `allow-jit`) to avoid `SIGTRAP` at
startup. `swift run` skips code-signing — so use `make run` (which
builds, signs, and runs), not `swift run`.

**Do NOT use `com.apple.developer.speech-recognition`** — it's a
restricted entitlement that requires a provisioning profile. CLI
binaries can't embed profiles, so AMFI kills the process with `SIGKILL`.
macOS 26 `SpeechAnalyzer` does not need this entitlement.

---

## Work Tracking — GitHub Issues Are the System of Record

**Chat history is ephemeral; issues persist.** A fresh clone + `gh issue
list` should be enough for any contributor (or agent) to pick up a track
of work without prior context.

### Document type ↔ purpose

| Artifact | Purpose | Timeline |
|---|---|---|
| **GitHub Issue** | Forward-looking unit of outstanding work | Open until shipped |
| **GitHub PR** | The change set fulfilling one or more issues | Open until merged |
| **`changes/` file** | Why-and-how narrative for one merged PR | Permanent post-merge |
| **`docs/learnings/` file** | Cross-PR diagnostic capture: traps, signatures, fixes | Permanent |
| **`docs/adr/` file** | Architectural decision records | Permanent |

Rules of thumb:

- "We should also do X someday" → **file an issue**, don't bury it in a PR body.
- Decision rationale for what shipped → **changes file** in the PR.
- Surprise traps that took multiple deploys to debug → **learnings doc**.
- Major architectural choices → **ADR**.

### Label palette

Every issue carries **type + track + priority + size**.

| Category | Labels | Meaning |
|---|---|---|
| Type | `epic`, `feature`, `bug`, `chore`, `docs`, `research` | What kind of issue |
| Track | `track:cli`, `track:mcp`, `track:speech`, `track:voice-memos`, `track:packaging` | Area of the system |
| Priority | `p0` (drop everything), `p1` (blocks current track), `p2` (next session), `p3` (someday) | Ordering, not deadlines |
| Size | `size:xs` (<2h), `size:s` (half-day), `size:m` (1–2 days), `size:l` (multi-session) | Effort estimate |
| Status | `blocked`, `needs-review`, `in-progress` | Set sparingly; usually inferable from assignee + comments |

If a `size:l` is filed, it should probably be split.

### Issue body template

```markdown
## Why
[1–2 sentence motivation — what capability or risk this unblocks.]

## Acceptance criteria
- [ ] Specific, testable condition
- [ ] Another specific, testable condition

## Out of scope
- [What we are deliberately NOT doing here, even though tempted]

## Dependencies
- Blocked by #N (if applicable)
- Related to #M

## Notes
- Relevant code paths, prior context, links to ADRs/learnings
- Anything an agent with empty context needs to start
```

The acceptance criteria checklist is the **definition of done**. A PR
closing the issue must check every box. If it can't, file a follow-up
and `Refs` (not `Closes`) the original.

### Epic body template

```markdown
## Goal
[1–2 sentences: the user/operator outcome this track delivers.]

## Track
`track:<name>`

## Children
- [ ] #101 First child issue
- [ ] #102 Second child issue

## Definition of done
[When can we close the epic? Usually: all children closed AND <higher-level
outcome verified end-to-end>.]

## Out of scope
[What this epic deliberately does NOT cover, with pointers to where that lives.]
```

Epics carry the `epic` label. They don't get PRs directly; their
children do. GitHub auto-ticks the children list as referenced issues
close.

### Naming

- **Epics**: `[EPIC] track: outcome` — e.g. `[EPIC] mcp: stdio server MVP`
- **Issues**: imperative, ≤10 words — `Add JSON output formatter`,
  `Refuse to run on macOS < 26`
- **Branches**: `feature/123-json-output-formatter` (issue number first)

### Lifecycle

1. **Pick** —
   `gh issue list --label 'track:<area>,p1' --state open --search 'no:assignee sort:created-asc'`,
   assign yourself.
2. **Worktree** per "Git Worktree Workflow" below.
3. **Work** — TDD, small commits.
4. **PR** — body MUST contain `Closes #N` (or `Refs #N` if only partial
   progress). Multiple `Closes #N #M` are fine when issues are
   naturally bundled.
5. **Merge** — issues auto-close on merge; epic checklists auto-tick.
6. **Verify** — leave a closing comment if anything is unusual.

### Anti-patterns

- ❌ `TODO:` comments in code without a filed issue — reference one (`// See #123`).
- ❌ Vague issues ("improve CLI") — un-pickable; rewrite as specific units.
- ❌ Plan-as-prose in the PR description instead of an issue — not
  queryable, lost on merge.
- ❌ Epics without `Definition of done` — they sprawl forever.
- ❌ PRs that don't link an issue.

---

## Git Worktree Workflow

The main worktree at `~/Development/dictamac/` stays on `main`. Feature
work happens in sibling worktrees alongside the repo.

```bash
# Create worktree for feature work
cd ~/Development/dictamac
git fetch origin
git branch feature/NAME origin/main
git push -u origin feature/NAME
git worktree add ../feature-NAME feature/NAME
cd ../feature-NAME

# Cleanup after merge
cd ~/Development/dictamac
git worktree remove ../feature-NAME
git branch -d feature/NAME
```

The `.githooks/post-checkout` hook blocks accidental branch checkouts in
the main worktree and auto-reverts to `main`. Worktrees themselves are
unaffected (they have `.git` as a file pointer, not a directory).

---

## Testing Conventions

### Swift Testing framework

```swift
import Testing
@testable import DictamacCore

struct TranscriptFormatterTests {
    @Test func plaintextStripsTrailingNewlines() {
        let transcript = Transcript(segments: [.init(text: "hello", ...)])
        #expect(PlaintextFormatter.format(transcript) == "hello\n")
    }
}
```

### File naming

- Tests mirror source — `Sources/DictamacCore/Transcript.swift` →
  `Tests/DictamacCoreTests/TranscriptTests.swift`.
- Mocks live in `Tests/.../Mocks/`.

### Test attestation

Every commit pushed to a feature branch must include an attestation line
in the commit message:

```
[dictamac-tests-passed: X tests in Ys]
```

The `.githooks/pre-push` hook enforces this and runs `make test` before
allowing the push.

### Audio fixtures

- Keep fixtures tiny (< 50 KB) — short tones, synthesized speech, or
  silence with a known transcript.
- Never commit recordings of real people speaking. The repo is public.

---

## macOS 26 Speech API Notes

These are hard-won; ignore at your peril.

### SpeechAnalyzer requires the main RunLoop

`SpeechAnalyzer` will not deliver results unless the main RunLoop is
alive. The CLI entry point uses `ParsableCommand` (not
`AsyncParsableCommand`) and calls `dispatchMain()` after kicking off
async work in a `Task {}`. Do not switch to `AsyncParsableCommand`
without verifying transcription still works end-to-end.

### `analyzer.start()` must run on `@MainActor`

```swift
let transcriber = SpeechTranscriber(
    locale: locale,
    transcriptionOptions: [],
    reportingOptions: [],
    attributeOptions: []
)
let analyzer = SpeechAnalyzer(modules: [transcriber])

try await Task { @MainActor in
    try await analyzer.start(inputSequence: inputSequence)
}.value

for try await result in transcriber.results {
    // result.text, result.isFinal
}
```

Calling `analyzer.start()` off the main actor crashes with `SIGTRAP`.

### Required entitlements (ad-hoc signed)

- `com.apple.security.cs.disable-library-validation`
- `com.apple.security.cs.allow-jit`

### Required TCC permissions

- **Speech Recognition** (always).
- **Files & Folders** access for the Voice Memos library, or **Full Disk
  Access** as a heavier-weight alternative — only needed for
  `--voice-memo` / `list_voice_memos` paths.

When a TCC permission is missing, exit with code 73 and write a
`stderr` message including the deep-link
(`x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition`)
so the user can grant the permission in one click.

### Locale model installation

The locale model downloads on first use. If it's missing and the network
is unreachable, exit with code 67 and tell the user how to trigger the
install manually.

---

## Code Conventions

### Protocol-first design

```swift
protocol Transcriber: Sendable {
    func transcribe(_ request: TranscriptionRequest) async throws -> Transcript
}
```

`DefaultTranscriber` is the production impl; `MockTranscriber` lives in
`Tests/`. The CLI and MCP transports both depend on the `Transcriber`
protocol, never the concrete type.

### Naming

- **Types**: `TranscriptionRequest`, `Transcript`, `TranscriptSegment`,
  `VoiceMemo`, `VoiceMemosIndex`
- **Protocols**: `Transcriber`, `VoiceMemosLibrary`, `AudioFileResolver`
- **Errors**: `DictamacError` enum with one case per exit code
- **Mocks**: `MockTranscriber`, `MockVoiceMemosLibrary` (test-only)

### Stdout discipline

The only thing that goes to stdout is the transcript artifact (plaintext
or JSON). Progress output, diagnostics, deep-links, and errors all go to
stderr. `--verbose` adds more stderr output; it never changes stdout.

---

## PR Workflow

### Pre-merge checklist

- [ ] CI passing
- [ ] **All review comments addressed** (see below)
- [ ] Test attestation in every commit
- [ ] `changes/NNNN-short-slug.md` added describing the why-and-how

### Review feedback protocol

**Before merging any PR, check and resolve all review feedback. Every
reviewer comment gets a reply. No exceptions.**

1. Fetch all comments:
   ```bash
   gh api repos/OWNER/REPO/pulls/NUMBER/comments \
     --jq '.[] | "\(.user.login): \(.body[0:200])"'
   gh api repos/OWNER/REPO/issues/NUMBER/comments \
     --jq '.[] | "\(.user.login): \(.body[0:200])"'
   ```
2. Reply to every comment:
   - **Actionable**: fix it, push, reply with the commit SHA.
   - **Deferred**: file a GitHub issue, link it in the reply.
   - **Disagree**: reply with reasoning — never silently ignore.
3. Re-check after pushing — new pushes can trigger new comments.
4. Resolve all threads before merging.

---

## Pre-Push Checklist

Before pushing any branch:

1. **Run the full test suite**: `make test` — not just the files you changed.
2. **Verify the release build succeeds**: `make build`.
3. **Include the test attestation** in the commit message:
   `[dictamac-tests-passed: X tests in Ys]`.
4. **No warnings or errors** in the Swift build output.

The `.githooks/pre-push` hook automates 1 + 3, but run them manually
first to catch failures before the push attempt.

---

## Debugging Discipline

1. **Reproduce before fixing.** Write a failing test that demonstrates
   the bug before writing any fix. The test proves the bug exists and
   prevents regressions.
2. **Check API response format assumptions early.** When working with
   SpeechAnalyzer results, MCP JSON-RPC envelopes, or Voice Memos
   metadata, log the raw response shape before writing parsing code.
3. **Audit nil/optional handling.** Force unwraps (`!`) are an
   anti-pattern. Inspect every optional, especially:
   - `SpeechAnalyzer` results where `text` or `isFinal` may be absent
   - JSON decoding where fields may be missing or have unexpected types
   - Voice Memos metadata reads where files may be deleted between
     index and read
4. **Isolate the layer.** Is the bug in the CLI transport, MCP
   transport, the core `Transcriber`, or the SpeechAnalyzer wrapper?
   The protocol seams make this cheap to test in isolation — use them.

---

## Anti-Patterns

- ❌ Committing secrets, credentials, or PII (this is a public repo).
- ❌ Writing implementation before tests.
- ❌ Hardcoding service dependencies; using singletons.
- ❌ Force unwrapping optionals (`!`).
- ❌ Skipping error handling or swallowing errors silently.
- ❌ Writing transcript-shaped data to stderr or diagnostics to stdout.
- ❌ Calling `analyzer.start()` off the main actor — crashes with `SIGTRAP`.
- ❌ Using `AsyncParsableCommand` with `dispatchMain()` — crashes.
- ❌ **Falling back to legacy speech APIs** (`SFSpeechRecognizer`,
  `SFSpeechAudioBufferRecognitionRequest`). The fix for `SpeechAnalyzer`
  / `SpeechTranscriber` issues is always to repair the runtime
  environment (main RunLoop, `@MainActor`, `dispatchMain()`,
  signing/entitlements) — not to downgrade APIs.
- ❌ Adding the restricted `com.apple.developer.speech-recognition`
  entitlement (AMFI will `SIGKILL` the binary).
- ❌ Persisting state between invocations (no daemon, no cache file).
- ❌ Drifting the CLI and MCP transports apart — they must remain thin
  shells over the same core.

---

## Commit Message Format

```
[Brief summary — imperative, ≤72 chars]

[What changed and why. Reference the issue: Closes #N or Refs #N.]

[dictamac-tests-passed: X tests in Ys]
```

Co-authorship trailers are welcome but not required.
