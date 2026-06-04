# Idempotent migrations from the in-tree wabox-claude-code.sh layout.
#
# Old layout (flat, single-backend):
#   $SESSIONS_DIR/<slug>.session
#   $SESSIONS_DIR/<slug>.model
#   $SESSIONS_DIR/<slug>.mode
#   $SESSIONS_DIR/<slug>.system
#   $STATE_DIR/agent.lock           (stale PID lock from old daemon name)
#
# New layout (namespaced by backend):
#   $SESSIONS_DIR/<slug>/<backend>/session
#   $SESSIONS_DIR/<slug>/<backend>/model
#   $SESSIONS_DIR/<slug>/<backend>/mode
#   $SESSIONS_DIR/<slug>/<backend>/system
#   $STATE_DIR/wabox-bot.lock
#
# The top-level $STATE_DIR rename (~/.local/state/wabox-claude →
# ~/.local/state/wabox-bot) happens in lib/config.sh before mkdir runs, so
# this file only handles within-STATE_DIR migrations.

# Flat session/model/mode/system files were only ever written by
# wabox-claude-code.sh, so they all belong under the "claude-code" backend
# subdir. Only run the migration when the active backend is claude-code —
# if a user is starting fresh on a different backend, leaving the legacy
# files in place is the right thing (next run with --backend claude-code
# picks them up).
migrate_flat_sessions() {
  [[ "$(backend_name)" == "claude-code" ]] || return 0
  local moved=0 f base slug suffix dest
  shopt -s nullglob
  for f in "$SESSIONS_DIR"/*.session \
           "$SESSIONS_DIR"/*.model \
           "$SESSIONS_DIR"/*.mode \
           "$SESSIONS_DIR"/*.system; do
    [[ -f "$f" ]] || continue
    base="$(basename "$f")"
    slug="${base%.*}"
    suffix="${base##*.}"
    dest="$SESSIONS_DIR/$slug/claude-code"
    mkdir -p "$dest"
    mv "$f" "$dest/$suffix"
    moved=$((moved + 1))
  done
  if ((moved > 0)); then
    log_info "migrate: moved $moved legacy flat session files into <slug>/claude-code/"
  fi
}

# Pre-rename leftovers: the old PID lock was $STATE_DIR/agent.lock. After
# the top-level dir rename in config.sh it sits as a stale file under the
# new STATE_DIR. The new daemon uses $STATE_DIR/wabox-bot.lock so the old
# file is harmless, but removing it keeps the dir tidy.
migrate_stale_pid_lock() {
  if [[ -f "$STATE_DIR/agent.lock" ]]; then
    rm -f "$STATE_DIR/agent.lock"
    log_info "migrate: removed stale agent.lock"
  fi
}

run_migrations() {
  migrate_stale_pid_lock
  migrate_flat_sessions
}
