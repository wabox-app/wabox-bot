#!/usr/bin/env bash
# Vosk transcription plugin for wabox-bot.
#
# Contract: audio path is the last argument; transcript printed to stdout. Vosk
# reads 16 kHz mono WAV, so we convert with ffmpeg first. The model is
# language-specific, so WABOX_TRANSCRIBE_LANG does not apply here.
set -euo pipefail

audio="${1:?usage: transcribe.sh <audio-file>}"
model="${WABOX_VOSK_MODEL:?set WABOX_VOSK_MODEL to a Vosk model directory}"

if [[ ! -d "$model" ]]; then
  printf 'vosk: model directory not found: %s\n' "$model" >&2
  exit 1
fi

wav="$(mktemp --suffix=.wav)"
trap 'rm -f "$wav"' EXIT
ffmpeg -nostdin -loglevel error -y -i "$audio" -ar 16000 -ac 1 -c:a pcm_s16le "$wav"

exec python3 - "$wav" "$model" <<'PY'
import sys, json, wave
from vosk import Model, KaldiRecognizer

wav_path, model_path = sys.argv[1:3]
wf = wave.open(wav_path, "rb")
rec = KaldiRecognizer(Model(model_path), wf.getframerate())
parts = []
while True:
    data = wf.readframes(4000)
    if not data:
        break
    if rec.AcceptWaveform(data):
        parts.append(json.loads(rec.Result()).get("text", ""))
parts.append(json.loads(rec.FinalResult()).get("text", ""))
print(" ".join(p for p in parts if p).strip())
PY
