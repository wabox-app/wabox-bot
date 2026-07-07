load test_helper

# `wabox-bot send <slug> [text]` — dumb delivery of a message to a conversation
# (no agent turn). Slug path writes an outbox job + a direction:"out"
# last_message; --to targets a raw recipient and writes no last_message.

setup() {
  setup_lib
  export WABOX_BOT_BACKEND=echo
  load_core
  # shellcheck source=lib/send.sh
  source "$LIB_DIR/send.sh"
  SLUG="feed1234"
  JID="5511@s.whatsapp.net"
  mkdir -p "$SESSIONS_DIR/$SLUG"
  printf '%s\n' "$JID" >"$SESSIONS_DIR/$SLUG/conv_key"
}

teardown() { teardown_lib; }

# The single outbox job written by send (there should be exactly one).
send_job() {
  shopt -s nullglob
  local jobs=("$WABOX_OUTBOX"/send-*.json)
  [ "${#jobs[@]}" -eq 1 ] || return 1
  printf '%s' "${jobs[0]}"
}

@test "no slug and no --to exits 1" {
  run send_main
  [ "$status" -eq 1 ]
}

@test "unknown slug exits 1" {
  run send_main "nosuchslug" "hi"
  [ "$status" -eq 1 ]
}

@test "slug happy path writes job + direction:out last_message" {
  run send_main "$SLUG" "olá mundo"
  [ "$status" -eq 0 ]
  job="$(send_job)"
  [ "$(jq -r '.to' "$job")" = "$JID" ]
  [ "$(jq -r '.text' "$job")" = "olá mundo" ]
  # last_message records the outbound turn.
  lm="$SESSIONS_DIR/$SLUG/last_message.json"
  [ -e "$lm" ]
  [ "$(jq -r '.direction' "$lm")" = "out" ]
  [ "$(jq -r '.text_preview' "$lm")" = "olá mundo" ]
}

@test "text via stdin (-) forms the body" {
  run send_main "$SLUG" - <<<"from stdin"
  [ "$status" -eq 0 ]
  job="$(send_job)"
  [ "$(jq -r '.text' "$job")" = "from stdin" ]
}

@test "omitted text reads stdin" {
  run send_main "$SLUG" <<<"piped body"
  [ "$status" -eq 0 ]
  job="$(send_job)"
  [ "$(jq -r '.text' "$job")" = "piped body" ]
}

@test "--to bypasses slug, targets the raw JID, writes no last_message" {
  run send_main --to "5599@s.whatsapp.net" "direct"
  [ "$status" -eq 0 ]
  job="$(send_job)"
  [ "$(jq -r '.to' "$job")" = "5599@s.whatsapp.net" ]
  [ "$(jq -r '.text' "$job")" = "direct" ]
  # No conversation ⇒ no last_message under the pre-seeded slug.
  [ ! -e "$SESSIONS_DIR/$SLUG/last_message.json" ]
}

@test "--to with a slug positional too exits 1" {
  run send_main --to "5599@s.whatsapp.net" "$SLUG" "extra"
  [ "$status" -eq 1 ]
}

@test "--file attaches files as extras (files-only when text empty)" {
  f="$TMPDIR_TEST/report.pdf"
  printf 'pdf' >"$f"
  run send_main "$SLUG" --file "$f" </dev/null
  [ "$status" -eq 0 ]
  job="$(send_job)"
  [ "$(jq -r '.files[0]' "$job")" = "$(readlink -f -- "$f")" ]
  # Files-only delivery: no text field.
  [ "$(jq -r 'has("text")' "$job")" = "false" ]
}

@test "--file plus text sets both the caption and the attachment" {
  f="$TMPDIR_TEST/a.txt"
  printf 'x' >"$f"
  run send_main "$SLUG" "caption" --file "$f"
  [ "$status" -eq 0 ]
  job="$(send_job)"
  [ "$(jq -r '.text' "$job")" = "caption" ]
  [ "$(jq -r '.files | length' "$job")" = "1" ]
}

@test "missing/unreadable --file exits 1" {
  run send_main "$SLUG" "hi" --file "/no/such/file"
  [ "$status" -eq 1 ]
}

@test "empty text and no files exits 1" {
  run send_main "$SLUG" </dev/null
  [ "$status" -eq 1 ]
}
