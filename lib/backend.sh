# Backend resolution + contract validation.
#
# Selection precedence: --backend CLI flag > WABOX_BOT_BACKEND env > "claude-code".
# The chosen name maps to lib/backends/<name>.sh (or
# $WABOX_BOT_BACKEND_DIR/<name>.sh if that override is set).
#
# Required contract:
#   backend_name   — echoes the short id (matches the filename stem)
#   backend_reply  — stdin=user text, stdout=reply text; exit 0/124/other
#
# Optional hooks (looked up lazily by the dispatcher and friends):
#   backend_handle_command    — slash command handler, returns 99 to pass
#   backend_clear             — wipes backend-owned state on /clear
#   backend_check_dependencies — extra dep checks (e.g. claude on PATH)
#   backend_help              — additional lines for /help
#   backend_status_lines      — additional lines for /status

: "${WABOX_BOT_BACKEND_DIR:=$LIB_DIR/backends}"
: "${WABOX_BOT_BACKEND:=claude-code}"

BACKEND_FILE="$WABOX_BOT_BACKEND_DIR/${WABOX_BOT_BACKEND}.sh"
if [[ ! -f "$BACKEND_FILE" ]]; then
  log_error "backend not found: $WABOX_BOT_BACKEND (looked for $BACKEND_FILE)"
  exit 1
fi

# shellcheck source=backends/claude-code.sh
source "$BACKEND_FILE"

for _fn in backend_name backend_reply; do
  if ! declare -f "$_fn" >/dev/null; then
    log_error "backend $WABOX_BOT_BACKEND is missing required function: $_fn"
    exit 1
  fi
done
unset _fn

# Sanity-check that the backend identifies as the name we loaded — protects
# against typos and copy/paste errors when authoring a new backend.
_loaded_name="$(backend_name)"
if [[ "$_loaded_name" != "$WABOX_BOT_BACKEND" ]]; then
  log_warn "backend file $BACKEND_FILE reports name '$_loaded_name', expected '$WABOX_BOT_BACKEND'"
fi
unset _loaded_name

if declare -f backend_check_dependencies >/dev/null; then
  backend_check_dependencies
fi

log_info "backend = $(backend_name)"
