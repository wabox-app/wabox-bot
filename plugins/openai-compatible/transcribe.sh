#!/usr/bin/env bash
# OpenAI-compatible /audio/transcriptions plugin for wabox-bot.
#
# Contract: audio path is the last argument; transcript printed to stdout.
# Works with any OpenAI-compatible endpoint (OpenAI, Groq, …). response_format
# = text makes the API return a plain transcript. The audio leaves the machine.
set -euo pipefail

audio="${1:?usage: transcribe.sh <audio-file>}"
url="${WABOX_STT_API_URL:-https://api.openai.com/v1/audio/transcriptions}"
key="${WABOX_STT_API_KEY:?set WABOX_STT_API_KEY to your API key}"
model="${WABOX_STT_API_MODEL:-whisper-1}"
lang="${WABOX_TRANSCRIBE_LANG:-}"

args=(-fsS "$url"
  -H "Authorization: Bearer $key"
  -F "model=$model"
  -F "response_format=text"
  -F "file=@$audio")
[[ -n "$lang" ]] && args+=(-F "language=$lang")

curl "${args[@]}"
