load test_helper

# `wabox-bot cmd <slug> "<slash command>"` runs a conversation's slash command
# from the CLI via the same handle_slash_command path, capturing the reply on
# stdout instead of delivering it to the outbox.

setup() {
  setup_lib
  export WABOX_BOT_BACKEND=claude-code
  load_core
  # shellcheck source=lib/cmd.sh
  source "$LIB_DIR/cmd.sh"
  SLUG="feed1234"
  JID="5511@s.whatsapp.net"
  mkdir -p "$SESSIONS_DIR/$SLUG"
  printf '%s\n' "$JID" >"$SESSIONS_DIR/$SLUG/conv_key"
}

teardown() { teardown_lib; }

# The outbox must stay empty — cmd captures, it does not message the user.
assert_outbox_empty() {
  run bash -c "ls -A '$WABOX_OUTBOX'"
  [ -z "$output" ]
}

@test "missing args exits 1" {
  run cmd_main "$SLUG"
  [ "$status" -eq 1 ]
}

@test "unknown slug exits 1" {
  run cmd_main "nosuchslug" "/status"
  [ "$status" -eq 1 ]
}

@test "input that isn't a slash command exits 1" {
  run cmd_main "$SLUG" "just some text"
  [ "$status" -eq 1 ]
}

@test "/status prints the captured reply on stdout, nothing to outbox" {
  run cmd_main "$SLUG" "/status"
  [ "$status" -eq 0 ]
  [[ "$output" == *"conv:    $JID"* ]]
  [[ "$output" == *"backend: claude-code"* ]]
  assert_outbox_empty
}

@test "/cwd <dir> persists the working folder and reports it" {
  local target="$TMPDIR_TEST/work-here"
  mkdir -p "$target"
  run cmd_main "$SLUG" "/cwd $target"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$target"* ]]
  [ "$(cat "$SESSIONS_DIR/$SLUG/workdir")" = "$target" ]
  assert_outbox_empty
}

@test "/cwd default clears the override" {
  printf '%s\n' "$TMPDIR_TEST" >"$SESSIONS_DIR/$SLUG/workdir"
  run cmd_main "$SLUG" "/cwd default"
  [ "$status" -eq 0 ]
  [ ! -e "$SESSIONS_DIR/$SLUG/workdir" ]
}

@test "/model <name> persists a per-conversation model override" {
  run cmd_main "$SLUG" "/model opus"
  [ "$status" -eq 0 ]
  [[ "$output" == *"opus"* ]]
  [ "$(cat "$SESSIONS_DIR/$SLUG/claude-code/model")" = "opus" ]
  assert_outbox_empty
}

@test "/model rejects an unsafe name without persisting it" {
  run cmd_main "$SLUG" "/model bad;rm -rf"
  [ "$status" -eq 0 ]              # handled (a rejection notice was produced)
  [[ "$output" == *"Invalid model"* ]]
  [ ! -e "$SESSIONS_DIR/$SLUG/claude-code/model" ]
}

@test "/clear drops the session and reports it" {
  mkdir -p "$SESSIONS_DIR/$SLUG/claude-code"
  printf 'sess-1\n' >"$SESSIONS_DIR/$SLUG/claude-code/session"
  run cmd_main "$SLUG" "/clear"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cleared"* ]]
  [ ! -e "$SESSIONS_DIR/$SLUG/claude-code/session" ]
  assert_outbox_empty
}

@test "unknown slash command reports it but still exits 0" {
  run cmd_main "$SLUG" "/nope"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Unknown command"* ]]
}
