load test_helper

# Rich replies wired through the per-envelope handler: ack reactions, outgoing
# file attachments, and quote-reply policy. Uses the echo backend and overrides
# backend_reply per-test where a turn needs to drop a file.

setup() {
  setup_lib
  export WABOX_BOT_BACKEND=echo
  load_core
  # shellcheck source=lib/inbox.sh
  source "$LIB_DIR/inbox.sh"
  DM="5511999999999@s.whatsapp.net"
  DM_SLUG="$(printf '%s' "$DM" | sha1sum | awk '{print $1}')"
  GRP="1203630@g.us"
  PART="5511888888888@s.whatsapp.net"
}

teardown() {
  teardown_lib
}

# Write a text envelope into the inbox.
mk_text() {
  local stem="$1" jid="$2" id="$3" text="$4" participant="$5"
  jq -nc --arg j "$jid" --arg id "$id" --arg t "$text" --arg p "$participant" \
    '{id:$id, from:$j, text:$t}
     + (if $p == "" then {} else {participant:$p} end)' \
    >"$WABOX_INBOX/$stem.json"
}

# ---- ack reactions --------------------------------------------------------

@test "ack reaction: an agent turn queues a react-only job when WABOX_ACK_REACT is set" {
  export WABOX_ACK_REACT="👀"
  mk_text "s1" "$DM" "M1" "hello" ""
  handle_envelope "$WABOX_INBOX/s1.json"
  [ -f "$WABOX_OUTBOX/s1-ack.json" ]
  [ "$(jq -r '.react.emoji' "$WABOX_OUTBOX/s1-ack.json")" = "👀" ]
  [ "$(jq -r '.react.messageId' "$WABOX_OUTBOX/s1-ack.json")" = "M1" ]
  [ "$(jq -r 'has("text")' "$WABOX_OUTBOX/s1-ack.json")" = "false" ]
  [ "$(jq -r 'has("participant")' "$WABOX_OUTBOX/s1-ack.json")" = "false" ]
  # The reply itself is still delivered.
  [ -f "$WABOX_OUTBOX/s1.json" ]
}

@test "ack reaction: default (unset WABOX_ACK_REACT) queues no ack job" {
  mk_text "s2" "$DM" "M2" "hello" ""
  handle_envelope "$WABOX_INBOX/s2.json"
  [ ! -e "$WABOX_OUTBOX/s2-ack.json" ]
  [ -f "$WABOX_OUTBOX/s2.json" ]
}

@test "ack reaction: a group ack carries participant" {
  export WABOX_ACK_REACT="👀"
  mk_text "s3" "$GRP" "M3" "hello" "$PART"
  handle_envelope "$WABOX_INBOX/s3.json"
  [ "$(jq -r '.react.participant' "$WABOX_OUTBOX/s3-ack.json")" = "$PART" ]
}

@test "ack reaction: a slash command does not trigger an ack" {
  export WABOX_ACK_REACT="👀"
  mk_text "s4" "$DM" "M4" "/ping" ""
  handle_envelope "$WABOX_INBOX/s4.json"
  [ ! -e "$WABOX_OUTBOX/s4-ack.json" ]
}

# ---- outgoing files -------------------------------------------------------

@test "files: a file the backend drops in wabox-send/ is attached as an absolute path, caption = reply" {
  backend_reply() {
    local slug="$1" wd
    wd="$(conversation_workdir "$slug")"
    printf 'PDF' >"$wd/wabox-send/report.pdf"
    printf 'here is your report'
  }
  mk_text "f1" "$DM" "M5" "make a report" ""
  handle_envelope "$WABOX_INBOX/f1.json"
  [ "$(jq -r '.text' "$WABOX_OUTBOX/f1.json")" = "here is your report" ]
  [ "$(jq -r '.files | length' "$WABOX_OUTBOX/f1.json")" = "1" ]
  [ "$(jq -r '.files[0]' "$WABOX_OUTBOX/f1.json")" = "$STATE_DIR/work/$DM_SLUG/wabox-send/report.pdf" ]
}

