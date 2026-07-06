load test_helper

# Task 2: acquire_single_instance_lock records the daemon's PID in PID_LOCK so
# `wabox-bot state` can report it.

setup() {
  setup_lib
  # shellcheck source=lib/config.sh
  source "$LIB_DIR/config.sh"
  # shellcheck source=lib/log.sh
  source "$LIB_DIR/log.sh"
  # shellcheck source=lib/locks.sh
  source "$LIB_DIR/locks.sh"
}

teardown() {
  teardown_lib
}

@test "acquire_single_instance_lock writes the daemon PID into the lock file" {
  acquire_single_instance_lock
  [ "$(cat "$PID_LOCK")" = "$$" ]
}

@test "a stale PID in the lock file is replaced, not appended" {
  printf '99999\n' >"$PID_LOCK"
  acquire_single_instance_lock
  # exactly one line, holding our PID (the stale one is gone)
  [ "$(wc -l <"$PID_LOCK")" -eq 1 ]
  [ "$(cat "$PID_LOCK")" = "$$" ]
}
