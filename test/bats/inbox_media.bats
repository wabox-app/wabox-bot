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
  [ -f "$STATE_DIR/work/$SLUG/.wabox/media/$stem.jpg" ]
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

@test "bare unsupported media (video, no caption) is a silent no-op" {
  stem="20260101-000005_x_FFFF"
  mk_envelope "$stem" \
    "$(jq -nc --arg j "$JID" --arg f "$stem.mp4" \
       '{id:"M6",from:$j,text:"",media:{type:"video",file:$f,mimetype:"video/mp4"}}')" \
    "$stem.mp4"
  handle_envelope "$WABOX_INBOX/$stem.json"
  [ ! -f "$WABOX_OUTBOX/$stem.json" ]
  # Never staged — the bytes are useless to the agent.
  [ ! -e "$STATE_DIR/work/$SLUG/.wabox/media/$stem.mp4" ]
}

@test "document-only message is staged and reaches the backend" {
  stem="20260101-000010_x_JJJJ"
  mk_envelope "$stem" \
    "$(jq -nc --arg j "$JID" --arg f "$stem.pdf" \
       '{id:"M10",from:$j,text:"",media:{type:"document",file:$f,mimetype:"application/pdf"}}')" \
    "$stem.pdf"
  handle_envelope "$WABOX_INBOX/$stem.json"
  [ -f "$WABOX_OUTBOX/$stem.json" ]
  [ -f "$STATE_DIR/work/$SLUG/.wabox/media/$stem.pdf" ]
}

@test "document with a caption forwards the caption text" {
  stem="20260101-000011_x_KKKK"
  mk_envelope "$stem" \
    "$(jq -nc --arg j "$JID" --arg f "$stem.pdf" \
       '{id:"M11",from:$j,text:"resume isso",media:{type:"document",file:$f,mimetype:"application/pdf"}}')" \
    "$stem.pdf"
  handle_envelope "$WABOX_INBOX/$stem.json"
  # echo backend ignores media and echoes the caption text through.
  [ "$(jq -r '.text' "$WABOX_OUTBOX/$stem.json")" = "echo: resume isso" ]
  [ -f "$STATE_DIR/work/$SLUG/.wabox/media/$stem.pdf" ]
}

@test "oversize document (no caption): notice sent, nothing staged, no turn" {
  export WABOX_DOC_MAX_MB=0   # any non-empty file trips the guard
  stem="20260101-000012_x_LLLL"
  mk_envelope "$stem" \
    "$(jq -nc --arg j "$JID" --arg f "$stem.pdf" \
       '{id:"M12",from:$j,text:"",media:{type:"document",file:$f,mimetype:"application/pdf"}}')" \
    "$stem.pdf"
  handle_envelope "$WABOX_INBOX/$stem.json"
  # The notice lands under a distinct stem; no agent turn ran (no $stem.json).
  [ -f "$WABOX_OUTBOX/${stem}-toobig.json" ]
  [[ "$(jq -r '.text' "$WABOX_OUTBOX/${stem}-toobig.json")" == *"muito grande"* ]]
  [ ! -f "$WABOX_OUTBOX/$stem.json" ]
  [ ! -e "$STATE_DIR/work/$SLUG/.wabox/media/$stem.pdf" ]
}

@test "oversize document with a caption still runs a text turn (notice + reply)" {
  export WABOX_DOC_MAX_MB=0
  stem="20260101-000013_x_MMMM"
  mk_envelope "$stem" \
    "$(jq -nc --arg j "$JID" --arg f "$stem.pdf" \
       '{id:"M13",from:$j,text:"da uma olhada",media:{type:"document",file:$f,mimetype:"application/pdf"}}')" \
    "$stem.pdf"
  handle_envelope "$WABOX_INBOX/$stem.json"
  # Both jobs exist — the notice (distinct stem) is not clobbered by the reply.
  [[ "$(jq -r '.text' "$WABOX_OUTBOX/${stem}-toobig.json")" == *"muito grande"* ]]
  [ "$(jq -r '.text' "$WABOX_OUTBOX/$stem.json")" = "echo: da uma olhada" ]
  [ ! -e "$STATE_DIR/work/$SLUG/.wabox/media/$stem.pdf" ]
}

