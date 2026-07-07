load test_helper

setup() {
  setup_lib
  WABOX_BOT_BACKEND=claude-code load_core
  JID="5511999999999@s.whatsapp.net"
  SLUG="$(printf '%s' "$JID" | sha1sum | awk '{print $1}')"
}

teardown() {
  teardown_lib
}

@test "/ping replies pong" {
  handle_slash_command "/ping" "$SLUG" "$JID" "$JID" "MSG1" "stem1"
  [ "$(jq -r '.text' "$WABOX_OUTBOX/stem1.json")" = "pong" ]
}

@test "/help aggregates core and backend lines" {
  handle_slash_command "/help" "$SLUG" "$JID" "$JID" "MSG" "help"
  text="$(jq -r '.text' "$WABOX_OUTBOX/help.json")"
  [[ "$text" == *"/clear"* ]]
  [[ "$text" == *"/ping"* ]]
  [[ "$text" == *"/status"* ]]
  [[ "$text" == *"/model"* ]]
  [[ "$text" == *"/mode"* ]]
  [[ "$text" == *"/system"* ]]
  [[ "$text" == *"/memory"* ]]
}

@test "/memory replies with the MEMORY.md content, monospace-wrapped" {
  wd="$STATE_DIR/work/$SLUG"
  mkdir -p "$wd"
  printf '* my wife is Ana\n* reports go out Fridays\n' >"$wd/MEMORY.md"
  handle_slash_command "/memory" "$SLUG" "$JID" "$JID" "MSG" "mem"
  text="$(jq -r '.text' "$WABOX_OUTBOX/mem.json")"
  [[ "$text" == '```'* ]]
  [[ "$text" == *'```' ]]
  [[ "$text" == *"my wife is Ana"* ]]
  [[ "$text" == *"reports go out Fridays"* ]]
}

@test "/memory reports no memory when absent" {
  handle_slash_command "/memory" "$SLUG" "$JID" "$JID" "MSG" "mem"
  [ "$(jq -r '.text' "$WABOX_OUTBOX/mem.json")" = "Sem memória ainda." ]
}

@test "/memory does not create the workdir when there is no memory" {
  handle_slash_command "/memory" "$SLUG" "$JID" "$JID" "MSG" "mem"
  [ ! -d "$STATE_DIR/work/$SLUG" ]
}

@test "/memory truncates an oversize MEMORY.md" {
  wd="$STATE_DIR/work/$SLUG"
  mkdir -p "$wd"
  head -c 4000 /dev/zero | tr '\0' 'x' >"$wd/MEMORY.md"
  handle_slash_command "/memory" "$SLUG" "$JID" "$JID" "MSG" "mem"
  text="$(jq -r '.text' "$WABOX_OUTBOX/mem.json")"
  [[ "$text" == *"arquivo completo em"* ]]
  [[ "$text" == *"$wd/MEMORY.md"* ]]
}

@test "/status reports the active backend and no session by default" {
  handle_slash_command "/status" "$SLUG" "$JID" "$JID" "MSG" "status"
  text="$(jq -r '.text' "$WABOX_OUTBOX/status.json")"
  [[ "$text" == *"backend: claude-code"* ]]
  [[ "$text" == *"session: (none"* ]]
}

@test "/clear delegates to backend_clear and drops the session file" {
  d="$(backend_state_dir "$SLUG")"
  echo "some-uuid" >"$d/session"
  handle_slash_command "/clear" "$SLUG" "$JID" "$JID" "MSG" "clear"
  [ ! -f "$d/session" ]
}

@test "/clear preserves the model preference" {
  d="$(backend_state_dir "$SLUG")"
  echo "haiku" >"$d/model"
  handle_slash_command "/clear" "$SLUG" "$JID" "$JID" "MSG" "clear"
  [ "$(cat "$d/model")" = "haiku" ]
}

@test "unknown command returns the canonical reply" {
  handle_slash_command "/nope" "$SLUG" "$JID" "$JID" "MSG" "stem"
  [ "$(jq -r '.text' "$WABOX_OUTBOX/stem.json")" = "Unknown command: /nope. Try /help." ]
}

@test "non-slash input returns 1 (caller should hand off to backend)" {
  run handle_slash_command "hello world" "$SLUG" "$JID" "$JID" "MSG" "stem"
  [ "$status" -eq 1 ]
}

@test "/model haiku persists the override into backend state dir" {
  handle_slash_command "/model haiku" "$SLUG" "$JID" "$JID" "MSG" "stem"
  [ "$(cat "$(backend_state_dir "$SLUG")/model")" = "haiku" ]
}

@test "/model default removes the override" {
  d="$(backend_state_dir "$SLUG")"
  echo "haiku" >"$d/model"
  handle_slash_command "/model default" "$SLUG" "$JID" "$JID" "MSG" "stem"
  [ ! -e "$d/model" ]
}

