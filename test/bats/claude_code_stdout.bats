load test_helper

# `claude`'s stdout is parsed as JSON and nothing checks that it is. A wrapper
# script standing in for the CLI (a version manager, a login-profile echo) that
# prints one line ahead of the envelope breaks every jq at once — and since each
# one swallows its own error, the turn used to surface as an empty reply with a
# clean log. These tests pin the loud failure.

setup() {
  setup_lib
  export WABOX_BOT_BACKEND=claude-code
  load_core
  SLUG="cafe1234"
  JID="5511@s.whatsapp.net"
  mkdir -p "$SESSIONS_DIR/$SLUG"
  printf '%s\n' "$JID" >"$SESSIONS_DIR/$SLUG/conv_key"
  FAKE_BIN="$TMPDIR_TEST/bin"
  mkdir -p "$FAKE_BIN"
}

teardown() {
  teardown_lib
}

# Install a fake `claude` whose stdout is exactly $1, then load the backend over
# the one load_core sourced so it picks up $CLAUDE_BIN.
stub_claude() {
  cat >"$FAKE_BIN/claude" <<EOF
#!/usr/bin/env bash
cat >/dev/null
printf '%s' $(printf '%q' "$1")
EOF
  chmod +x "$FAKE_BIN/claude"
  export CLAUDE_BIN="$FAKE_BIN/claude"
  # shellcheck source=../../lib/backends/claude-code.sh
  source "$LIB_DIR/backends/claude-code.sh"
}

# Note: these capture stdout with a command substitution rather than bats' `run`,
# because `run` folds stderr in and every turn logs a line there.
@test "a clean JSON envelope still yields the reply" {
  stub_claude '{"result":"oi","session_id":"s1","permission_denials":[]}'
  out="$(backend_reply "$SLUG" "$JID" "stem" <<<"olá")"
  [ "$out" = "oi" ]
}

@test "a line printed ahead of the envelope fails the turn instead of emptying it" {
  stub_claude 'mise ~/.config/mise/config.toml tools: claude@2.1.236
{"result":"oi","session_id":"s1","permission_denials":[]}'
  rc=0
  out="$(backend_reply "$SLUG" "$JID" "stem" <<<"olá" 2>/dev/null)" || rc=$?
  # 65 (EX_DATAERR) is "other" in the backend contract, so lib/inbox.sh answers
  # with its error line — never the silent "(no response)" this used to produce.
  [ "$rc" -eq 65 ]
  [ -z "$out" ]
}

@test "the offending output is named in the log, not swallowed" {
  stub_claude 'mise ~/.config/mise/config.toml tools: claude@2.1.236
{"result":"oi","session_id":"s1","permission_denials":[]}'
  backend_reply "$SLUG" "$JID" "stem" <<<"olá" || true
  grep -q "non-JSON on stdout" "$LOG_FILE"
  grep -q "mise ~/.config/mise/config.toml" "$LOG_FILE"
  grep -q "$FAKE_BIN/claude" "$LOG_FILE"
}

@test "stdout that is empty on a zero exit is an error, not a silent no-reply" {
  stub_claude ''
  run backend_reply "$SLUG" "$JID" "stem" <<<"olá"
  [ "$status" -eq 65 ]
}

@test "the session id is not overwritten from unparseable output" {
  mkdir -p "$(backend_state_dir "$SLUG")"
  printf 'keep-me\n' >"$(backend_state_dir "$SLUG")/session"
  stub_claude 'noise
{"result":"oi","session_id":"rotated","permission_denials":[]}'
  run backend_reply "$SLUG" "$JID" "stem" <<<"olá"
  [ "$status" -eq 65 ]
  [ "$(cat "$(backend_state_dir "$SLUG")/session")" = "keep-me" ]
}
