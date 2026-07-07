# `wabox-bot prompt <slug> <text>` — run a real agent turn for a conversation
# and deliver its reply. Unlike `send` (dumb delivery), this is the canonical
# turn: it takes the per-conversation flock, resolves the working directory,
# runs the same `senddir` lifecycle and `backend_reply` an inbound message
# would, and delivers the result — so the session learns what was said (a later
# "what did you remind me about?" works) and a heartbeat turn can attach files.
#
# The text is the second argument, or stdin when it is `-`. The reply is
# suppressed — nothing delivered, exit 5 — when, after trimming whitespace, it
# is empty or exactly the NOOP sentinel (WABOX_PROMPT_NOOP, default `NOOP`); a
# standing heartbeat prompt answers NOOP when there's nothing worth saying, so
# suppression is a success for cron, just distinguishable.
#
# Exit codes (stable contract):
#   0    delivered
#   1    usage / unknown slug
#   3    conversation lock busy
#   5    suppressed (empty or NOOP — nothing delivered)
#   124  backend timeout (passthrough)
#   other  backend error (passthrough)

prompt_main() {
  local slug="${1:-}"

  if [[ -z "$slug" || $# -lt 2 ]]; then
    printf 'Usage: wabox-bot prompt <slug> <text|->\n' >&2
    return 1
  fi
  local text_arg="$2"

  # conv_key is the only way back from the one-way slug to the routable JID.
  local conv_key=""
  if [[ -s "$SESSIONS_DIR/$slug/conv_key" ]]; then
    conv_key="$(cat -- "$SESSIONS_DIR/$slug/conv_key")"
  fi
  if [[ -z "$conv_key" ]]; then
    printf 'wabox-bot prompt: unknown conversation slug: %s\n' "$slug" >&2
    return 1
  fi

  # Resolve the prompt text (buffer it before taking the lock). `-` reads stdin
  # so a multi-line standing prompt can be piped in.
  local text
  if [[ "$text_arg" == "-" ]]; then
    text="$(cat)"
  else
    text="$text_arg"
  fi
  if [[ -z "$text" ]]; then
    printf 'wabox-bot prompt: empty prompt text\n' >&2
    return 1
  fi

  # Serialize against an in-flight turn for this conversation, exactly as the
  # daemon's per-conversation flock does. Busy ⇒ exit 3 rather than blocking a
  # cron heartbeat forever behind a long turn.
  exec 8>"$LOCKS_DIR/$slug.lock"
  if ! flock -w "${ANSWER_LOCK_WAIT:-5}" 8; then
    printf 'wabox-bot prompt: conversation is busy (lock held): %s\n' "$slug" >&2
    exec 8>&-
    return 3
  fi

  local workdir
  workdir="$(conversation_workdir "$slug")"

  # Ready the send folder before the turn (archive a prior turn's leftovers,
  # prune old archives), mirroring lib/inbox.sh so a heartbeat can drop files.
  local stem="prompt-$(date +%s)-$$"
  senddir_prepare "$workdir" "$stem"
  senddir_prune "$workdir"

  local reply rc=0
  reply="$(printf '%s' "$text" |
    backend_reply "$slug" "$conv_key" "$stem" "" "" "")" || rc=$?

  if ((rc == 124)); then
    printf 'wabox-bot prompt: backend timed out\n' >&2
    exec 8>&-
    return 124
  elif ((rc != 0)); then
    printf 'wabox-bot prompt: backend failed (rc=%d)\n' "$rc" >&2
    exec 8>&-
    return "$rc"
  fi

  # Suppression sentinel: trim leading/trailing whitespace, then compare. On a
  # match (or an empty reply) nothing is delivered. Any files the turn dropped
  # in the send folder are deliberately left in place — the next turn's
  # senddir_prepare archives them, so a suppressed turn attaches nothing.
  local trimmed="${reply#"${reply%%[![:space:]]*}"}"
  trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
  local noop="${WABOX_PROMPT_NOOP:-NOOP}"
  if [[ -z "$trimmed" || "$trimmed" == "$noop" ]]; then
    log_info "prompt[$slug] suppressed (empty or $noop sentinel); nothing delivered"
    exec 8>&-
    return 5
  fi

  # Collect any files the agent left in the send folder and attach them, exactly
  # as lib/inbox.sh does — the loop, never the model, owns the file list.
  local -a extra_files=()
  local collected
  collected="$(senddir_collect "$workdir")"
  [[ -n "$collected" ]] && mapfile -t extra_files <<<"$collected"

  local extras=""
  if ((${#extra_files[@]})); then
    local files_json
    files_json="$(printf '%s\n' "${extra_files[@]}" | jq -R . | jq -cs .)"
    extras="$(jq -cn --argjson files "$files_json" '{files: $files}')"
    log_info "prompt[$slug] attaching ${#extra_files[@]} file(s) from send folder"
  fi

  local to="${conv_key%%|*}"
  local out
  out="$(write_outbox "$to" "$reply" "" "$stem" "$extras")"
  log_info "prompt[$slug] delivered reply → $out"
  lastmsg_write "$slug" out "$reply"
  exec 8>&-
  return 0
}
