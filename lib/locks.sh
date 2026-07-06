# Single-instance flock + shutdown / child-reaping helpers.
#
# Two daemons fighting over the same inbox is a recipe for races on the
# read-receipt move, the session file, and the outbox writer. The
# single-instance lock taken via fd 9 prevents that. Per-conversation locks
# live elsewhere — they're cheap files under $LOCKS_DIR, taken via fd 8 by
# inbox.sh.

SHUTTING_DOWN=0
INOTIFY_PID=""
declare -A CHILDREN=()

acquire_single_instance_lock() {
  # Append-open (not truncate-open) so merely *attempting* to start a second
  # daemon can't wipe the running daemon's PID out of the lock file before
  # flock even reports the conflict.
  exec 9>>"$PID_LOCK"
  if ! flock -n 9; then
    log_error "another wabox-bot agent is already running (lock: $PID_LOCK)"
    exit 1
  fi
  # We own the lock now. Record our PID so `wabox-bot state` can report it —
  # truncate first (the file may carry a stale PID from a crashed run), then
  # write. fd 9 is in append mode, so the write lands at offset 0 after the
  # truncate. flock keeps fd 9 open for our whole lifetime.
  : >"$PID_LOCK"
  printf '%s\n' "$$" >&9
}

reap_children() {
  local pid
  for pid in "${!CHILDREN[@]}"; do
    kill -0 "$pid" 2>/dev/null || unset 'CHILDREN[$pid]'
  done
}

shutdown() {
  [[ "$SHUTTING_DOWN" == "1" ]] && return
  SHUTTING_DOWN=1
  log_info "shutdown requested — draining in-flight handlers"

  if [[ -n "$INOTIFY_PID" ]] && kill -0 "$INOTIFY_PID" 2>/dev/null; then
    kill "$INOTIFY_PID" 2>/dev/null || true
  fi

  # Give handlers up to SHUTDOWN_DRAIN_TIMEOUT + 10s to finish gracefully,
  # then SIGTERM.
  local deadline=$(($(date +%s) + SHUTDOWN_DRAIN_TIMEOUT + 10))
  while ((${#CHILDREN[@]} > 0)); do
    reap_children
    ((${#CHILDREN[@]} == 0)) && break
    if (($(date +%s) >= deadline)); then
      log_warn "deadline reached; sending SIGTERM to ${#CHILDREN[@]} handler(s)"
      for pid in "${!CHILDREN[@]}"; do kill "$pid" 2>/dev/null || true; done
      sleep 1
      for pid in "${!CHILDREN[@]}"; do kill -9 "$pid" 2>/dev/null || true; done
      break
    fi
    sleep 0.2
  done

  log_info "bye"
  exit 0
}

install_signal_handlers() {
  trap shutdown INT TERM HUP
}
