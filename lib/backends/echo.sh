# shellcheck shell=bash
# Echo backend.
#
# Replies "echo: <text>" to every incoming message. Useful for smoke-testing
# the wabox-bot loop end-to-end without involving an LLM or burning tokens.
#
# Implements the minimum contract: backend_name + backend_reply. No
# per-conversation state, no slash commands, no extra dependencies.

backend_name() {
  printf 'echo\n'
}

backend_reply() {
  # shellcheck disable=SC2034  # slug is part of the contract; unused here
  local slug="$1" conv_key="$2" stem="$3"
  local text
  text="$(cat)"
  log_info "[$stem] conv=$conv_key echo (${#text} chars)"
  printf 'echo: %s' "$text"
}
