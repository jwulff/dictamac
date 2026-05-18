# Prep Homebrew formula: PREFIX support, README, sample

PR: #59
Issues: Refs #9

## What changed

Three in-repo pieces that the eventual `brew install jwulff/tap/dictamac`
flow needs to be ready before the tap repo and v0.1 release tag exist:

1. **Makefile** — verified that `make install` already honors a
   `PREFIX` override (`PREFIX ?= $(HOME)/.local`) and lays the binary
   under `$(PREFIX)/bin`. No code change was required; the previous
   author already designed the target with Homebrew in mind. Confirmed
   end-to-end against `/tmp/dictamac-install-test`.
2. **README.md** — replaced the placeholder "Not yet released" install
   section with a real Homebrew block and a from-source block that
   documents the `PREFIX` override. The Requirements section now calls
   out macOS 26 (Tahoe), Swift 6.x toolchain, both TCC permissions, and
   the on-demand locale model.
3. **`Formula/dictamac.rb`** — a sample, in-repo copy of the Homebrew
   formula that brew will eventually consume from the
   `jwulff/homebrew-tap` repo. Lives here so the formula gets reviewed
   alongside the code it builds; the canonical install-time copy lives
   in the tap repo.

No source code, tests, entitlements, plist, plan doc, hooks, or CLAUDE.md
were touched — those are owned by parallel agents (#56, #44+#32, #33) on
the same `main` base.

## Why

`brew install jwulff/tap/dictamac` is the user-facing install story per
issue #9. Until the formula exists and the build target it invokes
(`make install PREFIX=...`) is verified, the Homebrew path is fiction.
This PR closes the gap for the dictamac-side pieces; the tap-repo
creation and v0.1 release tag are explicit user actions documented in
the release procedure below.

## How

### Makefile PREFIX (already in place)

`make install` was already written as:

```makefile
PREFIX ?= $(HOME)/.local

install: build
	mkdir -p "$(PREFIX)/bin"
	cp .build/release/dictamac "$(PREFIX)/bin/"
```

`PREFIX ?=` means "default to `~/.local` unless the caller sets it" —
exactly what Homebrew needs (`make install PREFIX=#{prefix}`). The
homebrew sandbox sets `prefix` to the keg root and the binary lands at
`#{prefix}/bin/dictamac`, which `brew link` then symlinks into
`/opt/homebrew/bin/`. No quirks to note; the previous author already
thought this through.

End-to-end verification:

```
$ make install PREFIX=/tmp/dictamac-install-test
[1/1] Write swift-version--58304C5D6DBC2206.txt
Build complete! (1.35s)
codesign --sign - --options runtime \
        --entitlements Resources/dictamac.entitlements \
        --force ".build/release/dictamac"
.build/release/dictamac: replacing existing signature
mkdir -p "/tmp/dictamac-install-test/bin"
cp .build/release/dictamac "/tmp/dictamac-install-test/bin/"

$ /tmp/dictamac-install-test/bin/dictamac --version
0.0.0-dev
```

### Formula shape

Three design choices in the sample formula worth recording:

1. **macOS gate via `depends_on macos: :tahoe`.** `:tahoe` is the
   Homebrew DSL macro for macOS 26 (Tahoe). Confirmed against
   `/opt/homebrew/Library/Homebrew/macos_version.rb` on this machine
   (Homebrew 5.1.9), which lists `tahoe: "26"`. Older Homebrew installs
   that predate the `:tahoe` macro will fail to parse the formula
   loudly, which is the desired behavior — dictamac literally cannot
   run on those systems either.
2. **Swift toolchain via `depends_on xcode: ["16.0", :build]`.** Xcode
   16+ ships Swift 6.x; the `:build` flag tells Homebrew Swift is only
   needed at compile time, not at runtime. The dependency falls back to
   Apple's standalone Command Line Tools if Xcode proper is not
   installed, matching how a contributor would build from source.
3. **`test do` smoke check via `--version`.** A real transcription
   would require Speech Recognition TCC permission, which is unavailable
   in `brew test`'s sandbox (it runs without a controlling user
   session). `--version` is the strongest assertion we can make in that
   environment; the matched regex (`/\d+\.\d+\.\d+/`) catches the case
   where the binary loads but `--version` prints something unexpected.

The formula carries `head "https://github.com/jwulff/dictamac.git",
branch: "main"` so contributors can do `brew install --HEAD
jwulff/tap/dictamac` to test against tip-of-main. Normal users get the
tagged tarball pinned by `url` + `sha256`.

