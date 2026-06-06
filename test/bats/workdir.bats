load test_helper

setup() {
  setup_lib
  load_core
}

teardown() {
  teardown_lib
}

@test "conversation_dir is the per-conversation root under SESSIONS_DIR" {
  run conversation_dir abc123
  [ "$status" -eq 0 ]
  [ "$output" = "$STATE_DIR/sessions/abc123" ]
}

@test "conversation_workdir defaults to per-slug folder and creates it" {
  run conversation_workdir abc123
  [ "$status" -eq 0 ]
  [ "$output" = "$STATE_DIR/work/abc123" ]
  [ -d "$STATE_DIR/work/abc123" ]
}

@test "conversation_workdir honors an override file" {
  mkdir -p "$SESSIONS_DIR/abc123" "$TMPDIR_TEST/custom"
  printf '%s\n' "$TMPDIR_TEST/custom" >"$SESSIONS_DIR/abc123/workdir"
  run conversation_workdir abc123
  [ "$status" -eq 0 ]
  [ "$output" = "$TMPDIR_TEST/custom" ]
}

@test "expand_tilde expands a leading ~/ to HOME" {
  run expand_tilde "~/Valter"
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/Valter" ]
}

@test "expand_tilde expands a bare ~ to HOME" {
  run expand_tilde "~"
  [ "$output" = "$HOME" ]
}

@test "expand_tilde leaves an absolute path unchanged" {
  run expand_tilde "/srv/data"
  [ "$output" = "/srv/data" ]
}

@test "workdir_display labels the default and does not create the dir" {
  run workdir_display abc123
  [ "$output" = "$STATE_DIR/work/abc123 (default)" ]
  [ ! -d "$STATE_DIR/work/abc123" ]
}

@test "workdir_display labels an override" {
  mkdir -p "$SESSIONS_DIR/abc123"
  printf '%s\n' "/srv/data" >"$SESSIONS_DIR/abc123/workdir"
  run workdir_display abc123
  [ "$output" = "/srv/data (override)" ]
}
