load test_helper

setup() {
  setup_lib
  WABOX_BOT_BACKEND=claude-code load_core
  mkdir -p "$SESSIONS_DIR"
}

teardown() {
  teardown_lib
}

@test "migrate moves flat session/model/mode/system into <slug>/claude-code/" {
  echo "session-id" >"$SESSIONS_DIR/abc.session"
  echo "sonnet"     >"$SESSIONS_DIR/abc.model"
  echo "plan"       >"$SESSIONS_DIR/abc.mode"
  printf 'Be terse.' >"$SESSIONS_DIR/abc.system"

  run_migrations

  [ ! -f "$SESSIONS_DIR/abc.session" ]
  [ ! -f "$SESSIONS_DIR/abc.model" ]
  [ -f "$SESSIONS_DIR/abc/claude-code/session" ]
  [ -f "$SESSIONS_DIR/abc/claude-code/model" ]
  [ -f "$SESSIONS_DIR/abc/claude-code/mode" ]
  [ -f "$SESSIONS_DIR/abc/claude-code/system" ]
  [ "$(cat "$SESSIONS_DIR/abc/claude-code/session")" = "session-id" ]
}

@test "migrate is idempotent" {
  echo "sess" >"$SESSIONS_DIR/abc.session"
  run_migrations
  run run_migrations  # second pass should find nothing to do
  [ "$status" -eq 0 ]
  [ "$(cat "$SESSIONS_DIR/abc/claude-code/session")" = "sess" ]
}

@test "migrate removes a stale agent.lock left behind by the old daemon name" {
  touch "$STATE_DIR/agent.lock"
  run_migrations
  [ ! -e "$STATE_DIR/agent.lock" ]
}

@test "migrate skips flat-session move when active backend isn't claude-code" {
  # Re-source backend.sh with WABOX_BOT_BACKEND=echo so backend_name now
  # returns "echo". migrate_flat_sessions early-returns when backend_name
  # isn't claude-code.
  echo "sess" >"$SESSIONS_DIR/abc.session"
  # shellcheck disable=SC1090,SC1091
  WABOX_BOT_BACKEND=echo source "$LIB_DIR/backend.sh"

  run_migrations

  # Flat file should remain in place — the next run with claude-code picks it up.
  [ -f "$SESSIONS_DIR/abc.session" ]
  [ ! -e "$SESSIONS_DIR/abc/claude-code/session" ]
}
