load test_helper

# The VERSION file is the single source of truth; lib/version.sh reads it and
# bin/wabox-bot --version prints it.

setup() {
  setup_lib
  # shellcheck source=lib/version.sh
  source "$LIB_DIR/version.sh"
}

teardown() {
  teardown_lib
}

@test "wabox_bot_version echoes the VERSION file contents (no trailing newline)" {
  expected="$(cat "$REPO_ROOT/VERSION")"
  run wabox_bot_version
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

@test "VERSION is a plausible semver string" {
  [[ "$(cat "$REPO_ROOT/VERSION")" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+].*)?$ ]]
}

@test "bin/wabox-bot --version prints 'wabox-bot <version>'" {
  run "$REPO_ROOT/bin/wabox-bot" --version
  [ "$status" -eq 0 ]
  [[ "$output" == "wabox-bot $(cat "$REPO_ROOT/VERSION")"* ]]
}

@test "-v is an alias for --version" {
  run "$REPO_ROOT/bin/wabox-bot" -v
  [ "$status" -eq 0 ]
  [[ "$output" == wabox-bot\ * ]]
}
