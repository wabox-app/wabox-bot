# Path defaults, environment variable resolution, dependency checks.
#
# Sourced before lib/log.sh, so this file cannot use the log_* helpers
# directly. need() references log_error, but that's only invoked from
# check_dependencies(), which the entrypoint calls *after* lib/log.sh has
# been sourced.

# Try to pick up the user's actual wabox paths from `wabox status --json`
# (falls back to platform defaults if wabox isn't on PATH).
default_paths_from_wabox() {
  if command -v wabox >/dev/null 2>&1; then
    local out
    if out="$(wabox status --json 2>/dev/null)"; then
      WABOX_INBOX_DEFAULT="$(jq -r '.inbox // empty' <<<"$out" 2>/dev/null || true)"
      WABOX_OUTBOX_DEFAULT="$(jq -r '.outbox // empty' <<<"$out" 2>/dev/null || true)"
    fi
  fi
  : "${WABOX_INBOX_DEFAULT:=${XDG_DATA_HOME:-$HOME/.local/share}/wabox/inbox}"
  : "${WABOX_OUTBOX_DEFAULT:=${XDG_DATA_HOME:-$HOME/.local/share}/wabox/outbox}"
}
default_paths_from_wabox

WABOX_INBOX="${WABOX_INBOX:-$WABOX_INBOX_DEFAULT}"
WABOX_OUTBOX="${WABOX_OUTBOX:-$WABOX_OUTBOX_DEFAULT}"
STATE_DIR="${STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/wabox-bot}"
SESSIONS_DIR="$STATE_DIR/sessions"
LOCKS_DIR="$STATE_DIR/locks"
# Default to a `processed/` sibling inside the inbox so the audit trail lives
# right next to the inbound files. inotifywait is non-recursive, so dropping
# files into this subdir won't retrigger the watcher.
PROCESSED_DIR="${PROCESSED_DIR:-$WABOX_INBOX/processed}"
LOG_FILE="${LOG_FILE:-$STATE_DIR/agent.log}"
PID_LOCK="$STATE_DIR/wabox-bot.lock"

GROUP_PER_PARTICIPANT="${GROUP_PER_PARTICIPANT:-0}"
IGNORE_FROM_ME="${IGNORE_FROM_ME:-1}"
KEEP_PROCESSED="${KEEP_PROCESSED:-1}"

mkdir -p "$STATE_DIR" "$SESSIONS_DIR" "$LOCKS_DIR" "$PROCESSED_DIR" \
  "$(dirname "$LOG_FILE")" "$WABOX_OUTBOX"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    log_error "missing required command: $1"
    exit 1
  }
}

check_dependencies() {
  need inotifywait
  need jq
  need flock
  need timeout
}
