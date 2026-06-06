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
