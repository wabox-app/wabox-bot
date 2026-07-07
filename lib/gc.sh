# `wabox-bot gc [slug] [--yes]` — prune reclaimable bot plumbing by age.
#
# Scope: one conversation (slug) or all. Dry-run by default — it lists what
# would go and the byte total; `--yes` applies. The daemon never deletes
# user-visible data on its own; this is the explicit verb an operator runs (or
# crons). gc touches only three kinds of thing, all owned by the bot:
#
#   .wabox/<media>/            staged inbound media   > WABOX_MEDIA_KEEP_DAYS
#   .wabox/<send>/.sent/       archived reply files   > WABOX_SEND_KEEP_DAYS
#   <PROCESSED_DIR>/*.json     audit envelopes+media  > WABOX_PROCESSED_KEEP_DAYS
#
# plus dangling legacy compat symlinks (wabox-send, wabox-media) at the workdir
# root. A `*_KEEP_DAYS` of 0 disables that category. Nothing the agent or user
# authored is ever touched — pruning is anchored under .wabox/ and PROCESSED_DIR
# only, and `find -P` never follows a symlink out of the tree.
#
# Exit codes: 0 (dry-run or applied), 1 usage / unknown slug.

# Accumulators for the run. Reset at the top of gc_main so the lib can be
# sourced and gc_main called more than once (tests).
_GC_PATHS=()
_GC_BYTES=0

# Read newline-separated paths on stdin; size each, record it, and delete it
# when apply=1. du -sb works for files and dirs alike; a missing size counts 0.
_gc_consume() {
  local apply="$1" p sz
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    sz="$(du -sb -- "$p" 2>/dev/null | cut -f1)"
    [[ "$sz" =~ ^[0-9]+$ ]] || sz=0
    _GC_BYTES=$((_GC_BYTES + sz))
    _GC_PATHS+=("$p")
    if ((apply)); then
      rm -rf -- "$p" 2>/dev/null || true
    fi
  done
}

# Echo (one per line) the reclaimable paths for a single conversation's plumbing.
# Uses the *effective* workdir (default or /cwd) but only ever names things under
# .wabox/ — so even a /cwd redirect into the user's own folder stays safe.
_gc_candidates_conversation() {
  local slug="$1" wd botdir days dir legacy
  wd="$(workdir_info "$slug" | tail -n1)"
  [[ -n "$wd" ]] || return 0
  botdir="$(workdir_botdir_path "$wd")"

  # Staged inbound media — flat files directly under .wabox/<media>/.
  days="${WABOX_MEDIA_KEEP_DAYS:-30}"
  dir="$botdir/${WABOX_MEDIA_DIR:-media}"
  if [[ "$days" != 0 && -d "$dir" ]]; then
    find -P "$dir" -mindepth 1 -type f -mtime +"$days" 2>/dev/null
  fi

  # Archived reply turns — per-stem dirs under .wabox/<send>/.sent/ (mirrors
  # senddir_prune; gc just runs it across all conversations on demand).
  days="${WABOX_SEND_KEEP_DAYS:-7}"
  dir="$botdir/${WABOX_SEND_DIR:-send}/.sent"
  if [[ "$days" != 0 && -d "$dir" ]]; then
    find -P "$dir" -mindepth 1 -maxdepth 1 -type d -mtime +"$days" 2>/dev/null
  fi

  # Dangling legacy compat symlinks: their target under .wabox/ is gone, so the
  # link is pure cruft. A still-live link (target present) is left alone this
  # release — habit and in-flight jobs may still resolve through it.
  for legacy in wabox-send wabox-media; do
    if [[ -L "$wd/$legacy" && ! -e "$wd/$legacy" ]]; then
      printf '%s\n' "$wd/$legacy"
    fi
  done
}

# Echo (one per line) reclaimable audit files in PROCESSED_DIR: each envelope
# older than the cutoff plus the media file it references. This is a global dir
# (not conversation-scoped), so it's pruned once per all-scope run, no lock.
_gc_candidates_processed() {
  local days="${WABOX_PROCESSED_KEEP_DAYS:-90}" json media
  [[ "$days" != 0 ]] || return 0
  [[ -d "$PROCESSED_DIR" ]] || return 0
  while IFS= read -r json; do
    [[ -n "$json" ]] || continue
    printf '%s\n' "$json"
    media="$(jq -r '.media.file // empty' <"$json" 2>/dev/null || true)"
    if [[ -n "$media" && -e "$PROCESSED_DIR/$media" ]]; then
      printf '%s\n' "$PROCESSED_DIR/$media"
    fi
  done < <(find -P "$PROCESSED_DIR" -mindepth 1 -maxdepth 1 -name '*.json' -type f -mtime +"$days" 2>/dev/null)
}

gc_main() {
  _GC_PATHS=()
  _GC_BYTES=0

  local slug="" apply=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes | -y) apply=1; shift ;;
      -*)
        printf 'wabox-bot gc: unknown option: %s\n' "$1" >&2
        return 1
        ;;
      *)
        if [[ -n "$slug" ]]; then
          printf 'wabox-bot gc: unexpected argument: %s\n' "$1" >&2
          return 1
        fi
        slug="$1"; shift
        ;;
    esac
  done

  local -a slugs=()
  if [[ -n "$slug" ]]; then
    if [[ ! -d "$SESSIONS_DIR/$slug" ]]; then
      printf 'wabox-bot gc: unknown conversation slug: %s\n' "$slug" >&2
      return 1
    fi
    slugs=("$slug")
  else
    local d
    for d in "$SESSIONS_DIR"/*/; do
      [[ -d "$d" ]] || continue
      slugs+=("$(basename -- "$d")")
    done
  fi

  # Per conversation, hold its lock non-blocking so we never wait on or race an
  # in-flight turn; a busy conversation is skipped with a notice (run stays 0).
  local s fd
  for s in "${slugs[@]}"; do
    exec {fd}>"$LOCKS_DIR/$s.lock"
    if ! flock -n "$fd"; then
      printf 'gc: skipping %s (busy)\n' "$s" >&2
      exec {fd}>&-
      continue
    fi
    _gc_consume "$apply" < <(_gc_candidates_conversation "$s")
    exec {fd}>&-
  done

  # PROCESSED_DIR is global; prune it once, only in the all-scope run. A single
  # slug's gc leaves the shared audit trail alone (a cron `wabox-bot gc` owns it).
  if [[ -z "$slug" ]]; then
    _gc_consume "$apply" < <(_gc_candidates_processed)
  fi

  if ((${#_GC_PATHS[@]} == 0)); then
    printf 'gc: nothing to reclaim.\n'
    return 0
  fi

  printf '%s\n' "${_GC_PATHS[@]}"
  local human
  human="$(human_bytes "$_GC_BYTES")"
  if ((apply)); then
    printf 'gc: reclaimed %s across %d item(s).\n' "$human" "${#_GC_PATHS[@]}"
  else
    printf 'gc: %d item(s), %s reclaimable. Run with --yes to apply.\n' \
      "${#_GC_PATHS[@]}" "$human"
  fi
  return 0
}
