# Common bats setup.
#
# Provides setup_lib / teardown_lib for tempdir isolation and load_core for
# sourcing the production lib files into the test shell. Tests that need
# the main loop (run_main_loop) should invoke bin/wabox-bot as a subprocess
# rather than calling load_core — load_core stops short of installing
# signal handlers or acquiring the single-instance lock.

setup_lib() {
  TMPDIR_TEST="$(mktemp -d)"
  export WABOX_INBOX="$TMPDIR_TEST/in"
  export WABOX_OUTBOX="$TMPDIR_TEST/out"
  export STATE_DIR="$TMPDIR_TEST/state"
  export LOG_FILE="$TMPDIR_TEST/log"
  mkdir -p "$WABOX_INBOX" "$WABOX_OUTBOX"

  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  LIB_DIR="$REPO_ROOT/lib"
  export LIB_DIR
}

teardown_lib() {
  rm -rf "$TMPDIR_TEST"
}

# Source the production core into the test shell. Honors $WABOX_BOT_BACKEND
# so individual tests can pick which backend to load.
load_core() {
  # shellcheck source=lib/config.sh
  source "$LIB_DIR/config.sh"
  # shellcheck source=lib/log.sh
  source "$LIB_DIR/log.sh"
  # shellcheck source=lib/locks.sh
  source "$LIB_DIR/locks.sh"
  # shellcheck source=lib/routing.sh
  source "$LIB_DIR/routing.sh"
  # shellcheck source=lib/outbox.sh
  source "$LIB_DIR/outbox.sh"
  # shellcheck source=lib/backend.sh
  source "$LIB_DIR/backend.sh"
  # shellcheck source=lib/migrate.sh
  source "$LIB_DIR/migrate.sh"
  # shellcheck source=lib/commands.sh
  source "$LIB_DIR/commands.sh"
}
