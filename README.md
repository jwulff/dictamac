# dictamac

> macOS CLI for transcribing audio files via Apple's SpeechAnalyzer. Agent-shaped: stdout-friendly CLI plus MCP server, both in one binary.

**Status:** in development. Not yet released.

## What it does

Transcribes audio files on macOS using the macOS 26 SpeechAnalyzer / SpeechTranscriber API — the same on-device speech model that powers system features like the Voice Memos transcript view. No model download, no GPU, no Python.

```bash
$ dictamac ~/Downloads/meeting.m4a
Hey everyone, thanks for jumping on. So the plan for next quarter is...
```

JSON output with timestamps:

```bash
$ dictamac --json ~/Downloads/meeting.m4a
{
  "version": "1",
  "locale": "en-US",
  "durationSeconds": 184.3,
  "segments": [
    {"startSeconds": 0.0, "endSeconds": 3.2, "text": "Hey everyone, thanks for jumping on.", "confidence": 0.94},
    ...
  ],
  "fullText": "Hey everyone, thanks for jumping on. ..."
}
```

Voice Memos lookup — find and transcribe a recording the Voice Memos app hasn't transcribed yet:

```bash
$ dictamac --voice-memo "yesterday's standup"
$ dictamac --list-voice-memos --since 7d
2026-05-12 14:03  Quick idea
2026-05-12 09:15  Standup recap
2026-05-10 18:22  Walk thoughts
```

## Why it exists

Apple's Voice Memos app transcribes recordings only when it feels like it — there's no public way to force-trigger transcription. dictamac fills that gap, and offers a clean MCP transport so AI agents can transcribe files as part of their workflow.

## MCP mode

`dictamac --mcp` runs an MCP stdio server exposing three tools:

- `transcribe_file` — transcribe an audio file by path
- `transcribe_voice_memo` — find and transcribe a Voice Memo by title or date
- `list_voice_memos` — list recent Voice Memos with metadata

## Install

### Homebrew (recommended)

```bash
brew install jwulff/tap/dictamac
```

That's it — Homebrew taps [`jwulff/homebrew-tap`](https://github.com/jwulff/homebrew-tap),
fetches the [v0.1.0 source tarball](https://github.com/jwulff/dictamac/releases/tag/v0.1.0),
builds with Swift, ad-hoc signs the binary with the `SpeechAnalyzer`
entitlements, and drops it at `/opt/homebrew/bin/dictamac`. Build
takes about 15 seconds on Apple Silicon.

### From source

```bash
git clone https://github.com/jwulff/dictamac.git
cd dictamac
make build
make install            # installs to ~/.local/bin by default
make install PREFIX=/usr/local   # or override the prefix
```

`make build` ad-hoc signs the release binary with the entitlements
`SpeechAnalyzer` needs at launch. Don't use `swift run` — it skips the
codesign step and the resulting binary will `SIGTRAP` on first
SpeechAnalyzer touch.

The canonical [`Formula/dictamac.rb`](Formula/dictamac.rb) lives in
this repo so the recipe can be code-reviewed alongside the code it
builds; the actively-installed copy is mirrored to
[`jwulff/homebrew-tap`](https://github.com/jwulff/homebrew-tap) on
each release.

## Requirements

- **macOS 26 (Tahoe) or later** — uses the `SpeechAnalyzer` /
  `SpeechTranscriber` APIs introduced in macOS 26. Older macOS releases
  cannot run dictamac.
- **Swift 6.x toolchain** — Xcode 16 or later, or a standalone Swift
  toolchain installer. Required whether you install via Homebrew (the
  formula builds from source) or directly via `make build`. The
  formula explicitly checks for Xcode 26+ because that's the toolchain
  ships the macOS 26 SDK that `SpeechAnalyzer` lives in.
- **Apple Silicon recommended**; Intel works but slower.
- **Speech Recognition permission** — granted on first run via the
  deep-link printed to stderr.
- **Files & Folders permission** for Voice Memos library access, needed
  only for `--voice-memo` / `--list-voice-memos` modes.
- **Locale model** — downloads automatically on first use; needs a
  working network connection at that moment.

## Related

- [steno](https://github.com/jwulff/steno) — live capture daemon for macOS speech-to-text, using the same SpeechAnalyzer stack

## License

MIT
