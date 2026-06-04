# shellcheck shell=bash
# Stub: how a hypothetical `aider` backend could look.
#
# Not wired in by default. Copy to lib/backends/aider.sh, fill in the
# blanks, then run with `wabox-bot --backend aider`. See docs/backends.md
# for the full contract.

backend_name() {
  printf 'aider\n'
}

backend_check_dependencies() {
  # aider needs a Python interpreter and the aider CLI on PATH. Both go
  # here so a missing tool surfaces at startup, not on the first message.
  need aider
  need python3
}

backend_reply() {
  local slug="$1" conv_key="$2" stem="$3"
  local text
  text="$(cat)"

  # aider keeps its own per-workspace state on disk; we just need a
  # per-conversation directory to hand it. backend_state_dir takes care
  # of creating $SESSIONS_DIR/<slug>/aider for us.
  local workspace
  workspace="$(backend_state_dir "$slug")"

  log_info "[$stem] conv=$conv_key aider workspace=$workspace"

  # Pipe the user's text in on stdin; aider writes the assistant turn to
  # stdout. The 124 exit code on timeout is what backend_reply's contract
  # expects, and `timeout` provides it for free.
  timeout --kill-after=5 "${AIDER_TIMEOUT:-180}" \
    aider --no-pretty --no-stream --message-file=/dev/stdin <<<"$text"
}

# Aider has its own /add, /drop, /diff commands but none of those make
# sense over WhatsApp. Skip backend_handle_command — the dispatcher will
# fall through to "Unknown command" for anything starting with /.

backend_clear() {
  # Burn the workspace so the next /reply starts from a clean repo state.
  local slug="$1"
  rm -rf -- "$(backend_state_dir "$slug")"
}
