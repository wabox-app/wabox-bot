load test_helper

setup() {
  setup_lib
  # shellcheck source=lib/config.sh
  source "$LIB_DIR/config.sh"
  # shellcheck source=lib/log.sh
  source "$LIB_DIR/log.sh"
  # shellcheck source=lib/senddir.sh
  source "$LIB_DIR/senddir.sh"
  WORKDIR="$TMPDIR_TEST/wd"
  mkdir -p "$WORKDIR"
  SEND="$WORKDIR/wabox-send"
}

teardown() {
  teardown_lib
}

@test "senddir_prepare creates the send folder when absent" {
  senddir_prepare "$WORKDIR" "stem1"
  [ -d "$SEND" ]
}

@test "senddir_prepare archives leftovers into .sent/<stem>/" {
  mkdir -p "$SEND"
  printf 'x' >"$SEND/old.pdf"
  senddir_prepare "$WORKDIR" "stemA"
  [ ! -e "$SEND/old.pdf" ]
  [ -f "$SEND/.sent/stemA/old.pdf" ]
}

@test "senddir_prepare on an empty folder is a no-op (no .sent created)" {
  mkdir -p "$SEND"
  senddir_prepare "$WORKDIR" "stemB"
  [ ! -e "$SEND/.sent" ]
}

@test "senddir_prepare never re-archives the .sent dir itself" {
  mkdir -p "$SEND/.sent/prev"
  printf 'x' >"$SEND/.sent/prev/keep.txt"
  senddir_prepare "$WORKDIR" "stemC"
  [ -f "$SEND/.sent/prev/keep.txt" ]
  [ ! -e "$SEND/.sent/stemC" ]
}

@test "senddir_collect prints absolute paths sorted by name" {
  mkdir -p "$SEND"
  printf 'x' >"$SEND/b.txt"
  printf 'x' >"$SEND/a.txt"
  run senddir_collect "$WORKDIR"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$SEND/a.txt" ]
  [ "${lines[1]}" = "$SEND/b.txt" ]
}

@test "senddir_collect skips dot-files and the .sent dir" {
  mkdir -p "$SEND/.sent/prev"
  printf 'x' >"$SEND/.sent/prev/archived.txt"
  printf 'x' >"$SEND/.hidden"
  printf 'x' >"$SEND/visible.txt"
  run senddir_collect "$WORKDIR"
  [ "$status" -eq 0 ]
  [ "$output" = "$SEND/visible.txt" ]
}

@test "senddir_collect is empty when the folder has no files" {
  mkdir -p "$SEND"
  run senddir_collect "$WORKDIR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "senddir_collect is empty when the folder does not exist" {
  run senddir_collect "$WORKDIR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "senddir_prune deletes archives older than the cutoff, keeps fresh ones" {
  export WABOX_SEND_KEEP_DAYS=7
  mkdir -p "$SEND/.sent/old" "$SEND/.sent/new"
  touch -d '30 days ago' "$SEND/.sent/old"
  senddir_prune "$WORKDIR"
  [ ! -e "$SEND/.sent/old" ]
  [ -d "$SEND/.sent/new" ]
}

@test "senddir_prune never touches live files or anything outside .sent" {
  mkdir -p "$SEND"
  printf 'x' >"$SEND/live.pdf"
  touch -d '30 days ago' "$SEND/live.pdf"
  senddir_prune "$WORKDIR"
  [ -f "$SEND/live.pdf" ]
}
