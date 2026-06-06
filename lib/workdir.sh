# Per-conversation working folder resolution.
#
# Each conversation gets a working directory the active backend cd's into
# before running an agent turn, so the agent's file operations stay isolated
# per conversation. Unset conversations default to an auto per-slug folder
# under $STATE_DIR/work; the /cwd command (lib/commands.sh) can redirect a
# conversation to a chosen path, persisted verbatim (already absolute) in
# $SESSIONS_DIR/<slug>/workdir.

# The per-conversation root — a sibling of the per-backend state subdirs
# (<slug>/<backend>/). The /cwd override file lives directly under here.
conversation_dir() {
  printf '%s' "$SESSIONS_DIR/$1"
}

# Resolve the *effective* working directory for a conversation: the /cwd
# override if set, else the auto default. Creates the directory and prints
# its path. The default materializes here on a conversation's first agent
# turn rather than eagerly for every conversation.
conversation_workdir() {
  local slug="$1" override_file dir
  override_file="$(conversation_dir "$slug")/workdir"
  if [[ -s "$override_file" ]]; then
    dir="$(cat -- "$override_file")"
  else
    dir="$STATE_DIR/work/$slug"
  fi
  mkdir -p "$dir"
  printf '%s' "$dir"
}

# Expand a leading ~ / ~/ in a user-supplied path to $HOME. Bash does not
# expand ~ inside a variable, so /cwd does it explicitly. Any path without a
# leading tilde is returned unchanged.
expand_tilde() {
  local p="$1"
  case "$p" in
    '~') printf '%s' "$HOME" ;;
    '~/'*) printf '%s' "$HOME/${p#'~/'}" ;;
    *) printf '%s' "$p" ;;
  esac
}

# Human-readable "path (default|override)" for /status and /cwd show. Unlike
# conversation_workdir, this does NOT create the directory.
workdir_display() {
  local slug="$1" file
  file="$(conversation_dir "$slug")/workdir"
  if [[ -s "$file" ]]; then
    printf '%s (override)' "$(cat -- "$file")"
  else
    printf '%s (default)' "$STATE_DIR/work/$slug"
  fi
}
