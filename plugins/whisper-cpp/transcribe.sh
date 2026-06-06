#!/usr/bin/env bash
# whisper.cpp transcription plugin for wabox-bot.
#
# Contract: audio path is the last argument; transcript printed to stdout.
# whisper-cli only reads 16 kHz mono WAV, so we convert with ffmpeg first.
set -euo pipefail

audio="${1:?usage: transcribe.sh <audio-file>}"
bin="${WABOX_WHISPERCPP_BIN:-whisper-cli}"
model="${WABOX_WHISPERCPP_MODEL:?set WABOX_WHISPERCPP_MODEL to the path of a ggml model}"
lang="${WABOX_TRANSCRIBE_LANG:-auto}"

if [[ ! -f "$model" ]]; then
  printf 'whisper-cpp: model not found: %s\n' "$model" >&2
  exit 1
fi

wav="$(mktemp --suffix=.wav)"
trap 'rm -f "$wav"' EXIT
ffmpeg -nostdin -loglevel error -y -i "$audio" -ar 16000 -ac 1 -c:a pcm_s16le "$wav"

# -np: no progress prints, -nt: no timestamps → clean transcript on stdout.
"$bin" -m "$model" -f "$wav" -l "$lang" -np -nt