@test "video with a caption is forwarded as text with a bracketed note" {
  stem="20260101-000014_x_NNNN"
  mk_envelope "$stem" \
    "$(jq -nc --arg j "$JID" --arg f "$stem.mp4" \
       '{id:"M14",from:$j,text:"olha isso",media:{type:"video",file:$f,mimetype:"video/mp4"}}')" \
    "$stem.mp4"
  handle_envelope "$WABOX_INBOX/$stem.json"
  text="$(jq -r '.text' "$WABOX_OUTBOX/$stem.json")"
  [[ "$text" == *"vídeo"* ]]
  [[ "$text" == *"olha isso"* ]]
  # The video itself is never staged.
  [ ! -e "$STATE_DIR/work/$SLUG/.wabox/media/$stem.mp4" ]
}

@test "a future unknown media type with a caption is forwarded with a generic note" {
  stem="20260101-000015_x_OOOO"
  mk_envelope "$stem" \
    "$(jq -nc --arg j "$JID" --arg f "$stem.bin" \
       '{id:"M15",from:$j,text:"veja",media:{type:"contact",file:$f,mimetype:"text/x-vcard"}}')" \
    "$stem.bin"
  handle_envelope "$WABOX_INBOX/$stem.json"
  text="$(jq -r '.text' "$WABOX_OUTBOX/$stem.json")"
  [[ "$text" == *"não consigo processar"* ]]
  [[ "$text" == *"veja"* ]]
}

@test "transcription failure sends the error reply to the outbox" {
  cat >"$TMPDIR_TEST/failing_stt.sh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$TMPDIR_TEST/failing_stt.sh"
  export WABOX_TRANSCRIBE_CMD="$TMPDIR_TEST/failing_stt.sh"
  stem="20260101-000006_x_GGGG"
  mk_envelope "$stem" \
    "$(jq -nc --arg j "$JID" --arg f "$stem.ogg" \
       '{id:"M7",from:$j,text:"",media:{type:"audio",file:$f,mimetype:"audio/ogg"}}')" \
    "$stem.ogg"
  handle_envelope "$WABOX_INBOX/$stem.json"
  [ -f "$WABOX_OUTBOX/$stem.json" ]
  [[ "$(jq -r '.text' "$WABOX_OUTBOX/$stem.json")" == *"transcrever"* ]]
}

@test "whitespace-only transcript triggers the error reply, not an empty turn" {
  cat >"$TMPDIR_TEST/blank_stt.sh" <<'SH'
#!/usr/bin/env bash
printf '   '
SH
  chmod +x "$TMPDIR_TEST/blank_stt.sh"
  export WABOX_TRANSCRIBE_CMD="$TMPDIR_TEST/blank_stt.sh"
  stem="20260101-000007_x_HHHH"
  mk_envelope "$stem" \
    "$(jq -nc --arg j "$JID" --arg f "$stem.ogg" \
       '{id:"M8",from:$j,text:"",media:{type:"audio",file:$f,mimetype:"audio/ogg"}}')" \
    "$stem.ogg"
  handle_envelope "$WABOX_INBOX/$stem.json"
  [[ "$(jq -r '.text' "$WABOX_OUTBOX/$stem.json")" == *"transcrever"* ]]
}

@test "audio with a caption prepends the caption to the transcript" {
  cat >"$TMPDIR_TEST/fake_stt.sh" <<'SH'
#!/usr/bin/env bash
printf 'ola mundo'
SH
  chmod +x "$TMPDIR_TEST/fake_stt.sh"
  export WABOX_TRANSCRIBE_CMD="$TMPDIR_TEST/fake_stt.sh"
  stem="20260101-000008_x_IIII"
  mk_envelope "$stem" \
    "$(jq -nc --arg j "$JID" --arg f "$stem.ogg" \
       '{id:"M9",from:$j,text:"listen to this",media:{type:"audio",file:$f,mimetype:"audio/ogg"}}')" \
    "$stem.ogg"
  handle_envelope "$WABOX_INBOX/$stem.json"
  expected="echo: listen to this"$'\n\n'"ola mundo"
  [ "$(jq -r '.text' "$WABOX_OUTBOX/$stem.json")" = "$expected" ]
}
