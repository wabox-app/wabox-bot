load test_helper

setup() {
  setup_lib
}

teardown() {
  teardown_lib
}

@test "claude-code backend defines required + optional contract functions" {
  WABOX_BOT_BACKEND=claude-code load_core
  for fn in backend_name backend_reply backend_handle_command \
            backend_clear backend_help backend_status_lines \
            backend_check_dependencies; do
    declare -f "$fn" >/dev/null || {
      echo "missing: $fn" >&2
      false
    }
  done
}

@test "bob backend defines required + optional contract functions" {
  WABOX_BOT_BACKEND=bob load_core
  for fn in backend_name backend_reply backend_handle_command \
            backend_clear backend_help backend_status_lines \
            backend_check_dependencies; do
    declare -f "$fn" >/dev/null || {
      echo "missing: $fn" >&2
      false
    }
  done
}

@test "bob backend identifies as bob" {
  WABOX_BOT_BACKEND=bob load_core
  [ "$(backend_name)" = "bob" ]
}

@test "echo backend defines only the minimum contract" {
  WABOX_BOT_BACKEND=echo load_core
  declare -f backend_name >/dev/null
  declare -f backend_reply >/dev/null
}

@test "claude-code backend identifies as claude-code" {
  WABOX_BOT_BACKEND=claude-code load_core
  [ "$(backend_name)" = "claude-code" ]
}

@test "echo backend identifies as echo" {
  WABOX_BOT_BACKEND=echo load_core
  [ "$(backend_name)" = "echo" ]
}

@test "missing backend file fails fast" {
  run env WABOX_BOT_BACKEND=does-not-exist bash -c '
    source "'"$LIB_DIR"'/config.sh"
    source "'"$LIB_DIR"'/log.sh"
    source "'"$LIB_DIR"'/backend.sh"
  '
  [ "$status" -ne 0 ]
  [[ "$output" == *"backend not found"* ]]
}

@test "backend_state_dir returns and creates a namespaced directory" {
  WABOX_BOT_BACKEND=claude-code load_core
  d="$(backend_state_dir "abc123")"
  [ "$d" = "$SESSIONS_DIR/abc123/claude-code" ]
  [ -d "$d" ]
}
