load test_helper

setup() {
  setup_lib
  WABOX_BOT_BACKEND=agy load_core
  SLUG="deadbeef"
  # A fake agy on PATH. In print mode it records its argv and stdin, writes a
  # conversation id into the --log-file (as the real agy does), and echoes a
  # canned reply. The `models` subcommand prints a fixed model list.
  AGYHOME="$TMPDIR_TEST/bin"
  mkdir -p "$AGYHOME"
  cat >"$AGYHOME/agy" <<'EOS'
#!/usr/bin/env bash
if [[ "$1" == "models" ]]; then
  printf '%s\n' "Gemini 3.5 Flash (Medium)" "Claude Opus 4.6 (Thinking)"
  exit 0
fi
printf '%s\n' "$@" >>"$AGY_ARGS_LOG"
logf=""; prev=""
for a in "$@"; do
  [[ "$prev" == "--log-file" ]] && logf="$a"
  prev="$a"
done
[[ -n "$logf" ]] && printf 'I0607 server.go conversation=11111111-2222-3333-4444-555555555555 done\n' >"$logf"
cat >"$AGY_STDIN_LOG"
printf '%s' "${AGY_FAKE_REPLY:-the agy reply}"
EOS
  chmod +x "$AGYHOME/agy"
  export PATH="$AGYHOME:$PATH"
  export AGY_ARGS_LOG="$TMPDIR_TEST/agy.args"
  export AGY_STDIN_LOG="$TMPDIR_TEST/agy.stdin"
  : >"$AGY_ARGS_LOG"
}

teardown() {
  teardown_lib
}

@test "backend_name is agy" {
  run backend_name
  [ "$status" -eq 0 ]
  [ "$output" = "agy" ]
}

@test "agy_compose_prompt prepends the concise-answer instruction" {
  run agy_compose_prompt "what is 2+2?" "" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"do not narrate your steps"* ]]
  [[ "$output" == *"what is 2+2?"* ]]
}

@test "agy_compose_prompt prepends an image pointer and keeps the caption" {
  run agy_compose_prompt "what is this?" ".wabox/media/p.jpg" "image"
  [ "$status" -eq 0 ]
  [[ "$output" == *".wabox/media/p.jpg"* ]]
  [[ "$output" == *"what is this?"* ]]
}

@test "agy_compose_prompt with an empty prefix omits the instruction" {
  AGY_REPLY_PREFIX="" run agy_compose_prompt "hello" "" ""
  [ "$status" -eq 0 ]
  [ "$output" = "hello" ]
}

@test "backend_reply returns agy's stdout" {
  output="$(printf "hi" | backend_reply "$SLUG" "conv" "stem")"
  [ "$output" = "the agy reply" ]
}

@test "backend_reply pipes the prompt on stdin, not argv" {
  printf "the user prompt" | backend_reply "$SLUG" "conv" "stem"
  [[ "$(cat "$AGY_STDIN_LOG")" == *"the user prompt"* ]]
}

@test "backend_reply strips the conversation-not-found warning from the reply" {
  export AGY_FAKE_REPLY=$'Warning: conversation "x" not found.\nthe real answer'
  output="$(printf "hi" | backend_reply "$SLUG" "conv" "stem")"
  [[ "$output" != *"not found"* ]]
  [[ "$output" == *"the real answer"* ]]
}

@test "first turn has no --conversation; the id is captured and reused next turn" {
  printf "one" | backend_reply "$SLUG" "conv" "stem"
  run grep -qx -- "--conversation" "$AGY_ARGS_LOG"
  [ "$status" -ne 0 ]   # no --conversation on the first turn
  # The id agy logged was captured and persisted.
  [ "$(agy_conversation_for "$SLUG")" = "11111111-2222-3333-4444-555555555555" ]

  : >"$AGY_ARGS_LOG"
  printf "two" | backend_reply "$SLUG" "conv" "stem"
  run grep -qx -- "--conversation" "$AGY_ARGS_LOG"
  [ "$status" -eq 0 ]
  run grep -qx -- "11111111-2222-3333-4444-555555555555" "$AGY_ARGS_LOG"
  [ "$status" -eq 0 ]
}

@test "backend_reply always passes --log-file and --print-timeout" {
  printf "x" | backend_reply "$SLUG" "conv" "stem"
  run grep -qx -- "--log-file" "$AGY_ARGS_LOG"
  [ "$status" -eq 0 ]
  run grep -qx -- "--print-timeout" "$AGY_ARGS_LOG"
  [ "$status" -eq 0 ]
}

@test "a saved model override is passed via --model" {
  agy_save_model_for "$SLUG" "Claude Opus 4.6 (Thinking)"
  printf "x" | backend_reply "$SLUG" "conv" "stem"
  run grep -qx -- "--model" "$AGY_ARGS_LOG"
  [ "$status" -eq 0 ]
  run grep -qx -- "Claude Opus 4.6 (Thinking)" "$AGY_ARGS_LOG"
  [ "$status" -eq 0 ]
}

@test "backend_clear drops the conversation id" {
  agy_save_conversation_for "$SLUG" "abc"
  [ -n "$(agy_conversation_for "$SLUG")" ]
  backend_clear "$SLUG"
  [ -z "$(agy_conversation_for "$SLUG")" ]
}

@test "/model accepts a valid model from the agy models list" {
  run backend_handle_command "/model" "Claude Opus 4.6 (Thinking)" "$SLUG" "conv" "to@x" "id1" "stem"
  [ "$status" -eq 0 ]
  [ "$(agy_model_for "$SLUG")" = "Claude Opus 4.6 (Thinking)" ]
}

@test "/model rejects a model that is not in the list" {
  run backend_handle_command "/model" "Totally Fake Model" "$SLUG" "conv" "to@x" "id1" "stem"
  [ "$status" -eq 0 ]   # handled (with a rejection reply), not passed through
  [ -z "$(agy_model_for "$SLUG")" ]
}

@test "/model default removes the override" {
  agy_save_model_for "$SLUG" "Gemini 3.5 Flash (Medium)"
  run backend_handle_command "/model" "default" "$SLUG" "conv" "to@x" "id1" "stem"
  [ "$status" -eq 0 ]
  [ -z "$(agy_model_for "$SLUG")" ]
}

@test "backend_handle_command passes unknown commands through with 99" {
  run backend_handle_command "/wat" "" "$SLUG" "conv" "to@x" "id1" "stem"
  [ "$status" -eq 99 ]
}
