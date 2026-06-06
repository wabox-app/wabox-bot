# Transcription plugins

Ready-made transcribers for wabox-bot's `WABOX_TRANSCRIBE_CMD` (inbound audio /
voice notes). Each subfolder is a self-contained plugin: a `transcribe.sh`
entrypoint plus a README with install and configuration steps.

## The contract

wabox-bot word-splits `WABOX_TRANSCRIBE_CMD`, appends the audio file path as the
**last argument**, and reads the transcript from **stdout**. Empty/whitespace
output or a non-zero exit is treated as a failure. Point the env var at a
plugin's script (use an absolute path):

    export WABOX_TRANSCRIBE_CMD=/abs/path/to/wabox-bot/plugins/<name>/transcribe.sh

Inbound WhatsApp audio is Opus-in-OGG; each plugin handles the format (converting
with ffmpeg where the engine needs WAV).

## Language

Every plugin honors `WABOX_TRANSCRIBE_LANG` (e.g. `pt`, `en`); leave it empty for
auto-detection. Exception: **vosk**'s language is fixed by the installed model,
so it ignores this variable.

## Plugins

| Plugin | Runs | Needs |
| --- | --- | --- |
| [`faster-whisper`](faster-whisper/) | locally (CPU/GPU, fast) | Python + `faster-whisper` |
| [`whisper-cpp`](whisper-cpp/) | locally (compiled, lean) | `whisper-cli` + `ffmpeg` + a ggml model |
| [`openai-whisper`](openai-whisper/) | locally (reference) | Python + `openai-whisper` + `ffmpeg` |
| [`vosk`](vosk/) | locally (lightweight) | Python + `vosk` + `ffmpeg` + a model |
| [`openai-compatible`](openai-compatible/) | remote API | `curl` + an API key (OpenAI, Groq, …) |
