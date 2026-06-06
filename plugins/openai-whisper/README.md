# OpenAI Whisper plugin

Wraps the reference [openai-whisper](https://github.com/openai/whisper) CLI.
Simplest to install, but heavy (pulls in PyTorch) and slower on CPU.

## Install

    pipx install openai-whisper       # or: pip install --user openai-whisper
    sudo pacman -S ffmpeg             # Arch; whisper requires ffmpeg

## Configure

| Env var | Default | Meaning |
| --- | --- | --- |
| `WABOX_OPENAI_WHISPER_MODEL` | `base` | Model (`tiny`/`base`/`small`/`medium`/`large`). |
| `WABOX_TRANSCRIBE_LANG` | (auto) | Force a language, e.g. `pt`. |

    export WABOX_TRANSCRIBE_CMD=/abs/path/to/wabox-bot/plugins/openai-whisper/transcribe.sh

## Smoke test

    ./transcribe.sh /path/to/voice-note.ogg
