# Timestamped, level-prefixed logging to both LOG_FILE and stderr.
#
# Depends on LOG_FILE being set by lib/config.sh. log_debug is a no-op
# unless DEBUG=1 in the environment.

log() {
  local level="$1"
  shift
  local line
  printf -v line '%s [%s] [pid=%d] %s' \
    "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$level" "$$" "$*"
  printf '%s\n' "$line" >>"$LOG_FILE"
  printf '%s\n' "$line" >&2
}
log_info() { log INFO "$@"; }
log_warn() { log WARN "$@"; }
log_error() { log ERROR "$@"; }
log_debug() {
  [[ "${DEBUG:-0}" == "1" ]] && log DEBUG "$@"
  return 0
}
