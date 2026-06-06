# Transcription plugins folder

**Date:** 2026-06-06
**Status:** Approved (design)

## Problem

`WABOX_TRANSCRIBE_CMD` lets users wire any speech-to-text command into the
audio-message flow, but the project ships no ready-to-use transcribers. Each
user must research a tool, learn its CLI, and write a wrapper that conforms to
the contract. We want a `plugins/` folder with ready-made, documented wrappers
for the common STT options.

## Contract recap

The bot word-splits `WABOX_TRANSCRIBE_CMD` and appends the audio file path as
the **last argument**; it reads the transcript from **stdout**. Empty or
whitespace-only output, or a non-zero exit, is treated as a failure (the user
gets a "could not transcribe" reply). Inbound audio is WhatsApp voice notes:
Opus-in-OGG (`audio/ogg; codecs=opus`).

## Goal

Ship five plugins, each a self-contained `transcribe.sh` entrypoint plus a
`README.md`, covering the options already discussed:

- **faster-whisper** — CTranslate2 Whisper, fast on CPU (`int8`), decodes OGG directly.
- **whisper-cpp** — `whisper-cli` from whisper.cpp; needs ffmpeg WAV conversion.
- **openai-whisper** — reference Python Whisper CLI.
- **vosk** — lightweight offline engine; model is language-specific.
- **openai-compatible** — `curl` to any OpenAI-compatible `/audio/transcriptions` endpoint (covers OpenAI and Groq).

## Non-goals

- Installing the engines or downloading models — the READMEs document how; the
  plugins assume the tool/model is present and fail clearly if not.
- Functional STT tests in CI (no models, keys, or network there).
- Changing the core `WABOX_TRANSCRIBE_CMD` contract — plugins conform to it as-is.
- A plugin registry/loader — these are plain scripts the user points the env var at.

## Structure

Top-level `plugins/`, one folder per plugin (flat — no `transcribe/` sublevel,
since every current plugin is a transcriber):

```
plugins/
  README.md                          # index + contract + WABOX_TRANSCRIBE_LANG
  faster-whisper/    { transcribe.sh, README.md }
  whisper-cpp/       { transcribe.sh, README.md }
  openai-whisper/    { transcribe.sh, README.md }
  vosk/              { transcribe.sh, README.md }
  openai-compatible/ { transcribe.sh, README.md }
```

