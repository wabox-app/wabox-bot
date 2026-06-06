# faster-whisper plugin

[faster-whisper](https://github.com/SYSTRAN/faster-whisper) is a fast CTranslate2
reimplementation of Whisper. Good accuracy, runs well on CPU with `int8`, and
decodes OGG/Opus directly (no manual conversion).

## Install

    pipx install faster-whisper      # or: pip install --user faster-whisper

Arch: `python` ships in the base system; `pipx` is `sudo pacman -S python-pipx`.
The model downloads automatically on first run.

## Configure

| Env var | Default | Meaning |
| --- | --- | --- |
| `WABOX_FW_MODEL` | `base` | Model size (`tiny`/`base`/`small`/`medium`/`large-v3`) or a path. |
| `WABOX_FW_DEVICE` | `cpu` | `cpu` or `cuda`. |
| `WABOX_FW_COMPUTE` | `int8` | Compute type (`int8`, `int8_float16`, `float16`, …). |
| `WABOX_TRANSCRIBE_LANG` | (auto) | Force a language, e.g. `pt`. |

    export WABOX_TRANSCRIBE_CMD=/abs/path/to/wabox-bot/plugins/faster-whisper/transcribe.sh
    export WABOX_TRANSCRIBE_LANG=pt   # optional

## Smoke test

    ./transcribe.sh /path/to/voice-note.ogg
