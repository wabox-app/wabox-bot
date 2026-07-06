load test_helper

# Task 4: `wabox-bot answer <slug> <yes|no>` answers a parked permission from
# the CLI via the backend hook, then delivers the reply to the chat.

# ---- generic plumbing (fake backend hook) ----------------------------------

setup_fake() {
  setup_lib
  export WABOX_BOT_BACKEND=echo
  load_core
  # shellcheck source=lib/answer.sh
  source "$LIB_DIR/answer.sh"
  SLUG="feed1234"
  JID="5511@s.whatsapp.net"
  mkdir -p "$SESSIONS_DIR/$SLUG"
  printf '%s\n' "$JID" >"$SESSIONS_DIR/$SLUG/conv_key"
}

@test "usage error (missing args) exits 1" {
  setup_fake
  run answer_main "$SLUG"
  [ "$status" -eq 1 ]
  teardown_lib
}

@test "invalid decision exits 1" {
  setup_fake
  run answer_main "$SLUG" maybe
  [ "$status" -eq 1 ]
  teardown_lib
}

@test "echo backend without the hook exits 4" {
  setup_fake
  run answer_main "$SLUG" yes
  [ "$status" -eq 4 ]
  teardown_lib
}

@test "unknown slug exits 1" {
  setup_fake
  backend_answer_permission() { printf 'ok'; }
  run answer_main "nosuchslug" yes
  [ "$status" -eq 1 ]
  teardown_lib
}

@test "happy path delivers the hook reply to the chat JID" {
  setup_fake
  backend_answer_permission() {
    # args: slug conv_key decision
    printf 'granted: %s / %s' "$2" "$3"
  }
  run answer_main "$SLUG" yes
  [ "$status" -eq 0 ]
  # An outbox job was written to the chat JID with the hook's reply.
  shopt -s nullglob
  jobs=("$WABOX_OUTBOX"/answer-*.json)
  [ "${#jobs[@]}" -eq 1 ]
  [ "$(jq -r '.to' "${jobs[0]}")" = "$JID" ]
  [ "$(jq -r '.text' "${jobs[0]}")" = "granted: $JID / yes" ]
  teardown_lib
}

@test "GROUP_PER_PARTICIPANT key routes the reply to the chat JID (before the pipe)" {
  setup_fake
  printf '%s\n' "12345@g.us|5511@s.whatsapp.net" >"$SESSIONS_DIR/$SLUG/conv_key"
  backend_answer_permission() { printf 'done'; }
  run answer_main "$SLUG" no
  [ "$status" -eq 0 ]
  shopt -s nullglob
  jobs=("$WABOX_OUTBOX"/answer-*.json)
  [ "$(jq -r '.to' "${jobs[0]}")" = "12345@g.us" ]
  teardown_lib
}

@test "hook exit 2 (nothing pending) propagates as exit 2, no outbox job" {
  setup_fake
  backend_answer_permission() { return 2; }
  run answer_main "$SLUG" yes
  [ "$status" -eq 2 ]
  shopt -s nullglob
  jobs=("$WABOX_OUTBOX"/answer-*.json)
  [ "${#jobs[@]}" -eq 0 ]
  teardown_lib
}

@test "a busy conversation lock exits 3" {
  setup_fake
  backend_answer_permission() { printf 'ok'; }
  # Hold the per-conversation lock from another process.
  ( exec 9>"$LOCKS_DIR/$SLUG.lock"; flock 9; sleep 5 ) &
  holder=$!
  for _ in $(seq 1 50); do [[ -e "$LOCKS_DIR/$SLUG.lock" ]] && break; sleep 0.05; done

  ANSWER_LOCK_WAIT=1 run answer_main "$SLUG" yes
  kill "$holder" 2>/dev/null || true
  [ "$status" -eq 3 ]
  teardown_lib
}

# ---- claude-code hook, with a stubbed cc_run_turn --------------------------

setup_cc() {
  setup_lib
  WABOX_BOT_BACKEND=claude-code load_core
  # shellcheck source=lib/answer.sh
  source "$LIB_DIR/answer.sh"
  SLUG="cc123456"
  JID="5522@s.whatsapp.net"
  mkdir -p "$SESSIONS_DIR/$SLUG"
  printf '%s\n' "$JID" >"$SESSIONS_DIR/$SLUG/conv_key"
  DENIALS='[{"tool_name":"Write","tool_use_id":"t","tool_input":{"file_path":"/tmp/x"}}]'
}

@test "claude-code: no pending ⇒ exit 2" {
  setup_cc
  run answer_main "$SLUG" yes
  [ "$status" -eq 2 ]
  teardown_lib
}

@test "claude-code: 'yes' resumes, clears pending, delivers the reply" {
  setup_cc
  cc_save_pending_permission "$SLUG" "write it" "$DENIALS" "$(date +%s)"
  # Stub the real Claude turn: a clean (no-denial) result.
  cc_run_turn() { printf '%s' '{"result":"file created","permission_denials":[]}'; }

  run answer_main "$SLUG" yes
  [ "$status" -eq 0 ]
  [ ! -e "$(cc_pending_permission_path "$SLUG")" ]
  shopt -s nullglob
  jobs=("$WABOX_OUTBOX"/answer-*.json)
  [ "$(jq -r '.to' "${jobs[0]}")" = "$JID" ]
  [ "$(jq -r '.text' "${jobs[0]}")" = "file created" ]
  teardown_lib
}

@test "claude-code: 'no' cancels and delivers the cancellation" {
  setup_cc
  cc_save_pending_permission "$SLUG" "write it" "$DENIALS" "$(date +%s)"
  run answer_main "$SLUG" no
  [ "$status" -eq 0 ]
  [ ! -e "$(cc_pending_permission_path "$SLUG")" ]
  shopt -s nullglob
  jobs=("$WABOX_OUTBOX"/answer-*.json)
  [[ "$(jq -r '.text' "${jobs[0]}")" == *"cancelado"* ]]
  teardown_lib
}

@test "claude-code: an approval turn that hits a NEW denial re-parks" {
  setup_cc
  cc_save_pending_permission "$SLUG" "do the thing" "$DENIALS" "$(date +%s)"
  bash_denial='[{"tool_name":"Bash","tool_use_id":"y","tool_input":{"command":"rm -rf /tmp/x"}}]'
  export bash_denial
  cc_run_turn() { printf '%s' "{\"result\":\"need a command\",\"permission_denials\":$bash_denial}"; }

  run answer_main "$SLUG" yes
  [ "$status" -eq 0 ]
  # A fresh pending remains, now for Bash.
  [ -e "$(cc_pending_permission_path "$SLUG")" ]
  pending="$(cc_load_pending_permission "$SLUG")"
  [ "$(jq -r '.denials[0].tool_name' <<<"$pending")" = "Bash" ]
  # The re-ask question reached the chat.
  shopt -s nullglob
  jobs=("$WABOX_OUTBOX"/answer-*.json)
  [[ "$(jq -r '.text' "${jobs[0]}")" == *"*Bash*"* ]]
  teardown_lib
}
