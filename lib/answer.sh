# `wabox-bot answer <slug> <yes|no>` — answer a parked permission from the CLI.
#
# Drives the backend's answer hook down the same path a WhatsApp "sim"/"não"
# reply would take, then delivers the backend's reply to the chat so the user
# still sees the outcome in the conversation. It takes the *per-conversation*
# lock (never the single-instance lock — it's a client, not a second daemon),
# so it serializes against an in-flight turn for that same conversation.
#
# Exit codes (the stable contract):
#   0  ok
#   1  usage / unknown slug
#   2  no fresh pending permission
#   3  conversation lock busy
#   4  backend doesn't support answering permissions

answer_main() {
  local slug="${1:-}" decision="${2:-}"

  if [[ -z "$slug" || -z "$decision" ]]; then
    printf 'Usage: wabox-bot answer <slug> <yes|no>\n' >&2
    return 1
  fi
  case "$decision" in
    yes | no) ;;
    *)
      printf 'wabox-bot answer: decision must be yes or no (got: %s)\n' "$decision" >&2
      return 1
      ;;
  esac

  if ! declare -F backend_answer_permission >/dev/null; then
    printf 'wabox-bot answer: backend %s does not support answering permissions\n' \
      "$(backend_name)" >&2
    return 4
  fi

  # We need the conv_key both to route the reply and to hand the backend its
  # human-readable context. It's the only way back from the one-way slug.
  local conv_key=""
  if [[ -s "$SESSIONS_DIR/$slug/conv_key" ]]; then
    conv_key="$(cat -- "$SESSIONS_DIR/$slug/conv_key")"
  fi
  if [[ -z "$conv_key" ]]; then
    printf 'wabox-bot answer: unknown conversation slug: %s\n' "$slug" >&2
    return 1
  fi

  # Serialize against an in-flight turn for this conversation, mirroring the
  # daemon's per-conversation flock. Busy ⇒ exit 3 rather than blocking forever.
  exec 8>"$LOCKS_DIR/$slug.lock"
  if ! flock -w "${ANSWER_LOCK_WAIT:-5}" 8; then
    printf 'wabox-bot answer: conversation is busy (lock held): %s\n' "$slug" >&2
    exec 8>&-
    return 3
  fi

  local reply rc=0
  reply="$(backend_answer_permission "$slug" "$conv_key" "$decision")" || rc=$?
  exec 8>&-

  if ((rc != 0)); then
    if ((rc == 2)); then
      printf 'wabox-bot answer: no pending permission for %s\n' "$slug" >&2
    else
      printf 'wabox-bot answer: backend failed (rc=%d)\n' "$rc" >&2
    fi
    return "$rc"
  fi

  # Deliver the reply to the chat JID so the outcome shows up in the
  # conversation, exactly as a WhatsApp answer would have. For a
  # GROUP_PER_PARTICIPANT key "<from>|<participant>", the chat JID is the part
  # before the pipe.
  local to="${conv_key%%|*}"
  local stem="answer-$(date +%s)-$$"
  local out
  out="$(write_outbox "$to" "$reply" "" "$stem")"
  log_info "answer[$slug] delivered reply → $out"
  return 0
}
