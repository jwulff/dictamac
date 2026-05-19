# Fix Formula: real v0.1.0 SHA + bypass nested SwiftPM sandbox

PR: #63
Issues: refs #9 (Homebrew installation)

## What changed

Two corrections to `Formula/dictamac.rb`. Both also pushed to
`jwulff/homebrew-tap` directly so `brew install jwulff/tap/dictamac`
works today; this PR syncs the canonical in-repo copy.

### 1. Real v0.1.0 tarball SHA256

Previous: `0019dfc4b32d63c1392aa264aed2253c1e0c2fb09216f8e2cc269bbfb8bb49b5`
Current:  `ffb72eedd13db1eb27e16837b44b363360638f61f4240def3fb9d04bab633658`

The previous SHA was computed before the upstream repo (jwulff/dictamac)
was made public. `curl -sL` silently swallowed the 404 response from
the `/archive/refs/tags/v0.1.0.tar.gz` URL (private repos return 404
to unauthenticated requests, which is what GitHub's archive endpoint
behaves as) and `shasum -a 256` happily hashed the 9-byte literal
`"Not Found"` body, producing the bogus SHA that ended up pinned in
the formula.

To prove it:

```
$ printf "Not Found" | shasum -a 256
0019dfc4b32d63c1392aa264aed2253c1e0c2fb09216f8e2cc269bbfb8bb49b5  -
```

The actual SHA was obtained via `gh release download v0.1.0 --archive=tar.gz`
(which uses the API, authenticated, and works on private repos) and
re-confirmed against the public `/archive/` URL after the repo was
flipped to public.

### 2. `swift build --disable-sandbox` instead of `make build`

Homebrew wraps the formula's install block in `sandbox-exec`.
SwiftPM internally also invokes `sandbox-exec` when compiling the
`Package.swift` manifest. Nested sandboxing isn't allowed on macOS —
the inner `sandbox-exec` fails with:

```
sandbox-exec: sandbox_apply: Operation not permitted
error: 'dictamac-0.1.0': Invalid manifest (...)
```

`--disable-sandbox` tells SwiftPM to skip its own layer. This is
safe under `brew install` because the build is already sandboxed by
Homebrew's outer wrapper.

To pass the flag cleanly, the formula now invokes `swift build`
directly (instead of `make build`) with the same `-Xlinker
-sectcreate __TEXT __info_plist Resources/Info.plist` flags the
Makefile uses, then runs `codesign` with the same entitlements
`make sign` uses, then `bin.install`s the signed binary. The
Makefile is unchanged — contributors building outside Homebrew
still use `make build` and get the normal SwiftPM sandbox.

## Why

The first SHA bug was masked by `curl -sL`'s silent error-swallowing.
`curl -fL` would have surfaced the 404 immediately; consider it a
hard-won learning for future release procedures (worth a callout in
PLAN.md §7 or wherever the release recipe lives). The sandbox issue
is a generic SwiftPM + Homebrew interaction — any Swift package
shipping as a Homebrew formula will hit it.

## Verification

```
$ brew tap jwulff/tap
$ brew install jwulff/tap/dictamac
🍺  /opt/homebrew/Cellar/dictamac/0.1.0: 6 files, 2.3MB, built in 14 seconds

$ dictamac --version
0.1.0

$ dictamac Tests/DictamacSpeechTests/Fixtures/hello-world.m4a
Hello, world, this is a test.
```

`make test` not impacted — formula change has no Swift surface.

## Follow-ups

- Audit other GitHub-tarball formulae using `curl -sL` recipes for
  the same silent-404 trap. `curl -fL` should be the project default
  in any release documentation.
- Consider adding `SWIFT_BUILD_FLAGS` to the Makefile so the
  formula can re-use `make build SWIFT_BUILD_FLAGS=--disable-sandbox`
  instead of duplicating the build incantation. Cosmetic; deferred.
