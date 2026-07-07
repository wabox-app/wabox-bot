# `wabox-bot cmd <slug> "<slash command>"` — run a conversation's slash command
# from the CLI, reusing the exact daemon logic (lib/commands.sh + the backend's
# handle_command hook) that a WhatsApp message would hit. The reply the command
# would send over WhatsApp is captured and printed on stdout instead of being
# delivered to the chat, so tooling (wabox-tui) can drive /cwd, /model, /mode,
# /system, /clear, … without messaging the user.
#
# This is the write half of the state/answer contract: `state --json` reads a
# conversation's overrides, `cmd` changes them, through the one code path that
# already validates and persists them.
#
# We do NOT take the per-conversation flock here — the individual commands grab
# it themselves where they mutate state (see /cwd, /model, …). Wrapping them in
# our own hold on the same lock would deadlock their nested `flock` on a fresh
# fd. (This means `cmd` can block while an in-flight turn holds the lock, same as
# a WhatsApp command would — that's the correct serialization.)
#
# Exit codes:
#   0  command handled (reply on stdout; may be an "Unknown command" notice)
#   1  usage / unknown slug / input wasn't a slash command

cmd_main() {
  local slug="${1:-}"
  shift || true
  local text="$*"

  if [[ -z "$slug" || -z "$text" ]]; then
    printf 'Usage: wabox-bot cmd <slug> "<slash command>"\n' >&2
    return 1
  fi

  # conv_key is the only way back from the one-way slug to the routable JID.
  local conv_key=""
  if [[ -s "$SESSIONS_DIR/$slug/conv_key" ]]; then
    conv_key="$(cat -- "$SESSIONS_DIR/$slug/conv_key")"
  fi
  if [[ -z "$conv_key" ]]; then
    printf 'wabox-bot cmd: unknown conversation slug: %s\n' "$slug" >&2
    return 1
  fi

  # Capture the reply instead of delivering it. handle_slash_command calls
  # write_outbox inside `$(...)` (a subshell), so a shell variable wouldn't
  # survive — route the captured text through a temp file the subshell appends
  # to. WABOX_CMD_CAPTURE is a plain global: subshells inherit it.
  local capture
  capture="$(mktemp "${TMPDIR:-/tmp}/wabox-cmd.XXXXXX")" || {
    printf 'wabox-bot cmd: could not create a temp file\n' >&2
    return 1
  }
  WABOX_CMD_CAPTURE="$capture"
  # Shadow the real writer for this one-shot process. Signature mirrors the real
  # write_outbox(to, text, reply_to_id, stem); we only keep the text.
  write_outbox() { printf '%s\n' "$2" >>"$WABOX_CMD_CAPTURE"; printf '%s' "$WABOX_CMD_CAPTURE"; }

  local to="${conv_key%%|*}"
  local rc=0
  handle_slash_command "$text" "$slug" "$conv_key" "$to" "" "cmd-$(date +%s)-$$" || rc=$?

  # handle_slash_command: 0 = handled (recognized, or an "Unknown command"
  # notice was written), 1 = input wasn't a slash command at all.
  if (( rc == 1 )); then
    rm -f -- "$capture"
    printf 'wabox-bot cmd: not a slash command: %s\n' "$text" >&2
    return 1
  fi

  cat -- "$capture"
  rm -f -- "$capture"
  return 0
}