@test "/system <multi-line text> stores the prompt verbatim" {
  handle_slash_command "/system Be terse.
Always reply in one paragraph." "$SLUG" "$JID" "$JID" "MSG" "stem"
  d="$(backend_state_dir "$SLUG")"
  stored="$(cat "$d/system")"
  [[ "$stored" == "Be terse."* ]]
  [[ "$stored" == *"Always reply in one paragraph."* ]]
}

@test "/foo without backend match falls through to unknown" {
  handle_slash_command "/foo" "$SLUG" "$JID" "$JID" "MSG" "stem"
  [ "$(jq -r '.text' "$WABOX_OUTBOX/stem.json")" = "Unknown command: /foo. Try /help." ]
}

@test "/cwd with no override reports the auto default folder" {
  handle_slash_command "/cwd" "$SLUG" "$JID" "$JID" "MSG" "cwd1"
  text="$(jq -r '.text' "$WABOX_OUTBOX/cwd1.json")"
  [[ "$text" == *"work/$SLUG (default)"* ]]
}

@test "/cwd <existing dir> persists the expanded absolute path" {
  mkdir -p "$TMPDIR_TEST/proj"
  handle_slash_command "/cwd $TMPDIR_TEST/proj" "$SLUG" "$JID" "$JID" "MSG" "cwd2"
  [ "$(cat "$(conversation_dir "$SLUG")/workdir")" = "$TMPDIR_TEST/proj" ]
  text="$(jq -r '.text' "$WABOX_OUTBOX/cwd2.json")"
  [[ "$text" == *"set to: $TMPDIR_TEST/proj"* ]]
}

@test "/cwd expands a leading tilde before persisting" {
  mkdir -p "$HOME/wabox-bot-test-dir"
  handle_slash_command "/cwd ~/wabox-bot-test-dir" "$SLUG" "$JID" "$JID" "MSG" "cwd3"
  [ "$(cat "$(conversation_dir "$SLUG")/workdir")" = "$HOME/wabox-bot-test-dir" ]
  rmdir "$HOME/wabox-bot-test-dir"
}

@test "/cwd default removes the override" {
  mkdir -p "$(conversation_dir "$SLUG")"
  printf '%s\n' "/srv/data" >"$(conversation_dir "$SLUG")/workdir"
  handle_slash_command "/cwd default" "$SLUG" "$JID" "$JID" "MSG" "cwd4"
  [ ! -e "$(conversation_dir "$SLUG")/workdir" ]
}

@test "/cwd rejects a relative path and persists nothing" {
  handle_slash_command "/cwd some/rel/path" "$SLUG" "$JID" "$JID" "MSG" "cwd5"
  text="$(jq -r '.text' "$WABOX_OUTBOX/cwd5.json")"
  [[ "$text" == *"absolute path or start with ~"* ]]
  [ ! -e "$(conversation_dir "$SLUG")/workdir" ]
}

@test "/cwd rejects a nonexistent directory" {
  handle_slash_command "/cwd $TMPDIR_TEST/nope" "$SLUG" "$JID" "$JID" "MSG" "cwd6"
  text="$(jq -r '.text' "$WABOX_OUTBOX/cwd6.json")"
  [[ "$text" == *"No such directory: $TMPDIR_TEST/nope"* ]]
  [ ! -e "$(conversation_dir "$SLUG")/workdir" ]
}

@test "/cwd rejects a path that is a file, not a directory" {
  : >"$TMPDIR_TEST/afile"
  handle_slash_command "/cwd $TMPDIR_TEST/afile" "$SLUG" "$JID" "$JID" "MSG" "cwd7"
  text="$(jq -r '.text' "$WABOX_OUTBOX/cwd7.json")"
  [[ "$text" == *"Not a directory: $TMPDIR_TEST/afile"* ]]
  [ ! -e "$(conversation_dir "$SLUG")/workdir" ]
}

@test "/help lists /cwd" {
  handle_slash_command "/help" "$SLUG" "$JID" "$JID" "MSG" "cwdhelp"
  [[ "$(jq -r '.text' "$WABOX_OUTBOX/cwdhelp.json")" == *"/cwd"* ]]
}

@test "/status reports the working folder" {
  handle_slash_command "/status" "$SLUG" "$JID" "$JID" "MSG" "cwdstatus"
  [[ "$(jq -r '.text' "$WABOX_OUTBOX/cwdstatus.json")" == *"workdir: "* ]]
}

@test "/status reports a human-readable folder size line" {
  handle_slash_command "/status" "$SLUG" "$JID" "$JID" "MSG" "szstatus"
  text="$(jq -r '.text' "$WABOX_OUTBOX/szstatus.json")"
  [[ "$text" == *"pasta:"* ]]
  [[ "$text" == *"(bot:"* ]]
}

@test "/status does not materialize the workdir as a side effect" {
  handle_slash_command "/status" "$SLUG" "$JID" "$JID" "MSG" "nomkdir"
  [ ! -e "$STATE_DIR/work/$SLUG" ]
}
