load test_helper

# Task 1: lib/inbox.sh persists conv_key + last_message.json per slug so that
# `wabox-bot state` can enumerate conversations and sort them by activity.

setup() {
  setup_lib
  export WABOX_BOT_BACKEND=echo
  load_core
  # shellcheck source=lib/inbox.sh
  source "$LIB_DIR/inbox.sh"
  JID="5511999999999@s.whatsapp.net"
  SLUG="$(printf '%s' "$JID" | sha1sum | awk '{print $1}')"
}

teardown() {
  teardown_lib
}

mk_envelope() {
  local stem="$1" json="$2" media_name="$3"
  printf '%s' "$json" >"$WABOX_INBOX/$stem.json"
  [[ -n "$media_name" ]] && printf 'fake-bytes' >"$WABOX_INBOX/$media_name"
  return 0
}

@test "a handled text message writes conv_key and last_message.json" {
  stem="20260101-000000_x_AAAA"
  mk_envelope "$stem" \
    "$(jq -nc --arg j "$JID" '{id:"M1",from:$j,text:"hello there"}')" ""
  handle_envelope "$WABOX_INBOX/$stem.json"

  [ -f "$STATE_DIR/sessions/$SLUG/conv_key" ]
  [ -f "$STATE_DIR/sessions/$SLUG/last_message.json" ]
  [ "$(cat "$STATE_DIR/sessions/$SLUG/conv_key")" = "$JID" ]
  [ "$(jq -r '.direction' "$STATE_DIR/sessions/$SLUG/last_message.json")" = "in" ]
  [ "$(jq -r '.text_preview' "$STATE_DIR/sessions/$SLUG/last_message.json")" = "hello there" ]
  # at is an epoch integer
  [[ "$(jq -r '.at' "$STATE_DIR/sessions/$SLUG/last_message.json")" =~ ^[0-9]+$ ]]
}

@test "text_preview is truncated at 120 chars" {
  stem="20260101-000001_x_BBBB"
  long="$(printf 'a%.0s' {1..200})"
  mk_envelope "$stem" \
    "$(jq -nc --arg j "$JID" --arg t "$long" '{id:"M2",from:$j,text:$t}')" ""
  handle_envelope "$WABOX_INBOX/$stem.json"

  preview="$(jq -r '.text_preview' "$STATE_DIR/sessions/$SLUG/last_message.json")"
  [ "${#preview}" -eq 120 ]
}

@test "image-only message records a [image] preview" {
  stem="20260101-000002_x_CCCC"
  mk_envelope "$stem" \
    "$(jq -nc --arg j "$JID" --arg f "$stem.jpg" \
       '{id:"M3",from:$j,text:"",media:{type:"image",file:$f,mimetype:"image/jpeg"}}')" \
    "$stem.jpg"
  handle_envelope "$WABOX_INBOX/$stem.json"

  [ "$(jq -r '.text_preview' "$STATE_DIR/sessions/$SLUG/last_message.json")" = "[image]" ]
}

@test "audio-only message records a [audio] preview (raw, not the transcript)" {
  cat >"$TMPDIR_TEST/fake_stt.sh" <<'SH'
#!/usr/bin/env bash
printf 'transcribed words'
SH
  chmod +x "$TMPDIR_TEST/fake_stt.sh"
  export WABOX_TRANSCRIBE_CMD="$TMPDIR_TEST/fake_stt.sh"
  stem="20260101-000003_x_DDDD"
  mk_envelope "$stem" \
    "$(jq -nc --arg j "$JID" --arg f "$stem.ogg" \
       '{id:"M4",from:$j,text:"",media:{type:"audio",file:$f,mimetype:"audio/ogg"}}')" \
    "$stem.ogg"
  handle_envelope "$WABOX_INBOX/$stem.json"

  [ "$(jq -r '.text_preview' "$STATE_DIR/sessions/$SLUG/last_message.json")" = "[audio]" ]
}

@test "a slash command still records the mapping and preview" {
  stem="20260101-000004_x_EEEE"
  mk_envelope "$stem" \
    "$(jq -nc --arg j "$JID" '{id:"M5",from:$j,text:"/ping"}')" ""
  handle_envelope "$WABOX_INBOX/$stem.json"

  [ "$(cat "$STATE_DIR/sessions/$SLUG/conv_key")" = "$JID" ]
  [ "$(jq -r '.text_preview' "$STATE_DIR/sessions/$SLUG/last_message.json")" = "/ping" ]
}

@test "leaves no temp files behind" {
  stem="20260101-000005_x_FFFF"
  mk_envelope "$stem" \
    "$(jq -nc --arg j "$JID" '{id:"M6",from:$j,text:"hi"}')" ""
  handle_envelope "$WABOX_INBOX/$stem.json"

  shopt -s nullglob
  leftovers=("$STATE_DIR/sessions/$SLUG"/.*.tmp.*)
  [ "${#leftovers[@]}" -eq 0 ]
}
