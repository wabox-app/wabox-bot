load test_helper

setup() {
  setup_lib
  export WABOX_BOT_BACKEND=echo
  CFG="$TMPDIR_TEST/config"
  export WABOX_BOT_CONFIG="$CFG"
  # shellcheck source=lib/config.sh
  source "$LIB_DIR/config.sh"
  # shellcheck source=lib/log.sh
  source "$LIB_DIR/log.sh"
  # shellcheck source=lib/configverb.sh
  source "$LIB_DIR/configverb.sh"
}

teardown() {
  teardown_lib
}

# Run the real binary (fresh process, so `get` re-reads the file after a `set`).
# stderr is discarded — the backend logs "backend = ..." at source time, and
# bats merges stderr into $output, which would corrupt value assertions.
wb() {
  run bash -c '
    export WABOX_BOT_BACKEND=echo WABOX_BOT_CONFIG="$1"
    bin="$2"; shift 2
    "$bin" config "$@" 2>/dev/null
  ' _ "$CFG" "$REPO_ROOT/bin/wabox-bot" "$@"
}

# ---- list ------------------------------------------------------------------

@test "list --json emits one object per registry var with the four fields" {
  run configverb_list_json
  [ "$status" -eq 0 ]
  [ "$(jq 'length' <<<"$output")" -eq "${#CONFIG_VARS[@]}" ]
  [ "$(jq -r '.[0] | has("var") and has("value") and has("secret") and has("set_in_file")' <<<"$output")" = "true" ]
}

@test "list masks secrets and flags them" {
  export WABOX_STT_API_KEY="sk-abc"
  run configverb_list_json
  local row
  row="$(jq -r '.[] | select(.var=="WABOX_STT_API_KEY")' <<<"$output")"
  [ "$(jq -r '.secret' <<<"$row")" = "true" ]
  [ "$(jq -r '.value' <<<"$row")" = "••••" ]
  [[ "$output" != *"sk-abc"* ]]
}

@test "list set_in_file reflects a non-comment assignment only" {
  printf 'WABOX_ACK_REACT=x\n# WABOX_SEND_DIR=send\n' >"$CFG"
  run configverb_list_json
  [ "$(jq -r '.[] | select(.var=="WABOX_ACK_REACT") | .set_in_file' <<<"$output")" = "true" ]
  # A commented line is a documented default, not an override.
  [ "$(jq -r '.[] | select(.var=="WABOX_SEND_DIR") | .set_in_file' <<<"$output")" = "false" ]
}

@test "list --json requires the --json flag" {
  run configverb_main list
  [ "$status" -eq 1 ]
}

# ---- get -------------------------------------------------------------------

@test "get prints a secret raw (no masking)" {
  export WABOX_STT_API_KEY="sk-visible"
  run configverb_get WABOX_STT_API_KEY
  [ "$status" -eq 0 ]
  [ "$output" = "sk-visible" ]
}

@test "get on an unknown var exits 1" {
  run configverb_get NOPE
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown var"* ]]
}

# ---- set -------------------------------------------------------------------

@test "set creates the config file from the template when absent" {
  [ ! -e "$CFG" ]
  run configverb_set WABOX_ACK_REACT "👀"
  [ "$status" -eq 0 ]
  [ -f "$CFG" ]
  grep -qE '^WABOX_ACK_REACT=' "$CFG"
}

@test "set replaces a template-form line with a plain assignment, preserving comments" {
  cat >"$CFG" <<'EOF'
# leading comment
WABOX_SEND_DIR="${WABOX_SEND_DIR:-send}"
KEEP_PROCESSED="${KEEP_PROCESSED:-1}"
EOF
  configverb_set WABOX_SEND_DIR "outbox"
  # Exactly one WABOX_SEND_DIR line, now a plain assignment.
  [ "$(grep -cE '^[[:space:]]*WABOX_SEND_DIR=' "$CFG")" -eq 1 ]
  grep -qxF 'WABOX_SEND_DIR=outbox' "$CFG"
  # Unrelated line and the comment survive.
  grep -qxF '# leading comment' "$CFG"
  grep -qE '^KEEP_PROCESSED=' "$CFG"
}

@test "set on an unknown var exits 1 and writes nothing" {
  run configverb_set NOPE value
  [ "$status" -eq 1 ]
  [ ! -e "$CFG" ]
}

@test "set warns when the var is exported in the environment with a different value" {
  : >"$CFG"
  export WABOX_ACK_REACT="fromenv"
  WABOX_CONFIG_PRE_ENV="WABOX_ACK_REACT "
  run configverb_set WABOX_ACK_REACT "fromfile"
  [ "$status" -eq 0 ]
  [[ "$output" == *"overrides the file"* ]]
}

@test "set does not warn when the var is not an environment override" {
  : >"$CFG"
  WABOX_CONFIG_PRE_ENV=" "
  run configverb_set WABOX_ACK_REACT "value"
  [[ "$output" != *"overrides the file"* ]]
}

# ---- unset -----------------------------------------------------------------

@test "unset deletes the assignment line" {
  printf 'WABOX_ACK_REACT=x\nKEEP_PROCESSED=1\n' >"$CFG"
  configverb_unset WABOX_ACK_REACT
  ! grep -qE '^[[:space:]]*WABOX_ACK_REACT=' "$CFG"
  grep -qE '^KEEP_PROCESSED=' "$CFG"
}

@test "unset is idempotent when the var is not in the file" {
  printf 'KEEP_PROCESSED=1\n' >"$CFG"
  run configverb_unset WABOX_ACK_REACT
  [ "$status" -eq 0 ]
  # File untouched.
  [ "$(cat "$CFG")" = "KEEP_PROCESSED=1" ]
}

@test "unset on a missing file exits 0" {
  run configverb_unset WABOX_ACK_REACT
  [ "$status" -eq 0 ]
}

@test "unset on an unknown var exits 1" {
  run configverb_unset NOPE
  [ "$status" -eq 1 ]
}

# ---- dispatch / round-trips through the binary -----------------------------

@test "unknown action exits 1 with usage" {
  run configverb_main frobnicate
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown action"* ]]
}

@test "set then get round-trips a value with spaces and quotes (fresh process)" {
  wb set CLAUDE_ARGS 'a "b c" d'
  [ "$status" -eq 0 ]
  wb get CLAUDE_ARGS
  [ "$status" -eq 0 ]
  [ "$output" = 'a "b c" d' ]
}

@test "set then get round-trips a value with a newline" {
  wb set WABOX_ACK_REACT $'line1\nline2'
  [ "$status" -eq 0 ]
  wb get WABOX_ACK_REACT
  [ "$status" -eq 0 ]
  [ "$output" = $'line1\nline2' ]
}

@test "unset then get returns the built-in default (fresh process)" {
  wb set WABOX_SEND_DIR "custom"
  wb get WABOX_SEND_DIR
  [ "$output" = "custom" ]
  wb unset WABOX_SEND_DIR
  wb get WABOX_SEND_DIR
  [ "$output" = "send" ]   # config.sh default
}

@test "--config <alt> before the config verb targets the alternate file" {
  alt="$TMPDIR_TEST/alt-config"
  WABOX_BOT_BACKEND=echo run "$REPO_ROOT/bin/wabox-bot" --config "$alt" config set WABOX_ACK_REACT "🔔"
  [ "$status" -eq 0 ]
  [ -f "$alt" ]
  grep -qE '^WABOX_ACK_REACT=' "$alt"
  # The default config path was not created.
  [ ! -e "$CFG" ]
}
