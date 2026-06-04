# Backend dispatcher.
#
# Sources the active backend file from lib/backends/ and validates that it
# exposes the minimum contract (backend_name + backend_reply). Optional
# hooks (backend_handle_command, backend_clear, backend_help,
# backend_status_lines) are looked up lazily by the caller.
#
# This file deliberately knows about exactly one backend in B2 — the
# pluggable selection logic arrives in the next commit.

# shellcheck source=backends/claude-code.sh
source "$LIB_DIR/backends/claude-code.sh"

for _fn in backend_name backend_reply; do
  if ! declare -f "$_fn" >/dev/null; then
    log_error "backend is missing required function: $_fn"
    exit 1
  fi
done
unset _fn

log_info "backend = $(backend_name)"