@test "files: an empty reply with files present becomes a files-only job" {
  backend_reply() {
    local slug="$1" wd
    wd="$(conversation_workdir "$slug")"
    printf 'PNG' >"$wd/wabox-send/chart.png"
    printf ''
  }
  mk_text "f2" "$DM" "M6" "chart it" ""
  handle_envelope "$WABOX_INBOX/f2.json"
  [ "$(jq -r 'has("text")' "$WABOX_OUTBOX/f2.json")" = "false" ]
  [ "$(jq -r '.files[0]' "$WABOX_OUTBOX/f2.json")" = "$STATE_DIR/work/$DM_SLUG/wabox-send/chart.png" ]
}

@test "files: an errored turn attaches nothing and keeps its partial output" {
  backend_reply() {
    local slug="$1" wd
    wd="$(conversation_workdir "$slug")"
    printf 'partial' >"$wd/wabox-send/partial.pdf"
    return 1
  }
  mk_text "f3" "$DM" "M7" "boom" ""
  handle_envelope "$WABOX_INBOX/f3.json"
  [ "$(jq -r 'has("files")' "$WABOX_OUTBOX/f3.json")" = "false" ]
  # partial output stays in the folder for archival on the next turn
  [ -f "$STATE_DIR/work/$DM_SLUG/wabox-send/partial.pdf" ]
}

@test "files: a leftover from a prior turn is archived, not re-attached" {
  local send="$STATE_DIR/work/$DM_SLUG/wabox-send"
  mkdir -p "$send"
  printf 'stale' >"$send/stale.pdf"
  backend_reply() { printf 'clean turn'; }
  mk_text "f4" "$DM" "M8" "hi again" ""
  handle_envelope "$WABOX_INBOX/f4.json"
  [ "$(jq -r 'has("files")' "$WABOX_OUTBOX/f4.json")" = "false" ]
  [ ! -e "$send/stale.pdf" ]
  [ -f "$send/.sent/f4/stale.pdf" ]
}

# ---- quote-reply policy ---------------------------------------------------

@test "quote auto: a group reply quotes the message with participant" {
  mk_text "q1" "$GRP" "M9" "in a group" "$PART"
  handle_envelope "$WABOX_INBOX/q1.json"
  [ "$(jq -r '.replyTo.id' "$WABOX_OUTBOX/q1.json")" = "M9" ]
  [ "$(jq -r '.replyTo.participant' "$WABOX_OUTBOX/q1.json")" = "$PART" ]
}

@test "quote auto: a DM with a queued backlog quotes; without backlog it does not" {
  # Stage a *second* envelope for the same DM still sitting in the inbox.
  mk_text "q2" "$DM" "M10" "first" ""
  mk_text "q2b" "$DM" "M11" "second (backlog)" ""
  handle_envelope "$WABOX_INBOX/q2.json"
  [ "$(jq -r '.replyTo.id' "$WABOX_OUTBOX/q2.json")" = "M10" ]
}

@test "quote auto: a DM with no backlog does not quote" {
  mk_text "q3" "$DM" "M12" "lonely" ""
  handle_envelope "$WABOX_INBOX/q3.json"
  [ "$(jq -r 'has("replyTo")' "$WABOX_OUTBOX/q3.json")" = "false" ]
}

@test "quote always: a DM with no backlog still quotes" {
  export WABOX_QUOTE_REPLY=always
  mk_text "q4" "$DM" "M13" "quote me" ""
  handle_envelope "$WABOX_INBOX/q4.json"
  [ "$(jq -r '.replyTo.id' "$WABOX_OUTBOX/q4.json")" = "M13" ]
}

@test "quote never: a group reply is not quoted" {
  export WABOX_QUOTE_REPLY=never
  mk_text "q5" "$GRP" "M14" "no quote" "$PART"
  handle_envelope "$WABOX_INBOX/q5.json"
  [ "$(jq -r 'has("replyTo")' "$WABOX_OUTBOX/q5.json")" = "false" ]
}
