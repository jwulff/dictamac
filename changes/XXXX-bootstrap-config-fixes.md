# Fix bootstrap config: .githooks bugs + CLAUDE.md cross-refs

PR: #TBD (orchestrator renames file)
Issues: Closes #33

## What changed

Addresses the nine bot-review findings from PR #30 that landed on `main`
via the bootstrap commit #31 but had no follow-up applied. The work
splits cleanly across two surfaces: the developer-workflow git hooks
(`.githooks/pre-push`, `.githooks/post-checkout`) and the workflow
documentation (`CLAUDE.md`).

## Why

Bots reviewed PR #30 *pre-rebase*. The pre-rebase diff bundled the
bootstrap config; the rebased PR #30 no longer touched those files, so
the findings were valid but stranded. Filed as #33 to keep the findings
visible and independently actionable.

Net effect after this PR:

- The pre-push hook actually delivers on its stated guarantee
  ("tests before push") — it no longer silently bypasses the runner,
  no longer lets multi-commit pushes slip an unattested commit through,
  and its "Push anyway?" prompt is reachable for the first time.
- The post-checkout hook fails loudly when its auto-revert can't
  succeed, instead of leaving the main worktree on a blocked branch.
- CLAUDE.md is internally consistent and aligned with `docs/PLAN.md`
  (§4 vs §9 pointer, entitlements list vs `Resources/dictamac.entitlements`,
  model-download wording, pure-doc `changes/` exception).

## How

### `.githooks/pre-push` — four behavior bugs

1. **`/dev/tty` for the "Push anyway?" prompt** (was `[ -t 0 ]`).
   Git's pre-push hook binds fd 0 to the ref-update stream, so the old
   TTY check on fd 0 was always false → the documented override was
   permanently unreachable. The new check is `[ -t 1 ] && [ -e /dev/tty ]`,
   with `read response < /dev/tty` for the prompt and
   `printf ... > /dev/tty` for the question itself.

2. **Iterate every commit in the pushed range.** The old hook ran a
   single `grep` against `git log --format=%B "$RANGE"`, so a
   multi-commit push slipped through whenever *any* commit had the
   trailer. The new loop iterates `git rev-list $remote..$local` (or
   merge-base on initial push), collects per-commit misses, and prints
   the offending `sha title` list to make remediation obvious. Initial
   push correctly handles the all-zeros `$remote_sha`.

3. **Token name alignment.** Warning output now uses
   `[dictamac-tests-passed: ...]` everywhere — extracted into a single
   `ATTESTATION_TOKEN` shell var so the message can never drift from
   the matcher again.

4. **Detect-and-fail instead of detect-and-skip.** When no runner is
   detected the hook now exits non-zero with a clear message rather
   than passing silently. Detection order is also reordered to prefer
   Makefile and Package.swift (this repo's actual setup) over generic
   JS/Go/Rust/Python detectors.

### `.githooks/post-checkout` — one bug

5. **Loud failure when auto-revert can't checkout.** The old hook ran
   `git checkout main` (or `master`) and exited 1 unconditionally —
   without checking whether the checkout itself succeeded. If it
   didn't (dirty working tree, conflicts), the main worktree was left
   parked on exactly the branch the hook is meant to prevent. The new
   path wraps the checkout in `if ! git checkout "$DEFAULT_BRANCH"`,
   prints an "ERROR: tried to auto-revert but checkout failed" block
   pointing the user at `git status` + manual `git checkout`, and
   keeps the non-zero exit.

### `CLAUDE.md` — five doc fixes

6. **`docs/PLAN.md §9` → `§4`** for the exit-code cross-reference.
   §9 is "Risks"; the stable exit-code table is in §4 (CLI Surface →
   Exit Codes).

7. **"No model download" reworded** to "no app-bundled speech model —
   the OS-managed locale asset is installed on first use" so the Tech
   Stack bullet stops contradicting the "Locale model installation"
   subsection further down.

8. **`com.apple.security.device.audio-input` added** to the required
   entitlements list. The entitlement is already present in
   `Resources/dictamac.entitlements`; only the doc was out of sync.
   Added a "must match Resources/dictamac.entitlements exactly" note +
   pointer to PLAN §7 U2.

9. **Second TCC deep-link** for Files & Folders (Voice Memos library)
   was already present on `main` after PR #30's later commit (`08745ae`).
   Verified, no further change needed; listed here for completeness so
   the issue's nine checkboxes all map to a verified outcome.

10. **Pure-doc `changes/` exception** noted in CLAUDE.md's pre-merge
    checklist (already documented in `changes/README.md`). Keeps the
    two surfaces from drifting.

### Verification

Each hook fix was verified in a scratch git repo (one branch with
mixed attestation, then one branch with dirty WD, then one branch
with no runner):

- Per-commit iteration: warns + lists the two unattested commits;
  non-interactive mode aborts with the documented token.
- Detect-and-fail: scratch repo with no Makefile/Package.swift now
  exits 1 with the "no test runner detected" error.
- /dev/tty prompt: reached under a `script(1)`-allocated PTY; the
  old `[ -t 0 ]` path would never have rendered the prompt.
- post-checkout failure path: dirty working tree blocks the
  `git checkout main`; new error block fires, exit 1, branch
  unchanged (with manual-fix instructions).

`make test` → `Test run with 364 tests in 31 suites passed after 0.928s`.

## Follow-ups

None. The structural rework of pre-push (e.g. moving from shell to a
Swift test driver) was explicitly out of scope per #33.
