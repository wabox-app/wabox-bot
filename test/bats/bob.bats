load test_helper

setup() {
  setup_lib
  WABOX_BOT_BACKEND=bob load_core
  SLUG="deadbeef"
  # A fake bob on PATH that echoes the json envelope bob produces, recording
  # the args and stdin it was called with so tests can assert on them.
  BOBHOME="$TMPDIR_TEST/bin"
  mkdir -p "$BOBHOME"
  cat >"$BOBHOME/bob" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$BOB_ARGS_LOG"
cat >"$BOB_STDIN_LOG"
printf '{"response": "hi from bob", "stats": {}}'
EOS
  chmod +x "$BOBHOME/bob"
  export PATH="$BOBHOME:$PATH"
  export BOB_ARGS_LOG="$TMPDIR_TEST/bob.args"
  export BOB_STDIN_LOG="$TMPDIR_TEST/bob.stdin"
  : >"$BOB_ARGS_LOG"
}

teardown() {
  teardown_lib
}

@test "backend_name is bob" {
  run backend_name
  [ "$status" -eq 0 ]
  [ "$output" = "bob" ]
}

@test "bob_compose_prompt passes plain text through unchanged when there is no media" {
  run bob_compose_prompt "hello there" "" ""
  [ "$status" -eq 0 ]
  [ "$output" = "hello there" ]
}

@test "bob_compose_prompt prepends an @-reference for images and keeps the caption" {
  run bob_compose_prompt "what is this?" "wabox-media/p.jpg" "image"
  [ "$status" -eq 0 ]
  [[ "$output" == *"@wabox-media/p.jpg"* ]]
  [[ "$output" == *"what is this?"* ]]
}

@test "bob_compose_prompt ignores a non-image media type" {
  run bob_compose_prompt "transcript text" "wabox-media/a.ogg" "audio"
  [ "$output" = "transcript text" ]
}

@test "backend_reply extracts .response from bob's json envelope" {
  output="$(printf "ping" | backend_reply "$SLUG" "conv" "stem")"
  [ "$output" = "hi from bob" ]
}

@test "backend_reply pipes the prompt on stdin, not argv" {
  printf "the user prompt" | backend_reply "$SLUG" "conv" "stem"
  [ "$(cat "$BOB_STDIN_LOG")" = "the user prompt" ]
}

@test "the first turn does not pass --resume, later turns resume latest" {
  printf "one" | backend_reply "$SLUG" "conv" "stem"
  run grep -qx -- "--resume" "$BOB_ARGS_LOG"
  [ "$status" -ne 0 ]   # no --resume on the first turn

  : >"$BOB_ARGS_LOG"
  printf "two" | backend_reply "$SLUG" "conv" "stem"
  run grep -qx -- "--resume" "$BOB_ARGS_LOG"
  [ "$status" -eq 0 ]
  run grep -qx -- "latest" "$BOB_ARGS_LOG"
  [ "$status" -eq 0 ]
}

@test "json output format is forced regardless of BOB_ARGS" {
  printf "x" | backend_reply "$SLUG" "conv" "stem"
  run grep -qx -- "-o" "$BOB_ARGS_LOG"
  [ "$status" -eq 0 ]
  run grep -qx -- "json" "$BOB_ARGS_LOG"
  [ "$status" -eq 0 ]
}

@test "a non-zero bob exit propagates as an error, leaving no session marker" {
  cat >"$BOBHOME/bob" <<'EOS'
#!/usr/bin/env bash
printf '{"error": {"type": "iet", "message": "plan suspended", "code": 1}}'
exit 1
EOS
  chmod +x "$BOBHOME/bob"
  rc=0
  printf "x" | backend_reply "$SLUG" "conv" "stem" || rc=$?
  [ "$rc" -eq 1 ]
  run bob_has_session "$SLUG"
  [ "$status" -ne 0 ]
}

@test "a saved model override is passed via --model" {
  bob_save_model_for "$SLUG" "granite-3"
  printf "x" | backend_reply "$SLUG" "conv" "stem"
  run grep -qx -- "--model" "$BOB_ARGS_LOG"
  [ "$status" -eq 0 ]
  run grep -qx -- "granite-3" "$BOB_ARGS_LOG"
  [ "$status" -eq 0 ]
}

@test "a saved mode override is passed via --chat-mode" {
  bob_save_mode_for "$SLUG" "plan"
  printf "x" | backend_reply "$SLUG" "conv" "stem"
  run grep -qx -- "--chat-mode" "$BOB_ARGS_LOG"
  [ "$status" -eq 0 ]
  # plan appears as the override value (and "advanced" still from BOB_ARGS).
  run grep -qx -- "plan" "$BOB_ARGS_LOG"
  [ "$status" -eq 0 ]
}

@test "backend_clear drops the session marker" {
  bob_mark_started "$SLUG"
  run bob_has_session "$SLUG"
  [ "$status" -eq 0 ]
  backend_clear "$SLUG"
  run bob_has_session "$SLUG"
  [ "$status" -ne 0 ]
}

@test "backend_handle_command rejects an out-of-enum mode" {
  run backend_handle_command "/mode" "wibble" "$SLUG" "conv" "to@x" "id1" "stem"
  [ "$status" -eq 0 ]   # handled (with a rejection reply), not passed through
  [ -z "$(bob_mode_for "$SLUG")" ]
}

@test "backend_handle_command accepts a valid mode" {
  run backend_handle_command "/mode" "code" "$SLUG" "conv" "to@x" "id1" "stem"
  [ "$status" -eq 0 ]
  [ "$(bob_mode_for "$SLUG")" = "code" ]
}

@test "backend_handle_command passes unknown commands through with 99" {
  run backend_handle_command "/wat" "" "$SLUG" "conv" "to@x" "id1" "stem"
  [ "$status" -eq 99 ]
}
