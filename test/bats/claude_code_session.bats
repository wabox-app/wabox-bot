load test_helper

setup() {
  setup_lib
  WABOX_BOT_BACKEND=claude-code load_core
  SLUG="deadbeef"
}

teardown() {
  teardown_lib
}

@test "cc_save_session_id persists the session id and the working dir it was created in" {
  cc_save_session_id "$SLUG" "sid-123" "/work/dir"
  d="$(backend_state_dir "$SLUG")"
  [ "$(cat "$d/session")" = "sid-123" ]
  [ "$(cat "$d/session.cwd")" = "/work/dir" ]
}

@test "cc_resumable_session returns the sid when the current workdir matches" {
  cc_save_session_id "$SLUG" "sid-123" "/work/dir"
  run cc_resumable_session "$SLUG" "/work/dir"
  [ "$status" -eq 0 ]
  [ "$output" = "sid-123" ]
}

@test "cc_resumable_session refuses to resume from a different workdir" {
  # This is the reported bug: a session created under one cwd cannot be
  # resumed from another — Claude scopes sessions to the working directory.
  cc_save_session_id "$SLUG" "sid-123" "/work/dir"
  run cc_resumable_session "$SLUG" "/some/other/dir"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "cc_resumable_session refuses a legacy session with no recorded cwd" {
  printf '%s\n' "sid-legacy" >"$(backend_state_dir "$SLUG")/session"
  run cc_resumable_session "$SLUG" "/work/dir"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "cc_resumable_session returns nothing when there is no session" {
  run cc_resumable_session "$SLUG" "/work/dir"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "backend_clear removes both the session id and its recorded cwd" {
  cc_save_session_id "$SLUG" "sid-123" "/work/dir"
  d="$(backend_state_dir "$SLUG")"
  backend_clear "$SLUG"
  [ ! -e "$d/session" ]
  [ ! -e "$d/session.cwd" ]
}