Each `transcribe.sh`:
- Starts with `#!/usr/bin/env bash` and `set -euo pipefail`, is `chmod +x`.
- Takes the audio path as `$1` (the contract's last/only appended arg).
- Validates required env vars / inputs and exits non-zero with a clear stderr
  message if missing (e.g. unset API key, missing model).
- Prints only the transcript to stdout (no progress/timestamps/log noise).
- The user sets `WABOX_TRANSCRIBE_CMD=/abs/path/plugins/<name>/transcribe.sh`.

## Common behavior

- **Language:** every plugin reads `WABOX_TRANSCRIBE_LANG`; empty ⇒ auto-detect.
  Exception: **vosk** ignores it (language is fixed by the downloaded model) —
  noted in its README.
- **Audio format:** whisper-cpp and vosk need 16 kHz mono PCM WAV, so their
  wrappers convert with `ffmpeg -ar 16000 -ac 1 -c:a pcm_s16le` into a temp file
  cleaned up via `trap`. faster-whisper, openai-whisper, and the API plugin
  accept OGG directly (they invoke ffmpeg/av themselves or upload the file).
- **Failure:** any missing prerequisite or tool error exits non-zero; combined
  with the bot's empty/whitespace check, the user always gets a clear outcome.

## Per-plugin environment variables

All have sensible defaults except where marked **required**.

| Plugin | Variables |
| --- | --- |
| faster-whisper | `WABOX_FW_MODEL` (default `base`), `WABOX_FW_DEVICE` (default `cpu`), `WABOX_FW_COMPUTE` (default `int8`), `WABOX_TRANSCRIBE_LANG` (auto) |
| whisper-cpp | `WABOX_WHISPERCPP_BIN` (default `whisper-cli`), `WABOX_WHISPERCPP_MODEL` (**required**, path to `.bin`), `WABOX_TRANSCRIBE_LANG` (auto) |
| openai-whisper | `WABOX_OPENAI_WHISPER_MODEL` (default `base`), `WABOX_TRANSCRIBE_LANG` (auto) |
| vosk | `WABOX_VOSK_MODEL` (**required**, model directory) |
| openai-compatible | `WABOX_STT_API_URL` (default `https://api.openai.com/v1/audio/transcriptions`), `WABOX_STT_API_KEY` (**required**), `WABOX_STT_API_MODEL` (default `whisper-1`), `WABOX_TRANSCRIBE_LANG` (auto) |

## Plugin implementation notes

- **faster-whisper** (`transcribe.sh`): bash wrapper that `exec python3 - "$1"`
  with a heredoc using `faster_whisper.WhisperModel(WABOX_FW_MODEL, device=…,
  compute_type=…)`; `transcribe(path, language=<lang or None>)`; print the joined
  segment text, stripped.
- **whisper-cpp**: convert OGG→WAV with ffmpeg, then
  `"$WABOX_WHISPERCPP_BIN" -m "$WABOX_WHISPERCPP_MODEL" -f "$wav" -l "${lang:-auto}" -np -nt`.
  Error if the model file is missing.
- **openai-whisper**: run `whisper "$1" --model … [--language …] --output_format txt
  --output_dir "$tmp"` quietly, then `cat "$tmp"/*.txt`.
- **vosk**: convert OGG→WAV, then `exec python3 - "$wav"` heredoc using
  `vosk.Model(WABOX_VOSK_MODEL)` + `KaldiRecognizer`, concatenating the
  recognized text. Error if `WABOX_VOSK_MODEL` is unset/missing.
- **openai-compatible**: `curl -fsS "$WABOX_STT_API_URL" -H "Authorization: Bearer
  $WABOX_STT_API_KEY" -F model="$WABOX_STT_API_MODEL" -F response_format=text
  [-F language="$lang"] -F file=@"$1"`. Error if the key is unset.

## Documentation

- `plugins/README.md`: explains the `WABOX_TRANSCRIBE_CMD` contract once, the
  shared `WABOX_TRANSCRIBE_LANG` convention, and a one-line index of the five
  plugins with a pointer to each plugin's README.
- Each `plugins/<name>/README.md`: **Install** (Arch via pacman/AUR/`yay` plus
  generic `pip`/`pipx`/`ffmpeg`), **Configure** (the plugin's env vars and an
  example `export WABOX_TRANSCRIBE_CMD=…`), and a **Smoke test**
  (`./transcribe.sh sample.ogg` should print only the transcript).
- `README.md` (root): a short pointer near the `WABOX_TRANSCRIBE_CMD` config rows
  ("Ready-made transcribers live in `plugins/` — see `plugins/README.md`").
- `CONTRIBUTING.md`: add `plugins/` to the Project layout list.

## Testing

- **CI shellcheck:** add `shellcheck plugins/*/transcribe.sh` to the workflow.
  The bash portions (including those wrapping a Python heredoc) are linted; the
  heredoc body is opaque to shellcheck, which is fine.
- **Structure test** (`test/bats/plugins.bats`): for each plugin directory under
  `plugins/`, assert that `transcribe.sh` exists, is executable, starts with a
  `#!` shebang, passes `bash -n` (syntax check), and that a `README.md` exists.
  This guards structure and catches syntax breakage without running STT. No
  functional transcription is exercised.

## Error handling

- Missing required env var (API key, model path/dir) → print a clear message to
  stderr naming the variable, exit non-zero. The README documents each.
- Missing tool (`ffmpeg`, `whisper-cli`, `python3`, `curl`, the Python package)
  → the natural command-not-found / import error propagates as non-zero exit.
  READMEs list prerequisites so this is diagnosable.
- All failures surface to the user via the bot's existing "could not transcribe"
  reply, since the wrappers exit non-zero or emit nothing.
