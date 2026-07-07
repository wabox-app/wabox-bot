# Outgoing-file staging (the <workdir>/wabox-send/ convention).
#
# Files an agent writes into <workdir>/$WABOX_SEND_DIR/ during a turn are
# attached to its reply (see lib/inbox.sh). This module owns that folder's
# lifecycle so the wiring in inbox.sh stays testable in isolation:
#
#   senddir_prepare <workdir> <stem>  — ready the folder at turn start
#   senddir_collect <workdir>         — list the files to attach after the turn
#   senddir_prune   <workdir>         — drop old archives opportunistically
#
# Why clear at the *start* of the next turn and not right after the reply: core
# reads the files asynchronously while sending, so deleting them the moment we
# write the job would race the send. Instead, leftovers are archived into a
# dot-prefixed `.sent/<stem>/` (which the attach glob skips) at the next turn's
# start. The model never names files here — the loop attaches whatever landed.

# The send folder for a workdir. Name configurable (relative to the workdir);
# a leading-dot or absolute WABOX_SEND_DIR would break the archive/glob logic,
# so it's treated as a plain relative folder name.
senddir_path() {
  printf '%s/%s' "$1" "${WABOX_SEND_DIR:-wabox-send}"
}

# Ready the send folder for a turn: create it, and archive any non-hidden
# leftovers from a previous turn into `.sent/<stem>/`. Idempotent — an
# already-empty folder is a no-op. We match `"$dir"/*` (no dotglob), so hidden
# entries — crucially `.sent` itself — are never re-archived into themselves.
senddir_prepare() {
  local workdir="$1" stem="$2" dir
  dir="$(senddir_path "$workdir")"
  mkdir -p "$dir"

  local -a leftovers=()
  local entry
  for entry in "$dir"/*; do
    # Without nullglob a no-match glob stays literal; the -e guard drops it.
    [[ -e "$entry" ]] || continue
    leftovers+=("$entry")
  done
  [[ ${#leftovers[@]} -eq 0 ]] && return 0

  local archive="$dir/.sent/$stem"
  mkdir -p "$archive"
  mv -f -- "${leftovers[@]}" "$archive/" 2>/dev/null || true
}

# Print the attachable files — non-hidden regular files directly in the send
# folder — as absolute paths, one per line, sorted by name. Empty output when
# there are none. core sends multiple files as separate messages in order, so a
# stable name-sort fixes that order (the reply text becomes file #1's caption).
# workdir is already absolute (conversation_workdir / a /cwd override), so the
# glob entries are absolute too — core reads them directly, not relative to cwd.
senddir_collect() {
  local workdir="$1" dir
  dir="$(senddir_path "$workdir")"
  [[ -d "$dir" ]] || return 0

  local -a files=()
  local entry
  for entry in "$dir"/*; do
    # Regular files only — this skips the `.sent/` archive dir and a no-match
    # literal glob alike. Hidden dot-files aren't matched without dotglob.
    [[ -f "$entry" ]] || continue
    files+=("$entry")
  done
  [[ ${#files[@]} -eq 0 ]] && return 0

  printf '%s\n' "${files[@]}" | sort
}

# Opportunistically delete archived turns older than WABOX_SEND_KEEP_DAYS.
# Only ever touches per-stem dirs under `.sent/` — never live files, never
# `.sent` itself, never anything outside it.
senddir_prune() {
  local workdir="$1" dir sent keep
  dir="$(senddir_path "$workdir")"
  sent="$dir/.sent"
  keep="${WABOX_SEND_KEEP_DAYS:-7}"
  [[ -d "$sent" ]] || return 0

  # -mtime +N: strictly older than N*24h. mindepth/maxdepth 1 so we remove the
  # per-stem archive dirs but not $sent itself.
  find "$sent" -mindepth 1 -maxdepth 1 -type d -mtime +"$keep" \
    -exec rm -rf -- {} + 2>/dev/null || true
}
