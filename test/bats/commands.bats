load test_helper

setup() {
  setup_lib
  WABOX_BOT_BACKEND=claude-code load_core
  JID="5511999999999@s.whatsapp.net"
  SLUG="$(printf '%s' "$JID" | sha1sum | awk '{print $1}')"
}

teardown() {
  teardown_lib
}

@test "/ping replies pong" {
  handle_slash_command "/ping" "$SLUG" "$JID" "$JID" "MSG1" "stem1"
  [ "$(jq -r '.text' "$WABOX_OUTBOX/stem1.json")" = "pong" ]
}

@test "/help aggregates core and backend lines" {
  handle_slash_command "/help" "$SLUG" "$JID" "$JID" "MSG" "help"
  text="$(jq -r '.text' "$WABOX_OUTBOX/help.json")"
  [[ "$text" == *"/clear"* ]]
  [[ "$text" == *"/ping"* ]]
  [[ "$text" == *"/status"* ]]
  [[ "$text" == *"/model"* ]]
  [[ "$text" == *"/mode"* ]]
  [[ "$text" == *"/system"* ]]
}

@test "/status reports the active backend and no session by default" {
  handle_slash_command "/status" "$SLUG" "$JID" "$JID" "MSG" "status"
  text="$(jq -r '.text' "$WABOX_OUTBOX/status.json")"
  [[ "$text" == *"backend: claude-code"* ]]
  [[ "$text" == *"session: (none"* ]]
}

@test "/clear delegates to backend_clear and drops the session file" {
  d="$(backend_state_dir "$SLUG")"
  echo "some-uuid" >"$d/session"
  handle_slash_command "/clear" "$SLUG" "$JID" "$JID" "MSG" "clear"
  [ ! -f "$d/session" ]
}

@test "/clear preserves the model preference" {
  d="$(backend_state_dir "$SLUG")"
  echo "haiku" >"$d/model"
  handle_slash_command "/clear" "$SLUG" "$JID" "$JID" "MSG" "clear"
  [ "$(cat "$d/model")" = "haiku" ]
}

@test "unknown command returns the canonical reply" {
  handle_slash_command "/nope" "$SLUG" "$JID" "$JID" "MSG" "stem"
  [ "$(jq -r '.text' "$WABOX_OUTBOX/stem.json")" = "Unknown command: /nope. Try /help." ]
}

@test "non-slash input returns 1 (caller should hand off to backend)" {
  run handle_slash_command "hello world" "$SLUG" "$JID" "$JID" "MSG" "stem"
  [ "$status" -eq 1 ]
}

@test "/model haiku persists the override into backend state dir" {
  handle_slash_command "/model haiku" "$SLUG" "$JID" "$JID" "MSG" "stem"
  [ "$(cat "$(backend_state_dir "$SLUG")/model")" = "haiku" ]
}

@test "/model default removes the override" {
  d="$(backend_state_dir "$SLUG")"
  echo "haiku" >"$d/model"
  handle_slash_command "/model default" "$SLUG" "$JID" "$JID" "MSG" "stem"
  [ ! -e "$d/model" ]
}

@test "/system <multi-line text> stores the prompt verbatim" {
  handle_slash_command "/system Be terse.
Always reply in one paragraph." "$SLUG" "$JID" "$JID" "MSG" "stem"
  d="$(backend_state_dir "$SLUG")"
  stored="$(cat "$d/system")"
  [[ "$stored" == "Be terse."* ]]
  [[ "$stored" == *"Always reply in one paragraph."* ]]
}

@test "/foo without backend match falls through to unknown" {
  handle_slash_command "/foo" "$SLUG" "$JID" "$JID" "MSG" "stem"
  [ "$(jq -r '.text' "$WABOX_OUTBOX/stem.json")" = "Unknown command: /foo. Try /help." ]
}
