setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

# A plugin must be a self-contained, runnable entrypoint plus a README.
assert_plugin() {
  local dir="$REPO_ROOT/plugins/$1"
  [ -f "$dir/transcribe.sh" ]
  [ -x "$dir/transcribe.sh" ]
  head -1 "$dir/transcribe.sh" | grep -q '^#!'
  bash -n "$dir/transcribe.sh"
  [ -f "$dir/README.md" ]
}

@test "plugin faster-whisper has a runnable transcribe.sh and a README" {
  assert_plugin faster-whisper
}

@test "plugin whisper-cpp has a runnable transcribe.sh and a README" {
  assert_plugin whisper-cpp
}

@test "plugin openai-whisper has a runnable transcribe.sh and a README" {
  assert_plugin openai-whisper
}

@test "plugin vosk has a runnable transcribe.sh and a README" {
  assert_plugin vosk
}

@test "plugin openai-compatible has a runnable transcribe.sh and a README" {
  assert_plugin openai-compatible
}
