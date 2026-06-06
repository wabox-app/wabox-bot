#!/usr/bin/env bash
# OpenAI Whisper (reference CLI) transcription plugin for wabox-bot.
#
# Contract: audio path is the last argument; transcript printed to stdout. The
# whisper CLI writes output files and prints progress, so we send it to a temp
# dir, silence its stdout/stderr, and cat the resulting .txt.
set -euo pipefail

audio="${1:?usage: transcribe.sh <audio-file>}"
model="${WABOX_OPENAI_WHISPER_MODEL:-base}"
lang="${WABOX_TRANSCRIBE_LANG:-}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

args=(--model "$model" --output_format txt --output_dir "$tmp" --fp16 False)
[[ -n "$lang" ]] && args+=(--language "$lang")

whisper "$audio" "${args[@]}" >/dev/null
cat "$tmp"/*.txt
