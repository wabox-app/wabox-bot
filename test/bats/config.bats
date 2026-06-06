load test_helper

setup() { setup_lib; }
teardown() { teardown_lib; }

@test "config file values are applied when WABOX_BOT_CONFIG points at it" {
  cat >"$TMPDIR_TEST/cfg" <<'EOF'
KEEP_PROCESSED="${KEEP_PROCESSED:-0}"
CLAUDE_TIMEOUT="${CLAUDE_TIMEOUT:-42}"
EOF
  export WABOX_BOT_CONFIG="$TMPDIR_TEST/cfg"
  load_core
  [ "$KEEP_PROCESSED" = "0" ]
  [ "$CLAUDE_TIMEOUT" = "42" ]
}

@test "environment overrides the config file (template :- form)" {
  cat >"$TMPDIR_TEST/cfg" <<'EOF'
KEEP_PROCESSED="${KEEP_PROCESSED:-0}"
EOF
  export WABOX_BOT_CONFIG="$TMPDIR_TEST/cfg"
  export KEEP_PROCESSED=9
  load_core
  [ "$KEEP_PROCESSED" = "9" ]
}

@test "config file values are exported to child processes" {
  cat >"$TMPDIR_TEST/cfg" <<'EOF'
WABOX_FW_MODEL="${WABOX_FW_MODEL:-small}"
EOF
  export WABOX_BOT_CONFIG="$TMPDIR_TEST/cfg"
  load_core
  run bash -c 'printf %s "${WABOX_FW_MODEL:-MISSING}"'
  [ "$output" = "small" ]
}

@test "a missing config path is silently ignored (defaults apply)" {
  export WABOX_BOT_CONFIG="$TMPDIR_TEST/nope"
  load_core
  [ "$KEEP_PROCESSED" = "1" ]
}

@test "config.example sources cleanly and yields the documented defaults" {
  ( set -euo pipefail
    # shellcheck disable=SC1091
    source "$REPO_ROOT/config.example"
    [ "$WABOX_BOT_BACKEND" = "claude-code" ]
    [ "$CLAUDE_TIMEOUT" = "180" ]
    [ "$WABOX_TRANSCRIBE_TIMEOUT" = "120" ]
    [ "$KEEP_PROCESSED" = "1" ]
  )
}

@test "--init-config writes config.example to the target and refuses to overwrite" {
  target="$TMPDIR_TEST/conf/config"
  WABOX_BOT_CONFIG="$target" run "$REPO_ROOT/bin/wabox-bot" --init-config
  [ "$status" -eq 0 ]
  [ -f "$target" ]
  diff "$target" "$REPO_ROOT/config.example"
  # second run must refuse, leaving the file untouched
  WABOX_BOT_CONFIG="$target" run "$REPO_ROOT/bin/wabox-bot" --init-config
  [ "$status" -ne 0 ]
}

@test "--config naming a missing file is an error" {
  run "$REPO_ROOT/bin/wabox-bot" --config "$TMPDIR_TEST/absent"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}
