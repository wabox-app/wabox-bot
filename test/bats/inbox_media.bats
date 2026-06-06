load test_helper

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

# Helper: write an envelope (+ optional media file) into the inbox.
mk_envelope() {
  local stem="$1" json="$2" media_name="$3"
  printf '%s' "$json" >"$WABOX_INBOX/$stem.json"
  [[ -n "$media_name" ]] && printf 'fake-bytes' >"$WABOX_INBOX/$media_name"
  return 0
}

@test "image-only message: file is staged and a reply is produced (no no-op)" {
  stem="20260101-000000_x_AAAA"
  mk_envelope "$stem" \
    "$(jq -nc --arg j "$JID" --arg f "$stem.jpg" \
       '{id:"M1",from:$j,text:"",media:{type:"image",file:$f,mimetype:"image/jpeg"}}')" \
    "$stem.jpg"
  handle_envelope "$WABOX_INBOX/$stem.json"
  [ -f "$WABOX_OUTBOX/$stem.json" ]
  [ -f "$STATE_DIR/work/$SLUG/wabox-media/$stem.jpg" ]
}

@test "audio message is transcribed via WABOX_TRANSCRIBE_CMD and sent as text" {
  cat >"$TMPDIR_TEST/fake_stt.sh" <<'SH'
#!/usr/bin/env bash
printf 'ola mundo'
SH
  chmod +x "$TMPDIR_TEST/fake_stt.sh"
  export WABOX_TRANSCRIBE_CMD="$TMPDIR_TEST/fake_stt.sh"
  stem="20260101-000001_x_BBBB"
  mk_envelope "$stem" \
    "$(jq -nc --arg j "$JID" --arg f "$stem.ogg" \
       '{id:"M2",from:$j,text:"",media:{type:"audio",file:$f,mimetype:"audio/ogg"}}')" \
    "$stem.ogg"
  handle_envelope "$WABOX_INBOX/$stem.json"
  [ "$(jq -r '.text' "$WABOX_OUTBOX/$stem.json")" = "echo: ola mundo" ]
}

@test "audio message with no transcriber configured is a silent no-op" {
  export WABOX_TRANSCRIBE_CMD=""
  stem="20260101-000002_x_CCCC"
  mk_envelope "$stem" \
    "$(jq -nc --arg j "$JID" --arg f "$stem.ogg" \
       '{id:"M3",from:$j,text:"",media:{type:"audio",file:$f,mimetype:"audio/ogg"}}')" \
    "$stem.ogg"
  handle_envelope "$WABOX_INBOX/$stem.json"
  [ ! -f "$WABOX_OUTBOX/$stem.json" ]
}

@test "plain /ping text still runs the slash command" {
  stem="20260101-000003_x_DDDD"
  mk_envelope "$stem" \
    "$(jq -nc --arg j "$JID" '{id:"M4",from:$j,text:"/ping",media:null}')" ""
  handle_envelope "$WABOX_INBOX/$stem.json"
  [ "$(jq -r '.text' "$WABOX_OUTBOX/$stem.json")" = "pong" ]
}

@test "a /clear caption on an image is treated as a caption, not a command" {
  stem="20260101-000004_x_EEEE"
  mk_envelope "$stem" \
    "$(jq -nc --arg j "$JID" --arg f "$stem.jpg" \
       '{id:"M5",from:$j,text:"/clear",media:{type:"image",file:$f,mimetype:"image/jpeg"}}')" \
    "$stem.jpg"
  handle_envelope "$WABOX_INBOX/$stem.json"
  [ "$(jq -r '.text' "$WABOX_OUTBOX/$stem.json")" = "echo: /clear" ]
}

@test "unsupported media type (video) is a silent no-op" {
  stem="20260101-000005_x_FFFF"
  mk_envelope "$stem" \
    "$(jq -nc --arg j "$JID" --arg f "$stem.mp4" \
       '{id:"M6",from:$j,text:"",media:{type:"video",file:$f,mimetype:"video/mp4"}}')" \
    "$stem.mp4"
  handle_envelope "$WABOX_INBOX/$stem.json"
  [ ! -f "$WABOX_OUTBOX/$stem.json" ]
}
