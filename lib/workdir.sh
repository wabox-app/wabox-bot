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
  local slug="$1" override_file dir is_default=1
  override_file="$(conversation_dir "$slug")/workdir"
  if [[ -s "$override_file" ]]; then
    dir="$(cat -- "$override_file")"
    is_default=0
  else
    dir="$STATE_DIR/work/$slug"
  fi
  mkdir -p "$dir"
  # Seed a freshly-created *default* workdir via the backend's optional hook —
  # its instructions file (WhatsApp etiquette + memory practice), shared skills,
  # etc. Only auto defaults: a /cwd redirect points at the user's own folder and
  # must never be written into. The hook is seed-if-absent and cheap-idempotent
  # (the plan requires this — it runs on every resolution), so the cost is one
  # stat per turn; a hook failure warns but never fails the turn. The hook must
  # emit nothing on stdout, since callers capture this function's output.
  if ((is_default)) && declare -f backend_seed_workdir >/dev/null; then
    if ! backend_seed_workdir "$slug" "$dir"; then
      log_warn "backend_seed_workdir failed for slug=$slug workdir=$dir"
    fi
  fi
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

# Machine-readable sibling of workdir_display for `wabox-bot state`. Prints two
# lines — "true"/"false" (is it the auto default?) then the path — and, like
# workdir_display and unlike conversation_workdir, does NOT create the directory
# (state is a read-only command).
workdir_info() {
  local slug="$1" file
  file="$(conversation_dir "$slug")/workdir"
  if [[ -s "$file" ]]; then
    printf 'false\n%s' "$(cat -- "$file")"
  else
    printf 'true\n%s' "$STATE_DIR/work/$slug"
  fi
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
