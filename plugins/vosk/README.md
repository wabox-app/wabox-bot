# Vosk plugin

[Vosk](https://alphacephei.com/vosk/) is a lightweight offline engine — small
models, low CPU use, decent accuracy. The model is **language-specific**, so
`WABOX_TRANSCRIBE_LANG` does not apply; install the model for your language.

## Install

    pipx install vosk         # or: pip install --user vosk
    sudo pacman -S ffmpeg     # Arch

Download and unzip a model, e.g. Portuguese:

    curl -LO https://alphacephei.com/vosk/models/vosk-model-small-pt-0.3.zip
    unzip vosk-model-small-pt-0.3.zip -d ~/.local/share/vosk

## Configure

| Env var | Default | Meaning |
| --- | --- | --- |
| `WABOX_VOSK_MODEL` | (required) | Path to the unzipped model directory. |

    export WABOX_VOSK_MODEL=~/.local/share/vosk/vosk-model-small-pt-0.3
    export WABOX_TRANSCRIBE_CMD=/abs/path/to/wabox-bot/plugins/vosk/transcribe.sh

## Smoke test

    ./transcribe.sh /path/to/voice-note.ogg
