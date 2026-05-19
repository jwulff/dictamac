# Fill Formula SHA256 for v0.1.0 tarball

PR: #62
Issues: Closes #9 (Homebrew formula in jwulff/tap, in-repo prep)

## What changed

`Formula/dictamac.rb`: replaced the placeholder `sha256` with the real
SHA256 of the `v0.1.0` source tarball that GitHub auto-generates from
the tag:

```
$ curl -sL https://github.com/jwulff/dictamac/archive/refs/tags/v0.1.0.tar.gz \
    | shasum -a 256
0019dfc4b32d63c1392aa264aed2253c1e0c2fb09216f8e2cc269bbfb8bb49b5
```

Also removes the inline placeholder comment explaining how to compute
the SHA — the comment block above the `url`/`sha256` lines still
describes the procedure for future version bumps; the placeholder
explanation is now redundant.

## Why

The Homebrew formula scaffold landed in PR #58 with a placeholder
SHA256 because the tag didn't exist yet — Homebrew formulas pin a
specific tarball by hash to defend against tag mutation, so the SHA
can only be computed after the tag is published. PR #61 + the v0.1.0
tag close that loop; this PR fills in the real value so the formula
is consumable.

This is the last in-repo step for #9. Two user actions remain:
1. Create `jwulff/homebrew-tap` (a separate GitHub repository).
2. Copy `Formula/dictamac.rb` to `Formula/dictamac.rb` in that tap
   repo, then `brew install jwulff/tap/dictamac` to verify.

The in-repo `Formula/dictamac.rb` stays as the canonical source —
future version bumps update it here, then the change is mirrored to
the tap repo by hand (or a future automation).

## Verification

- `ruby -c Formula/dictamac.rb` parses clean
- The SHA matches the live tarball as of the v0.1.0 tag at commit `1f15d41`

`make test` not impacted — formula change has no Swift surface.

## Follow-ups

- `jwulff/homebrew-tap` repo creation (user action)
- Eventual automation: a release-tag workflow that opens a PR
  updating the formula SHA automatically on every `v*.*.*` tag push.
  Scoped out of v0.1.0; file as a separate issue if/when the
  release cadence justifies it.