### README structure

The Requirements section follows the same shape as the issue body's
"Notes" — macOS version, toolchain, permissions, locale model. The
from-source block calls out `swift run` explicitly as a footgun (skips
codesign, `SIGTRAP` on first SpeechAnalyzer touch) to head off the
inevitable contributor mistake.

## Post-merge release procedure

The acceptance criteria for #9 require a v0.1.0 tag, a GitHub release
with a source tarball, and the formula's `sha256` filled in with the
tarball's real digest. None of that can happen from a feature branch —
it's a sequence of user actions after this PR merges. Documented here so
future-John (or any contributor) can execute it without rehydrating
context:

```bash
# 1. After this PR merges into main, on the merge commit, tag v0.1.0.
git checkout main
git pull
git tag -a v0.1.0 -m "Initial Homebrew-installable release"
git push origin v0.1.0

# 2. Create a GitHub release pointing at the tag. The tarball at
#    https://github.com/jwulff/dictamac/archive/refs/tags/v0.1.0.tar.gz
#    is auto-generated by GitHub from the tag — no upload needed.
gh release create v0.1.0 \
  --title "v0.1.0 — Initial Homebrew-installable release" \
  --notes "First Homebrew-installable release. Install via:

  brew install jwulff/tap/dictamac

See README.md for full documentation. Build-from-source formula; bottled
distribution is deferred per #9 'Out of scope'."

# 3. Compute the SHA256 of the auto-generated source tarball. GitHub
#    serves the tarball deterministically; the digest is stable for the
#    life of the tag.
SHA256=$(curl -sL https://github.com/jwulff/dictamac/archive/refs/tags/v0.1.0.tar.gz \
  | shasum -a 256 | awk '{print $1}')
echo "$SHA256"

# 4. Update the in-repo Formula/dictamac.rb with that SHA256 (open a
#    follow-up PR). At the same time, take the same formula content and
#    publish it to the tap repo:
#
#    a. Create https://github.com/jwulff/homebrew-tap if it does not
#       exist yet. The repo must be named exactly `homebrew-tap` for
#       `brew install jwulff/tap/...` to resolve.
#    b. Copy Formula/dictamac.rb from this repo to
#       Formula/dictamac.rb in the tap repo (with the SHA256 from
#       step 3 substituted in).
#    c. Commit and push the tap repo's main branch.
#
# 5. Verify on a clean macOS 26 machine (or after `brew untap`):
brew tap jwulff/tap
brew install jwulff/tap/dictamac
dictamac --version
dictamac --help
```

Step 4(a)–(c) is the only piece that lives outside `jwulff/dictamac`
entirely. Once it's done, every subsequent dictamac release is a smaller
loop: tag → release → recompute SHA → update both `Formula/dictamac.rb`
files → push tap.

## Out of scope (deferred to follow-up issues)

- **Bottled distribution.** Pre-built `.tar.gz` artifacts per
  architecture are a per-release operational burden; the issue
  explicitly defers them until the binary stabilizes. From-source brew
  installs take ~60s on Apple Silicon, which is acceptable for a tool
  this small.
- **Notarization.** Ad-hoc codesigning is the MVP per #9. Notarization
  would require an Apple Developer account and a Hardened Runtime
  config; deferred until the project decides whether to ship outside
  Homebrew.
- **`Run-Host:` provenance on this commit.** The user-level CLAUDE.md
  instruction adds the trailer automatically via the in-repo
  `prepare-commit-msg` hook; nothing extra to do here.

## Follow-ups

When v0.1.0 ships:

- File a follow-up issue to update `Formula/dictamac.rb`'s `sha256` with
  the real digest (step 4 above). This must happen in a separate PR
  because the SHA can only be computed after the release tag exists.
- File a follow-up to create and populate `jwulff/homebrew-tap` with the
  same formula content. This is a user action — Claude does not have
  write access to a repo that doesn't exist yet.

## Anti-patterns avoided

- No source / test / hook / plan / CLAUDE.md edits (other agents' turf).
- No `--no-verify` git operations.
- No release tag created from a feature branch.
- No real SHA256 in the formula — it's a placeholder by design; pretending
  to know the tarball digest before the tag exists would ship a broken
  formula.
- No `:sequoia` / older macOS macro — `:tahoe` is correct for macOS 26
  on this Homebrew (5.1.9) and is the version Apple ships.
