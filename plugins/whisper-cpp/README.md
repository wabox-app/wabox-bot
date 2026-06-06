# whisper.cpp plugin

Wraps [`whisper.cpp`](https://github.com/ggerganov/whisper.cpp)'s `whisper-cli`.
The leanest fully-offline option; needs a ggml model and converts the audio to
16 kHz WAV with ffmpeg.

## Install

    # Arch (AUR)
    yay -S whisper.cpp          # provides `whisper-cli`; whisper.cpp-cuda for NVIDIA
    sudo pacman -S ffmpeg

Download a model, e.g.:

    mkdir -p ~/.local/share/whisper
    curl -L -o ~/.local/share/whisper/ggml-base.bin \
      https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin

## Configure

| Env var | Default | Meaning |
| --- | --- | --- |
| `WABOX_WHISPERCPP_MODEL` | (required) | Path to the ggml `.bin` model. |
| `WABOX_WHISPERCPP_BIN` | `whisper-cli` | Binary name or path. |
| `WABOX_TRANSCRIBE_LANG` | `auto` | Force a language, e.g. `pt`. |

    export WABOX_WHISPERCPP_MODEL=~/.local/share/whisper/ggml-base.bin
    export WABOX_TRANSCRIBE_CMD=/abs/path/to/wabox-bot/plugins/whisper-cpp/transcribe.sh

## Smoke test

    ./transcribe.sh /path/to/voice-note.ogg
