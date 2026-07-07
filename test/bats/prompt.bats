load test_helper

# `wabox-bot prompt <slug> <text>` — run an agent turn for a conversation and
# deliver the reply, suppressing empty/NOOP replies (exit 5). Takes the
# per-conversation flock (busy ⇒ 3) and propagates a backend timeout (124).

# ---- echo-backend plumbing (generic backend_reply behaviour) ---------------

setup_echo() {
  setup_lib
  export WABOX_BOT_BACKEND=echo
  load_core
  # shellcheck source=lib/prompt.sh
  source "$LIB_DIR/prompt.sh"
  SLUG="feed1234"
  JID="5511@s.whatsapp.net"
  mkdir -p "$SESSIONS_DIR/$SLUG"
  printf '%s\n' "$JID" >"$SESSIONS_DIR/$SLUG/conv_key"
}

prompt_job() {
  shopt -s nullglob
  local jobs=("$WABOX_OUTBOX"/prompt-*.json)
  [ "${#jobs[@]}" -eq 1 ] || return 1
  printf '%s' "${jobs[0]}"
}

assert_outbox_empty() {
  run bash -c "ls -A '$WABOX_OUTBOX'"
  [ -z "$output" ]
}

@test "missing text exits 1" {
  setup_echo
  run prompt_main "$SLUG"
  [ "$status" -eq 1 ]
  teardown_lib
}

@test "unknown slug exits 1" {
  setup_echo
  run prompt_main "nosuchslug" "hi"
  [ "$status" -eq 1 ]
  teardown_lib
}

@test "happy path delivers the reply + direction:out last_message" {
  setup_echo
  run prompt_main "$SLUG" "hello"
  [ "$status" -eq 0 ]
  job="$(prompt_job)"
  [ "$(jq -r '.to' "$job")" = "$JID" ]
  [ "$(jq -r '.text' "$job")" = "echo: hello" ]
  lm="$SESSIONS_DIR/$SLUG/last_message.json"
  [ "$(jq -r '.direction' "$lm")" = "out" ]
  [ "$(jq -r '.text_preview' "$lm")" = "echo: hello" ]
  teardown_lib
}

@test "text via stdin (-)" {
  setup_echo
  run prompt_main "$SLUG" - <<<"piped"
  [ "$status" -eq 0 ]
  job="$(prompt_job)"
  [ "$(jq -r '.text' "$job")" = "echo: piped" ]
  teardown_lib
}

@test "NOOP reply ⇒ exit 5, nothing delivered" {
  setup_echo
  backend_reply() { printf 'NOOP'; }
  run prompt_main "$SLUG" "anything"
  [ "$status" -eq 5 ]
  assert_outbox_empty
  # No last_message written for a suppressed turn.
  [ ! -e "$SESSIONS_DIR/$SLUG/last_message.json" ]
  teardown_lib
}

@test "custom WABOX_PROMPT_NOOP sentinel suppresses" {
  setup_echo
  backend_reply() { printf '  skip-me  '; }
  WABOX_PROMPT_NOOP="skip-me" run prompt_main "$SLUG" "x"
  [ "$status" -eq 5 ]
  assert_outbox_empty
  teardown_lib
}

@test "empty reply ⇒ exit 5, nothing delivered" {
  setup_echo
  backend_reply() { printf ''; }
  run prompt_main "$SLUG" "x"
  [ "$status" -eq 5 ]
  assert_outbox_empty
  teardown_lib
}

@test "backend timeout propagates as 124, nothing delivered" {
  setup_echo
  backend_reply() { return 124; }
  run prompt_main "$SLUG" "x"
  [ "$status" -eq 124 ]
  assert_outbox_empty
  teardown_lib
}

@test "backend error propagates its rc" {
  setup_echo
  backend_reply() { return 7; }
  run prompt_main "$SLUG" "x"
  [ "$status" -eq 7 ]
  assert_outbox_empty
  teardown_lib
}

@test "a busy conversation lock exits 3" {
  setup_echo
  ( exec 9>"$LOCKS_DIR/$SLUG.lock"; flock 9; sleep 5 ) &
  holder=$!
  for _ in $(seq 1 50); do [[ -e "$LOCKS_DIR/$SLUG.lock" ]] && break; sleep 0.05; done
  ANSWER_LOCK_WAIT=1 run prompt_main "$SLUG" "hi"
  kill "$holder" 2>/dev/null || true
  [ "$status" -eq 3 ]
  teardown_lib
}

@test "a file the turn drops in the send folder is attached" {
  setup_echo
  backend_reply() {
    local wd; wd="$(conversation_workdir "$SLUG")"
    printf 'data' >"$wd/.wabox/${WABOX_SEND_DIR:-send}/out.txt"
    printf 'here is your file'
  }
  run prompt_main "$SLUG" "gimme the report"
  [ "$status" -eq 0 ]
  job="$(prompt_job)"
  [ "$(jq -r '.text' "$job")" = "here is your file" ]
  [ "$(jq -r '.files | length' "$job")" = "1" ]
  [[ "$(jq -r '.files[0]' "$job")" == *"/out.txt" ]]
  teardown_lib
}

# ---- claude-code backend (session continuity + permission parking) ---------

setup_cc() {
  setup_lib
  WABOX_BOT_BACKEND=claude-code load_core
  # shellcheck source=lib/prompt.sh
  source "$LIB_DIR/prompt.sh"
  SLUG="cc123456"
  JID="5522@s.whatsapp.net"
  mkdir -p "$SESSIONS_DIR/$SLUG"
  printf '%s\n' "$JID" >"$SESSIONS_DIR/$SLUG/conv_key"
}

@test "claude-code: session continuity — second prompt resumes" {
  setup_cc
  # Fake `claude`: record its argv, emit a minimal JSON turn with a session id.
  ARGS_LOG="$TMPDIR_TEST/claude-args.log"
  fake="$TMPDIR_TEST/fake-claude"
  cat >"$fake" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$ARGS_LOG"
printf '%s' '{"result":"ok","session_id":"sess-1","permission_denials":[]}'
EOF
  chmod +x "$fake"
  export CLAUDE_BIN="$fake"

  run prompt_main "$SLUG" "first"
  [ "$status" -eq 0 ]
  run prompt_main "$SLUG" "second"
  [ "$status" -eq 0 ]

  # First invocation started a fresh session; the second resumed it.
  [ "$(sed -n 1p "$ARGS_LOG" | grep -c -- '--session-id')" -eq 1 ]
  [[ "$(sed -n 2p "$ARGS_LOG")" == *"--resume sess-1"* ]]
  teardown_lib
}

@test "claude-code: a parked permission delivers the question and stays fresh" {
  setup_cc
  DENIALS='[{"tool_name":"Write","tool_use_id":"t","tool_input":{"file_path":"/tmp/x"}}]'
  export DENIALS
  cc_run_turn() { printf '%s' "{\"result\":\"blocked\",\"permission_denials\":$DENIALS}"; }

  run prompt_main "$SLUG" "write a file"
  [ "$status" -eq 0 ]
  job="$(prompt_job)"
  # The yes/no question text reached the chat.
  [[ "$(jq -r '.text' "$job")" == *"*Write*"* ]]
  # A fresh pending permission remains for the next answer.
  [ -e "$(cc_pending_permission_path "$SLUG")" ]
  teardown_lib
}
