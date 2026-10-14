load test_helper

# Model precedence in cc_run_turn: a conversation's /model is the user's explicit
# choice; the triage tier's WABOX_TURN_MODEL (lib/triage.sh) only applies when
# there is none.

setup() {
  setup_lib
  export WABOX_BOT_BACKEND=claude-code
  load_core
  SLUG="cafe5678"
  JID="5511@s.whatsapp.net"
  mkdir -p "$SESSIONS_DIR/$SLUG"
  FAKE_BIN="$TMPDIR_TEST/bin"
  mkdir -p "$FAKE_BIN"
  # A fake claude that records its argv and returns a valid envelope.
  cat >"$FAKE_BIN/claude" <<EOF2
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' "\$@" >"$TMPDIR_TEST/argv"
printf '%s' '{"result":"oi","session_id":"s1","permission_denials":[]}'
EOF2
  chmod +x "$FAKE_BIN/claude"
  export CLAUDE_BIN="$FAKE_BIN/claude"
  # shellcheck source=../../lib/backends/claude-code.sh
  source "$LIB_DIR/backends/claude-code.sh"
}

teardown() {
  teardown_lib
}

model_arg() {
  grep -A1 -x -- '--model' "$TMPDIR_TEST/argv" | tail -n1
}

@test "WABOX_TURN_MODEL is passed as --model when no /model is set" {
  WABOX_TURN_MODEL=haiku backend_reply "$SLUG" "$JID" stem <<<"oi" >/dev/null 2>&1
  [ "$(model_arg)" = "haiku" ]
}

@test "a conversation's /model wins over WABOX_TURN_MODEL" {
  cc_save_model_for "$SLUG" opus
  WABOX_TURN_MODEL=haiku backend_reply "$SLUG" "$JID" stem <<<"oi" >/dev/null 2>&1
  [ "$(model_arg)" = "opus" ]
}

@test "no override and no hint passes no --model" {
  backend_reply "$SLUG" "$JID" stem <<<"oi" >/dev/null 2>&1
  ! grep -qx -- '--model' "$TMPDIR_TEST/argv"
}
