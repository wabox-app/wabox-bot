load test_helper

# lib/lastmsg.sh — the shared last_message.json writer used by the inbound
# handler and the send/prompt verbs. Atomic (temp + rename) so concurrent
# writers never leave a partial file.

setup() {
  setup_lib
  export WABOX_BOT_BACKEND=echo
  load_core
  SLUG="feed1234"
  mkdir -p "$SESSIONS_DIR/$SLUG"
}

teardown() { teardown_lib; }

lm() { printf '%s' "$SESSIONS_DIR/$SLUG/last_message.json"; }

@test "writes an inbound record" {
  lastmsg_write "$SLUG" in "hi there"
  [ "$(jq -r '.direction' "$(lm)")" = "in" ]
  [ "$(jq -r '.text_preview' "$(lm)")" = "hi there" ]
  [ "$(jq -r '.at | type' "$(lm)")" = "number" ]
}

@test "writes an outbound record" {
  lastmsg_write "$SLUG" out "reply text"
  [ "$(jq -r '.direction' "$(lm)")" = "out" ]
  [ "$(jq -r '.text_preview' "$(lm)")" = "reply text" ]
}

@test "truncates the preview to 120 chars" {
  long="$(printf 'x%.0s' {1..200})"
  lastmsg_write "$SLUG" in "$long"
  preview="$(jq -r '.text_preview' "$(lm)")"
  [ "${#preview}" -eq 120 ]
}

@test "a media placeholder passes through as text" {
  lastmsg_write "$SLUG" in "[audio]"
  [ "$(jq -r '.text_preview' "$(lm)")" = "[audio]" ]
}

@test "concurrent writers never leave partial JSON, no temp leftovers" {
  for i in $(seq 1 40); do
    lastmsg_write "$SLUG" out "message number $i" &
  done
  wait
  # The final file is always complete, parseable JSON.
  jq -e . "$(lm)" >/dev/null
  # No temp files left behind under the slug dir.
  run bash -c "ls -A '$SESSIONS_DIR/$SLUG'/.last_message.tmp.* 2>/dev/null"
  [ -z "$output" ]
}
