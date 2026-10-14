load test_helper

# Isolated scheduled turns (WABOX_TURN_ISOLATED=1): they run in a throwaway
# session, and what they deliver is handed to the main session on its next turn.

setup() {
  setup_lib
  export WABOX_BOT_BACKEND=claude-code
  load_core
  SLUG="cafe9abc"
  JID="5511@s.whatsapp.net"
  mkdir -p "$SESSIONS_DIR/$SLUG"
  FAKE_BIN="$TMPDIR_TEST/bin"
  mkdir -p "$FAKE_BIN"
  # A fake claude that records argv and stdin, and answers with $FAKE_RESULT
  # (and $FAKE_DENIALS) from files so each test can change them between turns.
  printf 'oi' >"$TMPDIR_TEST/result"
  printf '[]' >"$TMPDIR_TEST/denials"
  printf '0' >"$TMPDIR_TEST/rc"
  cat >"$FAKE_BIN/claude" <<EOF2
#!/usr/bin/env bash
cat >"$TMPDIR_TEST/stdin"
printf '%s\n' "\$@" >"$TMPDIR_TEST/argv"
rc=\$(cat "$TMPDIR_TEST/rc")
((rc == 0)) || exit "\$rc"
jq -cn --arg r "\$(cat "$TMPDIR_TEST/result")" --argjson d "\$(cat "$TMPDIR_TEST/denials")" \
  '{result:\$r, session_id:"returned-sid", permission_denials:\$d}'
EOF2
  chmod +x "$FAKE_BIN/claude"
  export CLAUDE_BIN="$FAKE_BIN/claude"
  # shellcheck source=../../lib/backends/claude-code.sh
  source "$LIB_DIR/backends/claude-code.sh"
  WD="$(conversation_workdir "$SLUG")"
  cc_save_session_id "$SLUG" "main-sid" "$WD"
}

teardown() {
  teardown_lib
}

job_turn() {
  WABOX_TURN_SYNTHETIC=1 WABOX_TURN_ISOLATED=1 WABOX_TURN_LABEL="job #3 (daily 06:00)" \
    backend_reply "$SLUG" "$JID" stem <<<"run the morning brief"
}

notes() { cat "$(cc_job_notes_path "$SLUG")"; }

@test "an isolated turn starts a fresh session and leaves the conversation's alone" {
  printf 'Bom dia! Brief.' >"$TMPDIR_TEST/result"
  run job_turn
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "Bom dia! Brief." ]
  ! grep -qx -- '--resume' "$TMPDIR_TEST/argv"
  grep -qx -- '--session-id' "$TMPDIR_TEST/argv"
  ! grep -qx 'main-sid' "$TMPDIR_TEST/argv"
  # Not even the id claude reported back replaces the main session.
  [ "$(cc_session_id_for "$SLUG")" = "main-sid" ]
}

@test "what an isolated turn delivered is queued with its label" {
  printf 'Bom dia! Brief.' >"$TMPDIR_TEST/result"
  job_turn >/dev/null
  grep -q '^--- job #3 (daily 06:00), sent ' <(notes)
  grep -qx 'Bom dia! Brief.' <(notes)
}

@test "a NOOP or empty isolated reply is not queued" {
  printf '  NOOP \n' >"$TMPDIR_TEST/result"
  job_turn >/dev/null
  printf '' >"$TMPDIR_TEST/result"
  job_turn >/dev/null
  [ ! -s "$(cc_job_notes_path "$SLUG")" ]
}

@test "an isolated turn blocked on a permission queues nothing" {
  printf '[{"tool_name":"Bash","tool_input":{"command":"ls"}}]' >"$TMPDIR_TEST/denials"
  job_turn >/dev/null
  [ ! -s "$(cc_job_notes_path "$SLUG")" ]
}

@test "the next main turn resumes the conversation with the queued messages first" {
  printf 'Bom dia! Item 1, item 2.' >"$TMPDIR_TEST/result"
  job_turn >/dev/null
  printf 'ok' >"$TMPDIR_TEST/result"
  backend_reply "$SLUG" "$JID" stem <<<"fala mais do item 2" >/dev/null
  grep -qx -- '--resume' "$TMPDIR_TEST/argv"
  grep -qx 'main-sid' "$TMPDIR_TEST/argv"
  grep -q 'scheduled jobs ran in separate sessions' "$TMPDIR_TEST/stdin"
  grep -qx 'Bom dia! Item 1, item 2.' "$TMPDIR_TEST/stdin"
  # The user's own text comes last, after the framing.
  [ "$(tail -n1 "$TMPDIR_TEST/stdin")" = "fala mais do item 2" ]
  # Delivered once: the turn after that carries nothing.
  [ ! -e "$(cc_job_notes_path "$SLUG")" ]
  backend_reply "$SLUG" "$JID" stem <<<"e o 1?" >/dev/null
  ! grep -q 'scheduled jobs' "$TMPDIR_TEST/stdin"
}

@test "a failed main turn keeps the queued messages for the next one" {
  printf 'Brief.' >"$TMPDIR_TEST/result"
  job_turn >/dev/null
  printf '1' >"$TMPDIR_TEST/rc"
  run backend_reply "$SLUG" "$JID" stem <<<"oi"
  [ "$status" -ne 0 ]
  grep -qx 'Brief.' <(notes)
}

@test "notes from several jobs accumulate, and an oversized one is cut" {
  CC_JOB_NOTE_MAX=10
  printf 'first' >"$TMPDIR_TEST/result"
  job_turn >/dev/null
  printf 'a very long second message' >"$TMPDIR_TEST/result"
  job_turn >/dev/null
  grep -qx 'first' <(notes)
  grep -qx 'a very lon \[…\]' <(notes)
}

@test "the preamble keeps only the newest notes past the total cap" {
  printf '%s' "$(printf 'x%.0s' {1..50})" >"$TMPDIR_TEST/result"
  job_turn >/dev/null
  printf 'newest' >"$TMPDIR_TEST/result"
  job_turn >/dev/null
  CC_JOB_NOTES_MAX=40
  run cc_job_notes_preamble "$SLUG"
  [[ "$output" == *"(older scheduled messages omitted)"* ]]
  [[ "$output" == *newest* ]]
  [[ "$output" != *"$(printf 'x%.0s' {1..50})"* ]]
}

@test "/clear drops the queued notes" {
  printf 'Brief.' >"$TMPDIR_TEST/result"
  job_turn >/dev/null
  backend_clear "$SLUG"
  [ ! -e "$(cc_job_notes_path "$SLUG")" ]
}
