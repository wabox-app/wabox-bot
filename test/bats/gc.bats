load test_helper

setup() {
  setup_lib
  # shellcheck source=lib/config.sh
  source "$LIB_DIR/config.sh"
  # shellcheck source=lib/log.sh
  source "$LIB_DIR/log.sh"
  # shellcheck source=lib/workdir.sh
  source "$LIB_DIR/workdir.sh"
  # shellcheck source=lib/gc.sh
  source "$LIB_DIR/gc.sh"
}

teardown() {
  teardown_lib
}

# Register a conversation slug (so gc considers it) and return its default workdir.
mk_conv() {
  local slug="$1"
  mkdir -p "$SESSIONS_DIR/$slug"
  printf '%s' "$STATE_DIR/work/$slug"
}

@test "unknown slug exits 1" {
  run gc_main nope
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown conversation slug"* ]]
}

@test "dry-run lists old media but deletes nothing" {
  wd="$(mk_conv c1)"
  mkdir -p "$wd/.wabox/media"
  printf 'x' >"$wd/.wabox/media/old.jpg"
  touch -d '40 days ago' "$wd/.wabox/media/old.jpg"

  run gc_main c1
  [ "$status" -eq 0 ]
  [[ "$output" == *"old.jpg"* ]]
  [[ "$output" == *"Run with --yes to apply"* ]]
  [ -f "$wd/.wabox/media/old.jpg" ]
}

@test "--yes prunes media past WABOX_MEDIA_KEEP_DAYS but keeps fresh files" {
  wd="$(mk_conv c2)"
  mkdir -p "$wd/.wabox/media"
  printf 'x' >"$wd/.wabox/media/old.jpg"
  printf 'x' >"$wd/.wabox/media/new.jpg"
  touch -d '40 days ago' "$wd/.wabox/media/old.jpg"

  run gc_main c2 --yes
  [ "$status" -eq 0 ]
  [ ! -e "$wd/.wabox/media/old.jpg" ]
  [ -f "$wd/.wabox/media/new.jpg" ]
  [[ "$output" == *"reclaimed"* ]]
}

@test "agent files at the workdir root are never touched" {
  wd="$(mk_conv c3)"
  mkdir -p "$wd/.wabox/media"
  printf 'x' >"$wd/.wabox/media/old.jpg"
  touch -d '40 days ago' "$wd/.wabox/media/old.jpg"
  # Old agent-authored content at the root — must survive even though it's old.
  printf 'memories' >"$wd/MEMORY.md"
  printf 'notes' >"$wd/report.txt"
  touch -d '40 days ago' "$wd/MEMORY.md" "$wd/report.txt"

  run gc_main c3 --yes
  [ -f "$wd/MEMORY.md" ]
  [ -f "$wd/report.txt" ]
  [ ! -e "$wd/.wabox/media/old.jpg" ]
}

@test "WABOX_MEDIA_KEEP_DAYS=0 disables media pruning" {
  wd="$(mk_conv c4)"
  mkdir -p "$wd/.wabox/media"
  printf 'x' >"$wd/.wabox/media/old.jpg"
  touch -d '400 days ago' "$wd/.wabox/media/old.jpg"

  WABOX_MEDIA_KEEP_DAYS=0 run gc_main c4 --yes
  [ -f "$wd/.wabox/media/old.jpg" ]
}

@test "old send archives are pruned, live send files are not" {
  wd="$(mk_conv c5)"
  mkdir -p "$wd/.wabox/send/.sent/old" "$wd/.wabox/send/.sent/new"
  touch -d '30 days ago' "$wd/.wabox/send/.sent/old"
  printf 'live' >"$wd/.wabox/send/live.pdf"
  touch -d '30 days ago' "$wd/.wabox/send/live.pdf"

  run gc_main c5 --yes
  [ ! -e "$wd/.wabox/send/.sent/old" ]
  [ -d "$wd/.wabox/send/.sent/new" ]
  [ -f "$wd/.wabox/send/live.pdf" ]
}

@test "a busy conversation is skipped and the run still succeeds" {
  wd="$(mk_conv busy)"
  mkdir -p "$wd/.wabox/media"
  printf 'x' >"$wd/.wabox/media/old.jpg"
  touch -d '40 days ago' "$wd/.wabox/media/old.jpg"

  ( exec 8>>"$LOCKS_DIR/busy.lock"; flock 8; sleep 5 ) &
  holder=$!
  for _ in $(seq 1 50); do [[ -e "$LOCKS_DIR/busy.lock" ]] && break; sleep 0.05; done

  run gc_main busy --yes
  kill "$holder" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping busy (busy)"* ]]
  # The lock was held, so nothing was pruned.
  [ -f "$wd/.wabox/media/old.jpg" ]
}

@test "processed envelope + its media are removed as a pair in the all-scope run" {
  mk_conv c6 >/dev/null
  printf '{"media":{"file":"doc.pdf"}}' >"$PROCESSED_DIR/e1.json"
  printf 'PDF' >"$PROCESSED_DIR/doc.pdf"
  touch -d '100 days ago' "$PROCESSED_DIR/e1.json" "$PROCESSED_DIR/doc.pdf"
  # A fresh envelope must survive.
  printf '{"media":null}' >"$PROCESSED_DIR/e2.json"

  run gc_main --yes
  [ "$status" -eq 0 ]
  [ ! -e "$PROCESSED_DIR/e1.json" ]
  [ ! -e "$PROCESSED_DIR/doc.pdf" ]
  [ -f "$PROCESSED_DIR/e2.json" ]
}

@test "a single-slug run leaves the global processed/ audit trail alone" {
  mk_conv c7 >/dev/null
  printf '{"media":null}' >"$PROCESSED_DIR/old.json"
  touch -d '200 days ago' "$PROCESSED_DIR/old.json"

  run gc_main c7 --yes
  [ -f "$PROCESSED_DIR/old.json" ]
}

@test "WABOX_PROCESSED_KEEP_DAYS=0 keeps envelopes forever" {
  mk_conv c8 >/dev/null
  printf '{"media":null}' >"$PROCESSED_DIR/old.json"
  touch -d '400 days ago' "$PROCESSED_DIR/old.json"

  WABOX_PROCESSED_KEEP_DAYS=0 run gc_main --yes
  [ -f "$PROCESSED_DIR/old.json" ]
}

@test "a dangling legacy compat symlink is reclaimed" {
  wd="$(mk_conv c9)"
  mkdir -p "$wd"
  ln -s ".wabox/send" "$wd/wabox-send"   # target does not exist ⇒ dangling
  [ -L "$wd/wabox-send" ]
  [ ! -e "$wd/wabox-send" ]

  run gc_main c9 --yes
  [ ! -L "$wd/wabox-send" ]
}

@test "a live legacy compat symlink is left in place" {
  wd="$(mk_conv c10)"
  mkdir -p "$wd/.wabox/send"
  ln -s ".wabox/send" "$wd/wabox-send"   # target exists ⇒ still usable
  run gc_main c10 --yes
  [ -L "$wd/wabox-send" ]
}

@test "the gc subcommand dispatches through the binary" {
  mk_conv cli >/dev/null
  WABOX_BOT_BACKEND=echo run "$REPO_ROOT/bin/wabox-bot" gc
  [ "$status" -eq 0 ]
  WABOX_BOT_BACKEND=echo run "$REPO_ROOT/bin/wabox-bot" gc nope
  [ "$status" -eq 1 ]
}
