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

# ---- Bot plumbing dir (.wabox/) ----------------------------------------------
# All bot-owned plumbing (staged inbound media, outgoing-file staging + its
# archives) lives under one hidden dir per workdir so it never litters the
# user's own folder after /cwd. This is the *only* place the name ".wabox"
# is written — everything else routes through these helpers.
_WABOX_BOTDIR_NAME=.wabox

# Pure path — no mkdir, no migration. Read-only callers (state --sizes,
# /status, gc, rm) use this so they never materialize an empty .wabox/ as a
# side effect.
workdir_botdir_path() {
  printf '%s/%s' "$1" "$_WABOX_BOTDIR_NAME"
}

# One-time migration of the flat legacy layout (`wabox-send/`, `wabox-media/`
# at the workdir root) into `.wabox/`. Those names shipped for only a few
# hours, so we walk them back cheaply: move each into `.wabox/` and leave a
# relative compat symlink at the old name, keeping any in-flight outbox job
# (which holds an absolute path through the old name) and muscle memory working.
# A name that's already a symlink (migrated) or a destination that already
# exists is left untouched — this runs on every resolution and must be a no-op
# once done. gc removes the dangling symlinks after the next minor release.
_workdir_migrate_legacy() {
  local wd="$1" botdir="$2" pair legacy new
  local -a pairs=("wabox-send:${WABOX_SEND_DIR:-send}" "wabox-media:${WABOX_MEDIA_DIR:-media}")
  for pair in "${pairs[@]}"; do
    legacy="$wd/${pair%%:*}"
    new="$botdir/${pair#*:}"
    if [[ -d "$legacy" && ! -L "$legacy" && ! -e "$new" ]]; then
      mv -- "$legacy" "$new" 2>/dev/null || continue
      ln -s "$_WABOX_BOTDIR_NAME/${pair#*:}" "$legacy" 2>/dev/null || true
    fi
  done
}

# Resolve (and create) the `.wabox/` plumbing dir for a workdir, running the
# one-time legacy migration. Write-path callers (senddir/media staging) use
# this. Prints the absolute path with no trailing newline.
workdir_botdir() {
  local wd="$1" botdir
  botdir="$(workdir_botdir_path "$wd")"
  mkdir -p "$botdir"
  _workdir_migrate_legacy "$wd" "$botdir"
  printf '%s' "$botdir"
}

# ---- Sizes -------------------------------------------------------------------
# Apparent size in bytes of a directory (du -sb); 0 when the path is absent.
# du does not follow symlinks out of the tree by default, so a /cwd workdir's
# links can't inflate the count.
dir_bytes() {
  local d="$1" out
  [[ -d "$d" ]] || { printf '0'; return 0; }
  out="$(du -sb -- "$d" 2>/dev/null | cut -f1)"
  [[ "$out" =~ ^[0-9]+$ ]] || out=0
  printf '%s' "$out"
}

# Human-readable bytes for chat/status output, pt-BR decimal comma:
# 0 B / 12 KB / 800 MB / 1,2 GB. 1024 steps; one decimal past KB, trimmed
# when it would be ",0".
human_bytes() {
  awk -v b="${1:-0}" 'BEGIN {
    split("B KB MB GB TB PB", u, " ")
    i = 1; v = b + 0
    while (v >= 1024 && i < 6) { v /= 1024; i++ }
    if (i == 1) { printf "%d %s", v, u[i]; exit }
    v = sprintf("%.1f", v)
    if (v ~ /\.0$/) v = int(v)
    sub(/\./, ",", v)
    printf "%s %s", v, u[i]
  }'
}
