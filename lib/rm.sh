# `wabox-bot rm <slug> [--yes]` — delete a conversation end-to-end.
#
# Removes the session dir ($SESSIONS_DIR/<slug> — session ids, overrides, pending
# permission, conv_key, the /cwd pointer) and, only when the effective workdir is
# the auto default ($STATE_DIR/work/<slug>), that workdir too. A /cwd-redirected
# folder is the user's own ("your folder, your files") — rm removes the pointer
# to it (which lives inside the session dir) and prints the path it left behind,
# never touching the contents.
#
# Deletion must not be promptable from the chat side, so this is CLI-only — there
# is no /rm slash command (same reasoning as `send --to` gating). It takes the
# per-conversation lock so it can't race an in-flight turn.
#
# Exit codes: 0 ok, 1 usage / unknown slug / non-TTY without --yes, 3 busy.

rm_main() {
  local slug="" apply=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes | -y) apply=1; shift ;;
      -*)
        printf 'wabox-bot rm: unknown option: %s\n' "$1" >&2
        return 1
        ;;
      *)
        if [[ -n "$slug" ]]; then
          printf 'wabox-bot rm: unexpected argument: %s\n' "$1" >&2
          return 1
        fi
        slug="$1"; shift
        ;;
    esac
  done

  if [[ -z "$slug" ]]; then
    printf 'Usage: wabox-bot rm <slug> [--yes]\n' >&2
    return 1
  fi
  if [[ ! -d "$SESSIONS_DIR/$slug" ]]; then
    printf 'wabox-bot rm: unknown conversation slug: %s\n' "$slug" >&2
    return 1
  fi

  local winfo is_default workdir conv_key=""
  winfo="$(workdir_info "$slug")"
  is_default="${winfo%%$'\n'*}"
  workdir="${winfo#*$'\n'}"
  [[ -s "$SESSIONS_DIR/$slug/conv_key" ]] && conv_key="$(cat -- "$SESSIONS_DIR/$slug/conv_key")"

  # Serialize against an in-flight turn (busy ⇒ 3, matching answer/prompt) before
  # we prompt or delete, so the confirmation can't be answered mid-turn.
  exec 8>"$LOCKS_DIR/$slug.lock"
  if ! flock -w "${ANSWER_LOCK_WAIT:-5}" 8; then
    printf 'wabox-bot rm: conversation is busy (lock held): %s\n' "$slug" >&2
    exec 8>&-
    return 3
  fi

  if ((!apply)); then
    if [[ ! -t 0 ]]; then
      printf 'wabox-bot rm: refusing to delete without --yes on a non-terminal\n' >&2
      exec 8>&-
      return 1
    fi
    printf 'Delete conversation %s?\n' "$slug"
    printf '  conv_key: %s\n' "${conv_key:-<unknown>}"
    if [[ "$is_default" == true ]]; then
      printf '  workdir:  %s (default — will be deleted)\n' "$workdir"
    else
      printf '  workdir:  %s (/cwd override — preserved)\n' "$workdir"
    fi
    printf '  size:     %s (bot: %s)\n' \
      "$(human_bytes "$(dir_bytes "$workdir")")" \
      "$(human_bytes "$(dir_bytes "$(workdir_botdir_path "$workdir")")")"
    local ans
    read -r -p 'Type yes to confirm: ' ans
    if [[ "$ans" != yes && "$ans" != y ]]; then
      printf 'Aborted.\n'
      exec 8>&-
      return 0
    fi
  fi

  rm -rf -- "$SESSIONS_DIR/$slug"
  if [[ "$is_default" == true ]]; then
    rm -rf -- "$workdir"
    printf 'Removed conversation %s and its workdir %s.\n' "$slug" "$workdir"
  else
    printf 'Removed conversation %s. Your folder was left in place: %s\n' "$slug" "$workdir"
  fi
  exec 8>&-
  return 0
}
