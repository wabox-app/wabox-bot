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
