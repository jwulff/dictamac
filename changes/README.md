# changes/

One file per merged PR. The narrative of **why** something shipped and
**how** it was built — durable context that a PR title and commit log
can't carry.

## When to write one

Every PR that touches code, build config, or developer workflow should
land with a `changes/` file. Pure-doc PRs (typo fixes, README polish)
can skip it.

## File naming

```
changes/NNNN-short-kebab-slug.md
```

`NNNN` is the PR number, zero-padded to 4 digits. Example:
`changes/0042-json-output-formatter.md`.

## Template

```markdown
# <PR title>

PR: #NN
Issues: Closes #NN (+ Refs #MM if applicable)

## What changed

One paragraph — the user/operator-visible delta.

## Why

The motivation. What capability did this unlock, or what risk did it
close? Link to the issue's `## Why` section if it stands alone.

## How

The interesting design choices. Don't recap the diff — explain the
non-obvious calls:
- Why this approach over the alternatives we considered
- Tradeoffs we accepted
- Constraints that shaped the design (entitlements, macOS API quirks,
  MCP envelope rules, etc.)

## Follow-ups

Issues filed for things we deliberately deferred:
- #NN — short description
```

## Why not just rely on PR descriptions?

PR descriptions live on GitHub and are easy to lose. `changes/` files
live in git history, are grep-able, and survive repo migrations. They
also enforce a moment of reflection: "what should a future contributor
know about this change?"

## What does NOT belong here

- Long-running design docs → `docs/plans/` or an ADR
- Cross-PR diagnostic capture (traps, signatures, fixes) →
  `docs/learnings/`
- Outstanding work → GitHub issues
