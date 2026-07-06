load test_helper

# Task 3: lib/state.sh emits a versioned snapshot of the daemon + conversations.

setup() {
  setup_lib
  WABOX_BOT_BACKEND=claude-code load_core
  # shellcheck source=lib/state.sh
  source "$LIB_DIR/state.sh"
}

teardown() {
  teardown_lib
}

# Seed a conversation directory the way lib/inbox.sh would.
seed_conv() {
  local slug="$1" conv_key="$2" at="${3:-1751790000}" preview="${4:-hi}"
  mkdir -p "$SESSIONS_DIR/$slug"
  [[ -n "$conv_key" ]] && printf '%s\n' "$conv_key" >"$SESSIONS_DIR/$slug/conv_key"
  jq -nc --argjson at "$at" --arg t "$preview" \
    '{at:$at,direction:"in",text_preview:$t}' \
    >"$SESSIONS_DIR/$slug/last_message.json"
}

@test "top-level schema: version, daemon block, conversations array" {
  run state_json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.version' <<<"$output")" = "1" ]
  [ "$(jq -r '.daemon.backend' <<<"$output")" = "claude-code" ]
  [ "$(jq -r '.daemon.wabox_bot_version' <<<"$output")" = "$(cat "$REPO_ROOT/VERSION")" ]
  [ "$(jq -r '.daemon | has("inbox") and has("outbox") and has("state_dir") and has("log_file")' <<<"$output")" = "true" ]
  [ "$(jq -r '.conversations | type' <<<"$output")" = "array" ]
}

@test "daemon reports stopped when nobody holds the lock" {
  run state_json
  [ "$(jq -r '.daemon.running' <<<"$output")" = "false" ]
  [ "$(jq -r '.daemon.pid' <<<"$output")" = "null" ]
}

@test "daemon reports running + pid while the single-instance lock is held" {
  # Hold the lock in a background subshell with a known PID written in.
  ( exec 9>>"$PID_LOCK"; flock 9; : >"$PID_LOCK"; printf '4242\n' >&9; sleep 5 ) &
  holder=$!
  # Wait until the PID is visible in the lock file.
  for _ in $(seq 1 50); do [[ -s "$PID_LOCK" ]] && break; sleep 0.05; done

  run state_json
  kill "$holder" 2>/dev/null || true

  [ "$(jq -r '.daemon.running' <<<"$output")" = "true" ]
  [ "$(jq -r '.daemon.pid' <<<"$output")" = "4242" ]
}

@test "a seeded conversation surfaces its core fields" {
  slug="aaaa1111"
  seed_conv "$slug" "5511@s.whatsapp.net" 1751790000 "hello"
  run state_json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.conversations[0].slug' <<<"$output")" = "$slug" ]
  [ "$(jq -r '.conversations[0].conv_key' <<<"$output")" = "5511@s.whatsapp.net" ]
  [ "$(jq -r '.conversations[0].workdir_is_default' <<<"$output")" = "true" ]
  [ "$(jq -r '.conversations[0].locked' <<<"$output")" = "false" ]
  [ "$(jq -r '.conversations[0].last_message.text_preview' <<<"$output")" = "hello" ]
  # backend fragment merged in
  [ "$(jq -r '.conversations[0] | has("session_id") and has("overrides") and has("pending_permission")' <<<"$output")" = "true" ]
}

@test "conversations are sorted by last_message.at desc, nulls last" {
  seed_conv "older" "a@s.whatsapp.net" 1000 "old"
  seed_conv "newer" "b@s.whatsapp.net" 2000 "new"
  # A legacy dir with no last_message at all (should sort last).
  mkdir -p "$SESSIONS_DIR/legacy"
  run state_json
  [ "$(jq -r '.conversations[0].slug' <<<"$output")" = "newer" ]
  [ "$(jq -r '.conversations[1].slug' <<<"$output")" = "older" ]
  [ "$(jq -r '.conversations[2].slug' <<<"$output")" = "legacy" ]
}

@test "a legacy slug dir without conv_key yields conv_key: null" {
  mkdir -p "$SESSIONS_DIR/legacy"
  run state_json
  [ "$(jq -r '.conversations[0].slug' <<<"$output")" = "legacy" ]
  [ "$(jq -r '.conversations[0].conv_key' <<<"$output")" = "null" ]
}

@test "an override workdir reports workdir_is_default: false" {
  slug="ovr"
  seed_conv "$slug" "c@s.whatsapp.net"
  printf '%s\n' "/custom/dir" >"$SESSIONS_DIR/$slug/workdir"
  run state_json
  [ "$(jq -r '.conversations[0].workdir' <<<"$output")" = "/custom/dir" ]
  [ "$(jq -r '.conversations[0].workdir_is_default' <<<"$output")" = "false" ]
}

@test "a held per-conversation lock reports locked: true" {
  slug="lockme"
  seed_conv "$slug" "d@s.whatsapp.net"
  ( exec 8>>"$LOCKS_DIR/$slug.lock"; flock 8; sleep 5 ) &
  holder=$!
  for _ in $(seq 1 50); do [[ -e "$LOCKS_DIR/$slug.lock" ]] && break; sleep 0.05; done

  run state_json
  kill "$holder" 2>/dev/null || true
  [ "$(jq -r '.conversations[0].locked' <<<"$output")" = "true" ]
}

# ---- backend fragment (claude-code) ----------------------------------------

@test "a parked permission is reported with tools, question, and expiry" {
  slug="pending1"
  seed_conv "$slug" "e@s.whatsapp.net"
  DENIALS='[{"tool_name":"Write","tool_use_id":"t","tool_input":{"file_path":"/tmp/x"}}]'
  cc_save_pending_permission "$slug" "do it" "$DENIALS" "$(date +%s)"

  run state_json
  [ "$(jq -r '.conversations[0].pending_permission.tools[0]' <<<"$output")" = "Write" ]
  [[ "$(jq -r '.conversations[0].pending_permission.question' <<<"$output")" == *"permissão"* ]]
  # expires_at = asked_at + CC_PERMISSION_TIMEOUT
  asked="$(jq -r '.conversations[0].pending_permission.asked_at' <<<"$output")"
  expires="$(jq -r '.conversations[0].pending_permission.expires_at' <<<"$output")"
  [ "$((expires - asked))" -eq "$CC_PERMISSION_TIMEOUT" ]
}

@test "an expired parked permission reports pending_permission: null" {
  slug="expired1"
  seed_conv "$slug" "f@s.whatsapp.net"
  DENIALS='[{"tool_name":"Write","tool_use_id":"t","tool_input":{"file_path":"/tmp/x"}}]'
  CC_PERMISSION_TIMEOUT=600
  cc_save_pending_permission "$slug" "do it" "$DENIALS" 1
  run state_json
  [ "$(jq -r '.conversations[0].pending_permission' <<<"$output")" = "null" ]
}

@test "overrides surface model/mode/system when set" {
  slug="ovr2"
  seed_conv "$slug" "g@s.whatsapp.net"
  cc_save_model_for "$slug" "opus"
  cc_save_mode_for "$slug" "plan"
  cc_save_system_for "$slug" "be terse"
  run state_json
  [ "$(jq -r '.conversations[0].overrides.model' <<<"$output")" = "opus" ]
  [ "$(jq -r '.conversations[0].overrides.mode' <<<"$output")" = "plan" ]
  [ "$(jq -r '.conversations[0].overrides.system' <<<"$output")" = "be terse" ]
}
