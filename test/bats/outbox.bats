load test_helper

setup() {
  setup_lib
  # shellcheck source=lib/config.sh
  source "$LIB_DIR/config.sh"
  # shellcheck source=lib/log.sh
  source "$LIB_DIR/log.sh"
  # shellcheck source=lib/outbox.sh
  source "$LIB_DIR/outbox.sh"
}

teardown() {
  teardown_lib
}

@test "write_outbox produces a valid envelope with to/text/replyTo" {
  write_outbox "jid@s.whatsapp.net" "hello" "MSG1" "stem1" >/dev/null
  [ "$(jq -r '.to' "$WABOX_OUTBOX/stem1.json")" = "jid@s.whatsapp.net" ]
  [ "$(jq -r '.text' "$WABOX_OUTBOX/stem1.json")" = "hello" ]
  [ "$(jq -r '.replyTo.id' "$WABOX_OUTBOX/stem1.json")" = "MSG1" ]
}

@test "write_outbox omits replyTo when the id is empty" {
  write_outbox "jid@s.whatsapp.net" "no-reply-to" "" "stem2" >/dev/null
  [ "$(jq -r 'has("replyTo")' "$WABOX_OUTBOX/stem2.json")" = "false" ]
}

@test "write_outbox leaves no dot-tmp leftover" {
  write_outbox "jid@s.whatsapp.net" "hi" "MSG" "stem3" >/dev/null
  [ -f "$WABOX_OUTBOX/stem3.json" ]
  shopt -s nullglob
  tmp_files=("$WABOX_OUTBOX"/.stem3*)
  [ "${#tmp_files[@]}" -eq 0 ]
}

@test "write_outbox round-trips multi-line text" {
  multi=$'line1\nline2\nline3'
  write_outbox "jid@s.whatsapp.net" "$multi" "MSG" "stem4" >/dev/null
  [ "$(jq -r '.text' "$WABOX_OUTBOX/stem4.json")" = "$multi" ]
}

@test "write_outbox returns the final path on stdout" {
  out="$(write_outbox "jid@s.whatsapp.net" "x" "ID" "stem5")"
  [ "$out" = "$WABOX_OUTBOX/stem5.json" ]
}

@test "write_outbox: a 4-arg call is byte-identical with an empty 5th arg" {
  write_outbox "jid@s.whatsapp.net" "hi" "MSG" "a" >/dev/null
  write_outbox "jid@s.whatsapp.net" "hi" "MSG" "b" "" >/dev/null
  [ "$(cat "$WABOX_OUTBOX/a.json")" = "$(cat "$WABOX_OUTBOX/b.json")" ]
}

@test "write_outbox merges a react-only extras job (empty text omitted)" {
  write_outbox "jid@s.whatsapp.net" "" "" "ack" \
    '{"react":{"emoji":"👀","messageId":"M1"}}' >/dev/null
  [ "$(jq -r 'has("text")' "$WABOX_OUTBOX/ack.json")" = "false" ]
  [ "$(jq -r '.react.emoji' "$WABOX_OUTBOX/ack.json")" = "👀" ]
  [ "$(jq -r '.react.messageId' "$WABOX_OUTBOX/ack.json")" = "M1" ]
  [ "$(jq -r '.to' "$WABOX_OUTBOX/ack.json")" = "jid@s.whatsapp.net" ]
}

@test "write_outbox merges files alongside a text caption" {
  write_outbox "jid@s.whatsapp.net" "here you go" "" "f" \
    '{"files":["/tmp/a.pdf","/tmp/b.pdf"]}' >/dev/null
  [ "$(jq -r '.text' "$WABOX_OUTBOX/f.json")" = "here you go" ]
  [ "$(jq -r '.files | length' "$WABOX_OUTBOX/f.json")" = "2" ]
  [ "$(jq -r '.files[0]' "$WABOX_OUTBOX/f.json")" = "/tmp/a.pdf" ]
}

@test "write_outbox: files-only job omits text when the reply is empty" {
  write_outbox "jid@s.whatsapp.net" "" "" "fo" \
    '{"files":["/tmp/a.pdf"]}' >/dev/null
  [ "$(jq -r 'has("text")' "$WABOX_OUTBOX/fo.json")" = "false" ]
  [ "$(jq -r '.files[0]' "$WABOX_OUTBOX/fo.json")" = "/tmp/a.pdf" ]
}

@test "write_outbox: extras.replyTo (with participant) wins over the rid arg" {
  write_outbox "grp@g.us" "reply" "IGNORED" "q" \
    '{"replyTo":{"id":"M9","participant":"5511@s.whatsapp.net"}}' >/dev/null
  [ "$(jq -r '.replyTo.id' "$WABOX_OUTBOX/q.json")" = "M9" ]
  [ "$(jq -r '.replyTo.participant' "$WABOX_OUTBOX/q.json")" = "5511@s.whatsapp.net" ]
}

@test "write_outbox ignores invalid extras rather than failing delivery" {
  run write_outbox "jid@s.whatsapp.net" "still delivered" "" "bad" 'not-json'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.text' "$WABOX_OUTBOX/bad.json")" = "still delivered" ]
  [ "$(jq -r 'has("react")' "$WABOX_OUTBOX/bad.json")" = "false" ]
}

@test "write_outbox ignores a non-object extras (a JSON array)" {
  write_outbox "jid@s.whatsapp.net" "ok" "" "arr" '[1,2,3]' >/dev/null
  [ "$(jq -r '.text' "$WABOX_OUTBOX/arr.json")" = "ok" ]
}
