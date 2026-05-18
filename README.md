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

### From source (recommended for now)

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

### Homebrew (coming soon)

Once the `jwulff/homebrew-tap` repo is published with the v0.1.0 formula,
the recommended install will be:

```bash
brew install jwulff/tap/dictamac
```

This is **not yet available** — the tap repo and v0.1.0 release tag are
post-merge user actions tracked in
[#9](https://github.com/jwulff/dictamac/issues/9). Until then, use the
from-source path above.

A sample Homebrew formula lives at
[`Formula/dictamac.rb`](Formula/dictamac.rb) so the formula can be
reviewed alongside the code it builds; the canonical, brew-installable
copy will live in the tap repo once it's published.

## Requirements

- **macOS 26 (Tahoe) or later** — uses the `SpeechAnalyzer` /
  `SpeechTranscriber` APIs introduced in macOS 26. Older macOS releases
  cannot run dictamac.
- **Swift 6.x toolchain** — Xcode 16 or later, or a standalone Swift
  toolchain installer. Required only when building from source (the
  Homebrew formula also builds from source for now, so it also needs
  this).
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
