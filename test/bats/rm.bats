load test_helper

setup() {
  setup_lib
  # shellcheck source=lib/config.sh
  source "$LIB_DIR/config.sh"
  # shellcheck source=lib/log.sh
  source "$LIB_DIR/log.sh"
  # shellcheck source=lib/workdir.sh
  source "$LIB_DIR/workdir.sh"
  # shellcheck source=lib/rm.sh
  source "$LIB_DIR/rm.sh"
}

teardown() {
  teardown_lib
}

@test "unknown slug exits 1" {
  run rm_main nope --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown conversation slug"* ]]
}

@test "missing slug argument exits 1 with usage" {
  run rm_main --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "a default-workdir conversation is deleted end to end" {
  slug=d1
  mkdir -p "$SESSIONS_DIR/$slug/claude-code"
  printf 'jid@s.whatsapp.net' >"$SESSIONS_DIR/$slug/conv_key"
  mkdir -p "$STATE_DIR/work/$slug/.wabox/media"
  printf 'x' >"$STATE_DIR/work/$slug/notes.md"

  run rm_main "$slug" --yes
  [ "$status" -eq 0 ]
  [ ! -e "$SESSIONS_DIR/$slug" ]
  [ ! -e "$STATE_DIR/work/$slug" ]
  [[ "$output" == *"and its workdir"* ]]
}

@test "a /cwd override target is preserved and its path reported" {
  slug=d2
  mkdir -p "$SESSIONS_DIR/$slug"
  printf 'jid@s.whatsapp.net' >"$SESSIONS_DIR/$slug/conv_key"
  user_dir="$TMPDIR_TEST/valter"
  mkdir -p "$user_dir"
  printf 'precious' >"$user_dir/keep.txt"
  printf '%s\n' "$user_dir" >"$SESSIONS_DIR/$slug/workdir"

  run rm_main "$slug" --yes
  [ "$status" -eq 0 ]
  [ ! -e "$SESSIONS_DIR/$slug" ]
  # The user's folder and contents are untouched.
  [ -f "$user_dir/keep.txt" ]
  [[ "$output" == *"left in place: $user_dir"* ]]
}

@test "a busy conversation exits 3" {
  slug=busy
  mkdir -p "$SESSIONS_DIR/$slug"
  printf 'jid@s.whatsapp.net' >"$SESSIONS_DIR/$slug/conv_key"

  ( exec 8>>"$LOCKS_DIR/$slug.lock"; flock 8; sleep 5 ) &
  holder=$!
  for _ in $(seq 1 50); do [[ -e "$LOCKS_DIR/$slug.lock" ]] && break; sleep 0.05; done

  ANSWER_LOCK_WAIT=1 run rm_main "$slug" --yes
  kill "$holder" 2>/dev/null || true
  [ "$status" -eq 3 ]
  # Nothing was deleted.
  [ -d "$SESSIONS_DIR/$slug" ]
}

@test "without --yes on a non-terminal it refuses (exit 1) and deletes nothing" {
  slug=d3
  mkdir -p "$SESSIONS_DIR/$slug"
  printf 'jid@s.whatsapp.net' >"$SESSIONS_DIR/$slug/conv_key"

  run rm_main "$slug" </dev/null
  [ "$status" -eq 1 ]
  [ -d "$SESSIONS_DIR/$slug" ]
}

@test "the rm subcommand dispatches through the binary" {
  slug=cli
  mkdir -p "$SESSIONS_DIR/$slug"
  printf 'jid@s.whatsapp.net' >"$SESSIONS_DIR/$slug/conv_key"
  WABOX_BOT_BACKEND=echo run "$REPO_ROOT/bin/wabox-bot" rm "$slug" --yes
  [ "$status" -eq 0 ]
  [ ! -e "$SESSIONS_DIR/$slug" ]
  # Usage error surfaces too.
  WABOX_BOT_BACKEND=echo run "$REPO_ROOT/bin/wabox-bot" rm
  [ "$status" -eq 1 ]
}

@test "after rm, resolving the same slug yields a fresh clean workdir" {
  slug=d4
  mkdir -p "$SESSIONS_DIR/$slug/claude-code"
  printf 'old-session' >"$SESSIONS_DIR/$slug/claude-code/session"
  mkdir -p "$STATE_DIR/work/$slug"
  printf 'old' >"$STATE_DIR/work/$slug/stale.txt"

  rm_main "$slug" --yes

  # As the next inbound envelope would: recreate the default workdir clean.
  run conversation_workdir "$slug"
  [ "$status" -eq 0 ]
  [ "$output" = "$STATE_DIR/work/$slug" ]
  [ -d "$STATE_DIR/work/$slug" ]
  [ ! -e "$STATE_DIR/work/$slug/stale.txt" ]
  [ ! -e "$SESSIONS_DIR/$slug/claude-code/session" ]
}
