load test_helper

setup() {
  setup_lib
  WABOX_BOT_BACKEND=claude-code load_core
  SLUG="deadbeef"
  # A realistic single-denial array as emitted in `.permission_denials`.
  DENIALS='[{"tool_name":"Write","tool_use_id":"toolu_x","tool_input":{"file_path":"/tmp/hello.txt","content":"hi\n"}}]'
}

teardown() {
  teardown_lib
}

# ---- state roundtrip -------------------------------------------------------

@test "save/load/clear pending permission roundtrips the stored fields" {
  cc_save_pending_permission "$SLUG" "write the file" "$DENIALS" "$(date +%s)"
  pending="$(cc_load_pending_permission "$SLUG")"
  [ "$(jq -r '.original_prompt' <<<"$pending")" = "write the file" ]
  [ "$(jq -r '.denials[0].tool_name' <<<"$pending")" = "Write" ]
  cc_clear_pending_permission "$SLUG"
  [ ! -e "$(cc_pending_permission_path "$SLUG")" ]
}

@test "cc_has_pending_permission is false when nothing is parked" {
  run cc_has_pending_permission "$SLUG"
  [ "$status" -eq 1 ]
}

@test "cc_has_pending_permission is true for a fresh pending" {
  cc_save_pending_permission "$SLUG" "p" "$DENIALS" "$(date +%s)"
  run cc_has_pending_permission "$SLUG"
  [ "$status" -eq 0 ]
}

@test "cc_has_pending_permission clears and reports false once expired" {
  CC_PERMISSION_TIMEOUT=600
  # asked_at far in the past → now - asked_at >> timeout.
  cc_save_pending_permission "$SLUG" "p" "$DENIALS" 1
  run cc_has_pending_permission "$SLUG"
  [ "$status" -eq 1 ]
  # and the stale file is gone, so the next message is a normal prompt
  [ ! -e "$(cc_pending_permission_path "$SLUG")" ]
}

# ---- emit-or-park ----------------------------------------------------------

@test "cc_emit_or_park returns the result text when there are no denials" {
  json='{"result":"all done","permission_denials":[]}'
  run cc_emit_or_park "$SLUG" "the prompt" "$json"
  [ "$status" -eq 0 ]
  [ "$output" = "all done" ]
  [ ! -e "$(cc_pending_permission_path "$SLUG")" ]
}

@test "cc_emit_or_park parks and returns the permission question on a denial" {
  json="{\"result\":\"I need to write a file\",\"permission_denials\":$DENIALS}"
  run cc_emit_or_park "$SLUG" "the prompt" "$json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Claude precisa de permissão"* ]]
  [[ "$output" == *"*Write*"* ]]
  [[ "$output" == *"sim"* ]]
  # the parked file remembers the prompt and the denied tool
  pending="$(cc_load_pending_permission "$SLUG")"
  [ "$(jq -r '.original_prompt' <<<"$pending")" = "the prompt" ]
  [ "$(jq -r '.denials[0].tool_name' <<<"$pending")" = "Write" ]
}

@test "cc_format_permission_message lists each denied tool with its salient arg and the ask" {
  run cc_format_permission_message "$DENIALS"
  [[ "$output" == *"⚠️ *Claude precisa de permissão*"* ]]
  [[ "$output" == *"• *Write* — /tmp/hello.txt"* ]]
  [[ "$output" == *"Responda *sim* para autorizar ou *não* para cancelar."* ]]
  # the agent's free-text result is deliberately dropped — keep it objective
  [[ "$output" != *"result"* ]]
}

@test "cc_format_permission_message collapses a multi-line command onto one line" {
  d='[{"tool_name":"Bash","tool_use_id":"t","tool_input":{"command":"mkdir -p ~/tmp &&\nprintf x > ~/tmp/a.txt"}}]'
  run cc_format_permission_message "$d"
  [[ "$output" == *"• *Bash* — mkdir -p ~/tmp && printf x > ~/tmp/a.txt"* ]]
}

@test "cc_format_permission_message shows a bare tool when it has no salient arg" {
  d='[{"tool_name":"Skill","tool_use_id":"t","tool_input":{}}]'
  run cc_format_permission_message "$d"
  [[ "$output" == *"• *Skill*"* ]]
}

# ---- response handling -----------------------------------------------------

@test "a 'não' answer clears the pending and sends a cancellation" {
  cc_save_pending_permission "$SLUG" "p" "$DENIALS" "$(date +%s)"
  run cc_handle_permission_response "$SLUG" "conv" "stem" "/work" "não"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cancelado"* ]]
  [ ! -e "$(cc_pending_permission_path "$SLUG")" ]
}

@test "an unrecognised answer keeps the pending and re-asks" {
  cc_save_pending_permission "$SLUG" "p" "$DENIALS" "$(date +%s)"
  run cc_handle_permission_response "$SLUG" "conv" "stem" "/work" "what do you mean"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Não entendi"* ]]
  # still parked, so the next message gets another shot
  [ -e "$(cc_pending_permission_path "$SLUG")" ]
}

@test "a 'sim' answer resumes the turn granting exactly the denied tools" {
  cc_save_pending_permission "$SLUG" "write the file" "$DENIALS" "$(date +%s)"

  # Stub the real Claude invocation: record the allowedTools it was handed and
  # return a clean (no-denial) turn so the flow completes.
  GRANTED_FILE="$TMPDIR_TEST/granted"
  cc_run_turn() {
    printf '%s' "$6" >"$GRANTED_FILE"   # extra_allowed is arg 6
    printf '%s' '{"result":"file created","permission_denials":[]}'
  }

  run cc_handle_permission_response "$SLUG" "conv" "stem" "/work" "sim"
  [ "$status" -eq 0 ]
  [[ "$output" == *"file created"* ]]
  [ "$(cat "$GRANTED_FILE")" = "Write" ]
  # pending is cleared once approved
  [ ! -e "$(cc_pending_permission_path "$SLUG")" ]
}

@test "an approved turn that hits a NEW denial parks again" {
  cc_save_pending_permission "$SLUG" "do the thing" "$DENIALS" "$(date +%s)"

  bash_denial='[{"tool_name":"Bash","tool_use_id":"toolu_y","tool_input":{"command":"rm -rf /tmp/x"}}]'
  cc_run_turn() {
    printf '%s' "{\"result\":\"now I need to run a command\",\"permission_denials\":$bash_denial}"
  }
  export bash_denial

  run cc_handle_permission_response "$SLUG" "conv" "stem" "/work" "sim"
  [ "$status" -eq 0 ]
  [[ "$output" == *"*Bash*"* ]]
  # re-parked with the new denial
  [ -e "$(cc_pending_permission_path "$SLUG")" ]
  pending="$(cc_load_pending_permission "$SLUG")"
  [ "$(jq -r '.denials[0].tool_name' <<<"$pending")" = "Bash" ]
}

# ---- integration with /clear and /status -----------------------------------

@test "backend_clear drops a parked permission" {
  cc_save_pending_permission "$SLUG" "p" "$DENIALS" "$(date +%s)"
  backend_clear "$SLUG"
  [ ! -e "$(cc_pending_permission_path "$SLUG")" ]
}

@test "backend_status_lines flags a pending permission" {
  cc_save_pending_permission "$SLUG" "p" "$DENIALS" "$(date +%s)"
  run backend_status_lines "$SLUG"
  [[ "$output" == *"pending:"* ]]
  [[ "$output" == *"sim"* ]]
}
