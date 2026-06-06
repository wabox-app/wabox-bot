# OpenAI-compatible API plugin

Sends the audio to any OpenAI-compatible `/audio/transcriptions` endpoint via
`curl`. No local model or GPU — but the audio leaves your machine and you need
an API key. Works with OpenAI and Groq (and other compatible providers).

## Install

    sudo pacman -S curl    # Arch (usually already present)

## Configure

| Env var | Default | Meaning |
| --- | --- | --- |
| `WABOX_STT_API_KEY` | (required) | Your API key. |
| `WABOX_STT_API_URL` | `https://api.openai.com/v1/audio/transcriptions` | Endpoint. |
| `WABOX_STT_API_MODEL` | `whisper-1` | Model name. |
| `WABOX_TRANSCRIBE_LANG` | (auto) | Force a language, e.g. `pt`. |

OpenAI:

    export WABOX_STT_API_KEY=sk-...
    export WABOX_TRANSCRIBE_CMD=/abs/path/to/wabox-bot/plugins/openai-compatible/transcribe.sh

Groq:

    export WABOX_STT_API_URL=https://api.groq.com/openai/v1/audio/transcriptions
    export WABOX_STT_API_KEY=gsk-...
    export WABOX_STT_API_MODEL=whisper-large-v3
    export WABOX_TRANSCRIBE_CMD=/abs/path/to/wabox-bot/plugins/openai-compatible/transcribe.sh

## Smoke test

    ./transcribe.sh /path/to/voice-note.ogg
