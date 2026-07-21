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
  # Isolate from the developer's real ~/.config/wabox-bot/config: without this,
  # load_core → config.sh would source it and inherit whatever knobs it sets
  # (e.g. WABOX_ACK_REACT), breaking tests that assume stock defaults. Point at
  # a guaranteed-absent path; config.sh only sources an existing file. Tests
  # that want a config (config.bats) export their own after calling setup_lib.
  export WABOX_BOT_CONFIG="$TMPDIR_TEST/no-config"
  # Disable the message-batching debounce by default so handle_envelope drains
  # synchronously and the suite doesn't sleep the window on every envelope.
  # batch.bats overrides this to exercise the real window.
  export WABOX_BATCH_WINDOW=0
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
  # shellcheck source=lib/version.sh
  source "$LIB_DIR/version.sh"
  # shellcheck source=lib/update.sh
  source "$LIB_DIR/update.sh"
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
  # shellcheck source=lib/lastmsg.sh
  source "$LIB_DIR/lastmsg.sh"
  # shellcheck source=lib/workdir.sh
  source "$LIB_DIR/workdir.sh"
  # shellcheck source=lib/senddir.sh
  source "$LIB_DIR/senddir.sh"
  # shellcheck source=lib/media.sh
  source "$LIB_DIR/media.sh"
  # shellcheck source=lib/backend.sh
  source "$LIB_DIR/backend.sh"
  # shellcheck source=lib/migrate.sh
  source "$LIB_DIR/migrate.sh"
  # shellcheck source=lib/commands.sh
  source "$LIB_DIR/commands.sh"
  # shellcheck source=lib/batch.sh
  source "$LIB_DIR/batch.sh"
}
