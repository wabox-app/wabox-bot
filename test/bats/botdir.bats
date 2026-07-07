load test_helper

setup() {
  setup_lib
  load_core
  WD="$TMPDIR_TEST/wd"
  mkdir -p "$WD"
}

teardown() {
  teardown_lib
}

@test "workdir_botdir creates .wabox/ and prints its path" {
  run workdir_botdir "$WD"
  [ "$status" -eq 0 ]
  [ "$output" = "$WD/.wabox" ]
  [ -d "$WD/.wabox" ]
}

@test "workdir_botdir_path is pure — no directory is created" {
  run workdir_botdir_path "$WD"
  [ "$output" = "$WD/.wabox" ]
  [ ! -e "$WD/.wabox" ]
}

@test "staged media lands under .wabox/media" {
  src="$TMPDIR_TEST/pic.jpg"
  printf 'x' >"$src"
  run media_stage "$src" "$WD"
  [ "$output" = ".wabox/media/pic.jpg" ]
  [ -f "$WD/.wabox/media/pic.jpg" ]
}

@test "senddir_path resolves under .wabox/send" {
  run senddir_path "$WD"
  [ "$output" = "$WD/.wabox/send" ]
}

@test "legacy wabox-send/ migrates into .wabox/send with a working compat symlink" {
  mkdir -p "$WD/wabox-send"
  printf 'old' >"$WD/wabox-send/report.pdf"
  workdir_botdir "$WD" >/dev/null
  # Moved into place.
  [ -f "$WD/.wabox/send/report.pdf" ]
  # A relative compat symlink remains at the old name and still resolves.
  [ -L "$WD/wabox-send" ]
  [ "$(readlink "$WD/wabox-send")" = ".wabox/send" ]
  [ -f "$WD/wabox-send/report.pdf" ]
}

@test "legacy wabox-media/ migrates into .wabox/media" {
  mkdir -p "$WD/wabox-media"
  printf 'old' >"$WD/wabox-media/a.ogg"
  workdir_botdir "$WD" >/dev/null
  [ -f "$WD/.wabox/media/a.ogg" ]
  [ -L "$WD/wabox-media" ]
}

@test "migration is idempotent and leaves an existing destination untouched" {
  mkdir -p "$WD/wabox-send"
  printf 'legacy' >"$WD/wabox-send/x.txt"
  # A new-layout file already exists ⇒ migration must not clobber it.
  mkdir -p "$WD/.wabox/send"
  printf 'new' >"$WD/.wabox/send/keep.txt"
  workdir_botdir "$WD" >/dev/null
  [ "$(cat "$WD/.wabox/send/keep.txt")" = "new" ]
  # The legacy dir is left as-is (not a symlink) because the destination existed.
  [ ! -L "$WD/wabox-send" ]
  [ -f "$WD/wabox-send/x.txt" ]
  # Re-resolving is a no-op.
  workdir_botdir "$WD" >/dev/null
  [ ! -L "$WD/wabox-send" ]
}

@test "dir_bytes is 0 for an absent dir and positive for a populated one" {
  [ "$(dir_bytes "$TMPDIR_TEST/nope")" = "0" ]
  printf 'abcdef' >"$WD/f"
  [ "$(dir_bytes "$WD")" -gt 0 ]
}

@test "human_bytes formats with pt-BR comma and trims trailing ,0" {
  [ "$(human_bytes 0)" = "0 B" ]
  [ "$(human_bytes 512)" = "512 B" ]
  [ "$(human_bytes 838860800)" = "800 MB" ]
  [ "$(human_bytes 1288490188)" = "1,2 GB" ]
}
