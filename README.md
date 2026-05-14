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

Not yet released. See [docs/PLAN.md](docs/PLAN.md) for the implementation plan.

Eventual install via Homebrew:

```bash
brew install jwulff/tap/dictamac
```

## Requirements

- macOS 26 (Tahoe) or later — SpeechAnalyzer API
- Apple Silicon recommended; Intel works but slower
- Locale model installed (downloads automatically on first use)

## Related

- [steno](https://github.com/jwulff/steno) — live capture daemon for macOS speech-to-text, using the same SpeechAnalyzer stack

## License

MIT
