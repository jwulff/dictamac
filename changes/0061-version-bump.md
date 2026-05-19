# Bump version to 0.1.0 and fix orphan-push hook glob bug

PR: #61
Issues: refs release sequence (no tracking issue — first stable tag)

## What changed

- `Resources/Info.plist`: `CFBundleShortVersionString` and `CFBundleVersion`
  flip from `0.0.0-dev` to `0.1.0` for the first Homebrew-installable
  release. `DictamacVersion.current` (the single source of truth from
  #59) picks this up automatically:
  - `dictamac --version` → `0.1.0`
  - MCP `serverInfo.version` → `0.1.0`
- `.githooks/pre-push`: fixed the orphan-push commit-range determination.
  The previous logic used `--not --branches='main'` to exclude commits
  reachable from main, but the literal `main` glob (no `*` wildcard)
  doesn't match the `refs/heads/main` ref under git's fnmatch — the
  exclusion silently no-opped and the entire `main` history surfaced
  as "missing attestation" on every initial branch push.

  Replaced with explicit merge-base computation against the available
  base refs (`origin/main`, `origin/master`, `main`, `master`), picking
  the newest merge-base by commit date. `git merge-base --octopus` is
  tried first; per-base merge-base with a freshness tie-break is the
  fallback. This sidesteps the glob trap entirely and ensures a fresher
  `origin/main` wins over a stale local `main` — Copilot's review on
  this PR caught the staleness risk explicitly.

## Why

dictamac has been functionally complete since wave 5 (PR #57 wired the
last p1 work for CLI `--voice-memo`). Tagging `v0.1.0` is the natural
next step: it produces a stable GitHub tarball URL that the Homebrew
formula (`Formula/dictamac.rb`, scaffolded in PR #58) can reference
without `HEAD`, and gives downstream consumers a real version string
to pin against instead of `0.0.0-dev`.

The hook fix is bundled here because the bug only surfaces on initial
branch pushes — the exact case this release PR's push hit. Splitting
the fix into its own PR would have required bypassing the broken hook
on the first push, which the project's "never `--no-verify`" rule
forbids. Fixing the on-disk hook as part of this PR was the only path
that respected the rule.

## Tradeoffs

- The hook now invokes `git log` per merge-base candidate to compare
  commit timestamps. At most four candidates (`origin/main`,
  `origin/master`, `main`, `master`), so the overhead is negligible
  even on initial pushes that exercise this branch.
- `--octopus` is "all listed commits reachable from", which for our
  use is overkill but harmless; the fallback path covers the case
  where `--octopus` declines (e.g. when one of the candidates has no
  common ancestor with `local_sha`).
- The freshness tie-break uses commit date (`%ct`) rather than
  topological order. For a linear history that's identical; for
  branches with rebases the rebase commit date wins, which is what
  we want for "freshest base ref".

## Verification

```
$ ./.build/release/dictamac --version
0.1.0   # was 0.0.0-dev pre-bump
```

`make test` → 385 tests in 33 suites. The hook fix is exercised by
the very push that delivers it: the initial push of this branch now
identifies only the version-bump commit as in-scope for the
attestation check, not the entire main history.

## Post-merge release procedure

Documented in `changes/0058-homebrew-formula-prep.md`. After this PR
merges:

1. `git tag -a v0.1.0 -m "Initial release"`
2. `git push origin v0.1.0`
3. `gh release create v0.1.0 --title "..." --notes "..."`
4. Compute `sha256` of the auto-generated tarball:
   `curl -sL https://github.com/jwulff/dictamac/archive/refs/tags/v0.1.0.tar.gz | shasum -a 256`
5. Open a follow-up PR updating `Formula/dictamac.rb`'s placeholder
   SHA256 with the real value.
6. Create `jwulff/homebrew-tap` (user action) and copy
   `Formula/dictamac.rb` into it.
7. `brew install jwulff/tap/dictamac` to verify.
