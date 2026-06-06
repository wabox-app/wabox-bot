#!/usr/bin/env bash
# faster-whisper transcription plugin for wabox-bot.
#
# Contract: the audio file path is the last argument; the transcript is printed
# to stdout. faster-whisper decodes OGG/Opus directly, so no conversion is
# needed. Args are passed to the embedded Python via argv to avoid quoting
# pitfalls.
set -euo pipefail

audio="${1:?usage: transcribe.sh <audio-file>}"
model="${WABOX_FW_MODEL:-base}"
device="${WABOX_FW_DEVICE:-cpu}"
compute="${WABOX_FW_COMPUTE:-int8}"
lang="${WABOX_TRANSCRIBE_LANG:-}"

exec python3 - "$audio" "$model" "$device" "$compute" "$lang" <<'PY'
import sys
from faster_whisper import WhisperModel

audio, model, device, compute, lang = sys.argv[1:6]
m = WhisperModel(model, device=device, compute_type=compute)
segments, _ = m.transcribe(audio, language=(lang or None))
print("".join(seg.text for seg in segments).strip())
PY
