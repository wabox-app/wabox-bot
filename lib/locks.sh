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
  exec 9>"$PID_LOCK"
  if ! flock -n 9; then
    log_error "another wabox-bot agent is already running (lock: $PID_LOCK)"
    exit 1
  fi
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

  # Give handlers up to CLAUDE_TIMEOUT + 10s to finish gracefully, then SIGTERM
  local deadline=$(($(date +%s) + CLAUDE_TIMEOUT + 10))
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
