#!/usr/bin/env bats
# The scheduler exposed over MCP — `wabox-bot mcp <slug>` — plus the claude-code
# /mcp command that registers it in a workdir.
#
# The protocol half drives the *real* entrypoint as a subprocess (like loop.bats
# does for the daemon): a handshake that only works in-process would prove
# nothing about what a client actually spawns.

load test_helper

setup_mcp() {
  setup_lib
  # A private HOME: cc_workspace_trusted reads ~/.claude.json, and a test must
  # not depend on which folders the developer happens to have trusted.
  export HOME="$TMPDIR_TEST/home"
  mkdir -p "$HOME"
  export WABOX_JOB_TZ="America/Sao_Paulo"
  load_core
  # ROOT is set by bin/wabox-bot before it sources anything; cc_bot_path reads
  # it to write an absolute spawn line into .mcp.json.
  ROOT="$REPO_ROOT"
  # shellcheck source=../../lib/mcp.sh
  source "$LIB_DIR/mcp.sh"
  SLUG="feed1234"
  JID="5511999@s.whatsapp.net"
  mkdir -p "$SESSIONS_DIR/$SLUG" "$JOBS_DIR/$SLUG"
  printf '%s\n' "$JID" >"$SESSIONS_DIR/$SLUG/conv_key"
}

# Feed a batch of JSON-RPC lines to the real binary and echo its stdout.
rpc() {
  printf '%s\n' "$@" |
    env WABOX_BOT_CONFIG="$WABOX_BOT_CONFIG" STATE_DIR="$STATE_DIR" \
      WABOX_INBOX="$WABOX_INBOX" WABOX_OUTBOX="$WABOX_OUTBOX" \
      LOG_FILE="$LOG_FILE" WABOX_JOB_TZ="$WABOX_JOB_TZ" \
      timeout 30 "$REPO_ROOT/bin/wabox-bot" mcp "$SLUG" 2>/dev/null
}

# Run a slash command through the real dispatcher and echo the reply text.
cmd_reply_mcp() {
  local text="$1" stem="t$RANDOM$RANDOM" job
  handle_slash_command "$text" "$SLUG" "$JID" "$JID" "" "$stem" || return $?
  job="$WABOX_OUTBOX/$stem.json"
  [ -f "$job" ] || return 1
  jq -r '.text' "$job"
}

INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}'

# ---- protocol ----------------------------------------------------------------

@test "initialize answers with the tools capability and echoes the client's protocol version" {
  setup_mcp
  out="$(rpc "$INIT")"
  [ "$(jq -r '.id' <<<"$out")" = "1" ]
  [ "$(jq -r '.result.protocolVersion' <<<"$out")" = "2025-06-18" ]
  [ "$(jq -r '.result.serverInfo.name' <<<"$out")" = "wabox" ]
  [ "$(jq -r '.result.capabilities.tools | type' <<<"$out")" = "object" ]
  teardown_lib
}

@test "a notification is never answered" {
  setup_mcp
  out="$(rpc "$INIT" '{"jsonrpc":"2.0","method":"notifications/initialized"}')"
  # Exactly one line back: the initialize result, nothing for the notification.
  [ "$(wc -l <<<"$out")" -eq 1 ]
  [ "$(jq -r '.id' <<<"$out")" = "1" ]
  teardown_lib
}

@test "tools/list advertises the scheduler tools and send_file with input schemas" {
  setup_mcp
  out="$(rpc "$INIT" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | tail -1)"
  names="$(jq -r '.result.tools[].name' <<<"$out" | sort | tr '\n' ' ')"
  [ "$names" = "cancel_job list_jobs schedule_at schedule_daily schedule_every schedule_in schedule_message send_file " ]
  [ "$(jq -r '.result.tools[] | select(.name=="schedule_in") | .inputSchema.required | join(",")' <<<"$out")" = "delay,text" ]
  teardown_lib
}

@test "an unknown method is a JSON-RPC error, an unknown tool is a tool error" {
  setup_mcp
  out="$(rpc "$INIT" \
    '{"jsonrpc":"2.0","id":2,"method":"resources/list"}' \
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"nope","arguments":{}}}')"
  [ "$(jq -r 'select(.id==2) | .error.code' <<<"$out")" = "-32601" ]
  # A tool failure must come back as a *result* the model can read and retry.
  [ "$(jq -r 'select(.id==3) | .result.isError' <<<"$out")" = "true" ]
  [ "$(jq -r 'select(.id==3) | .error // "none"' <<<"$out")" = "none" ]
  teardown_lib
}

@test "a string id round-trips as a string" {
  setup_mcp
  out="$(rpc '{"jsonrpc":"2.0","id":"abc","method":"ping"}')"
  [ "$(jq -r '.id | type' <<<"$out")" = "string" ]
  [ "$(jq -r '.id' <<<"$out")" = "abc" ]
  teardown_lib
}

@test "the server refuses a slug it doesn't know" {
  setup_mcp
  run bash -c "printf '%s\n' '$INIT' | WABOX_BOT_CONFIG=/dev/null STATE_DIR='$STATE_DIR' \
    timeout 30 '$BATS_TEST_DIRNAME/../../bin/wabox-bot' mcp nosuchslug 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown conversation slug"* ]]
  teardown_lib
}

# ---- tools actually schedule -------------------------------------------------

@test "schedule_daily through the protocol writes a real job record" {
  setup_mcp
  out="$(rpc "$INIT" \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"schedule_daily","arguments":{"time":"09:00","text":"morning brief"}}}')"
  [ "$(jq -r 'select(.id==2) | .result.isError' <<<"$out")" = "false" ]
  [[ "$(jq -r 'select(.id==2) | .result.content[0].text' <<<"$out")" == *"09:00"* ]]
  [ -f "$JOBS_DIR/$SLUG/1.json" ]
  [ "$(jq -r '.kind' "$JOBS_DIR/$SLUG/1.json")" = "daily" ]
  [ "$(jq -r '.text' "$JOBS_DIR/$SLUG/1.json")" = "morning brief" ]
  teardown_lib
}

@test "list_jobs and cancel_job see the same jobs the slash commands do" {
  setup_mcp
  out="$(rpc "$INIT" \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"schedule_in","arguments":{"delay":"2h","text":"tirar o frango"}}}' \
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_jobs","arguments":{}}}' \
    '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"cancel_job","arguments":{"id":"1"}}}')"
  [[ "$(jq -r 'select(.id==3) | .result.content[0].text' <<<"$out")" == *"tirar o frango"* ]]
  [[ "$(jq -r 'select(.id==4) | .result.content[0].text' <<<"$out")" == *"Cancelled job #1"* ]]
  [ ! -f "$JOBS_DIR/$SLUG/1.json" ]
  teardown_lib
}

@test "a multi-word text survives as one job, newlines and all" {
  setup_mcp
  rpc "$INIT" \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"schedule_every","arguments":{"interval":"30m","text":"check the calendar\nand the inbox"}}}' >/dev/null
  [ "$(jq -r '.text' "$JOBS_DIR/$SLUG/1.json")" = "check the calendar
and the inbox" ]
  teardown_lib
}

@test "a bad duration comes back as the command's own usage text, not a crash" {
  setup_mcp
  out="$(rpc "$INIT" \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"schedule_in","arguments":{"delay":"soonish","text":"x"}}}')"
  [ "$(jq -r 'select(.id==2) | .result.isError' <<<"$out")" = "false" ]
  [[ "$(jq -r 'select(.id==2) | .result.content[0].text' <<<"$out")" == *"couldn't read"* ]]
  [ ! -f "$JOBS_DIR/$SLUG/1.json" ]
  teardown_lib
}

@test "schedule_message registers a verbatim send job, not an agent turn" {
  setup_mcp
  out="$(rpc "$INIT" \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"schedule_message","arguments":{"when":"22:00","text":"tomar o remédio"}}}' \
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"schedule_message","arguments":{"when":"every 2h","text":"beber água"}}}')"
  [ "$(jq -r 'select(.id==2) | .result.isError' <<<"$out")" = "false" ]
  [ "$(jq -r '.action' "$JOBS_DIR/$SLUG/1.json")" = "send" ]
  [ "$(jq -r '.raw' "$JOBS_DIR/$SLUG/1.json")" = "true" ]
  [ "$(jq -r '.text' "$JOBS_DIR/$SLUG/1.json")" = "tomar o remédio" ]
  [ "$(jq -r '.kind' "$JOBS_DIR/$SLUG/2.json")" = "interval" ]
  [ "$(jq -r '.action' "$JOBS_DIR/$SLUG/2.json")" = "send" ]
  teardown_lib
}

# ---- /mcp registration -------------------------------------------------------

@test "schedule_daily takes days, and refuses days it can't read" {
  setup_mcp
  out="$(rpc "$INIT" \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"schedule_daily","arguments":{"time":"15:00","days":"fri","text":"weekly review"}}}' \
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"schedule_daily","arguments":{"time":"15:00","days":"someday","text":"x"}}}')"
  [ "$(jq -r 'select(.id==2) | .result.isError' <<<"$out")" = "false" ]
  [ "$(jq -r '.days' "$JOBS_DIR/$SLUG/1.json")" = "5" ]
  [ "$(jq -r '.text' "$JOBS_DIR/$SLUG/1.json")" = "weekly review" ]
  # An unreadable day spec must not slip into the text as its first word.
  [ "$(jq -r 'select(.id==3) | .result.isError' <<<"$out")" = "true" ]
  [ ! -e "$JOBS_DIR/$SLUG/2.json" ]
  teardown_lib
}

# ---- send_file -----------------------------------------------------------------

# One tools/call to send_file; echoes the result object.
send_file_rpc() {
  local args
  args="$(jq -cn --arg p "$1" '{path:$p}')"
  rpc "$INIT" \
    "$(jq -cn --argjson a "$args" '{jsonrpc:"2.0",id:2,method:"tools/call",params:{name:"send_file",arguments:$a}}')" |
    jq -c 'select(.id==2) | .result'
}

@test "send_file queues a file from the working folder into the send folder" {
  setup_mcp
  wd="$(conversation_workdir "$SLUG")"
  mkdir -p "$wd/docs"
  printf 'pdf-bytes' >"$wd/docs/CNH-e.pdf"
  res="$(send_file_rpc "docs/CNH-e.pdf")"
  [ "$(jq -r '.isError' <<<"$res")" = "false" ]
  [[ "$(jq -r '.content[0].text' <<<"$res")" == *"Queued CNH-e.pdf"* ]]
  [ "$(cat "$(senddir_path "$wd")/CNH-e.pdf")" = "pdf-bytes" ]
  # …and it is exactly what the loop attaches at the end of the turn.
  [ "$(senddir_collect "$wd")" = "$(senddir_path "$wd")/CNH-e.pdf" ]
  teardown_lib
}

@test "send_file refuses a file outside the working folder, symlinks included" {
  setup_mcp
  wd="$(conversation_workdir "$SLUG")"
  printf 'secret' >"$TMPDIR_TEST/outside.txt"
  res="$(send_file_rpc "$TMPDIR_TEST/outside.txt")"
  [ "$(jq -r '.isError' <<<"$res")" = "true" ]
  [[ "$(jq -r '.content[0].text' <<<"$res")" == *"outside the working folder"* ]]
  ln -s "$TMPDIR_TEST/outside.txt" "$wd/link.txt"
  res="$(send_file_rpc "link.txt")"
  [ "$(jq -r '.isError' <<<"$res")" = "true" ]
  res="$(send_file_rpc "../outside.txt")"
  [ "$(jq -r '.isError' <<<"$res")" = "true" ]
  [ -z "$(senddir_collect "$wd")" ]
  teardown_lib
}

@test "send_file reports a missing file as a readable tool error" {
  setup_mcp
  res="$(send_file_rpc "nope.pdf")"
  [ "$(jq -r '.isError' <<<"$res")" = "true" ]
  [[ "$(jq -r '.content[0].text' <<<"$res")" == *"No such file"* ]]
  teardown_lib
}

@test "send_file keeps two different files with the same name, and queues one file once" {
  setup_mcp
  wd="$(conversation_workdir "$SLUG")"
  mkdir -p "$wd/a" "$wd/b"
  printf 'one' >"$wd/a/doc.pdf"
  printf 'two' >"$wd/b/doc.pdf"
  send_file_rpc "a/doc.pdf" >/dev/null
  send_file_rpc "b/doc.pdf" >/dev/null
  res="$(send_file_rpc "a/doc.pdf")"
  [[ "$(jq -r '.content[0].text' <<<"$res")" == *"Already queued: doc.pdf"* ]]
  dir="$(senddir_path "$wd")"
  [ "$(cat "$dir/doc.pdf")" = "one" ]
  [ "$(cat "$dir/doc (2).pdf")" = "two" ]
  [ "$(senddir_collect "$wd" | wc -l)" -eq 2 ]
  teardown_lib
}

@test "send_file refuses a file over WABOX_DOC_MAX_MB" {
  setup_mcp
  wd="$(conversation_workdir "$SLUG")"
  truncate -s 2M "$wd/big.bin"
  res="$(printf '%s\n' "$INIT" '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"send_file","arguments":{"path":"big.bin"}}}' |
    env WABOX_BOT_CONFIG="$WABOX_BOT_CONFIG" STATE_DIR="$STATE_DIR" \
      WABOX_INBOX="$WABOX_INBOX" WABOX_OUTBOX="$WABOX_OUTBOX" LOG_FILE="$LOG_FILE" \
      WABOX_DOC_MAX_MB=1 timeout 30 "$REPO_ROOT/bin/wabox-bot" mcp "$SLUG" 2>/dev/null |
    jq -c 'select(.id==2) | .result')"
  [ "$(jq -r '.isError' <<<"$res")" = "true" ]
  [[ "$(jq -r '.content[0].text' <<<"$res")" == *"over the 1 MB limit"* ]]
  teardown_lib
}

@test "/mcp add writes .mcp.json pointing at this executable and this slug" {
  setup_mcp
  wd="$(conversation_workdir "$SLUG")"
  out="$(cmd_reply_mcp "/mcp add")"
  [[ "$out" == *"schedule things myself"* ]]
  [ "$(jq -r '.mcpServers.wabox.args | join(" ")' "$wd/.mcp.json")" = "mcp $SLUG" ]
  [ -x "$(jq -r '.mcpServers.wabox.command' "$wd/.mcp.json")" ]
  teardown_lib
}

@test "/mcp add also enables the server and pre-allows its tools" {
  setup_mcp
  wd="$(conversation_workdir "$SLUG")"
  cmd_reply_mcp "/mcp add" >/dev/null
  s="$wd/.claude/settings.local.json"
  [ "$(jq -r '.enabledMcpjsonServers | index("wabox") != null' "$s")" = "true" ]
  [ "$(jq -r '.permissions.allow | index("mcp__wabox") != null' "$s")" = "true" ]
  teardown_lib
}

@test "/mcp add preserves other servers and other permissions" {
  setup_mcp
  wd="$(conversation_workdir "$SLUG")"
  mkdir -p "$wd/.claude"
  printf '%s' '{"mcpServers":{"readwise":{"command":"x"}}}' >"$wd/.mcp.json"
  printf '%s' '{"permissions":{"allow":["WebSearch"]},"enabledMcpjsonServers":["readwise"]}' \
    >"$wd/.claude/settings.local.json"
  cmd_reply_mcp "/mcp add" >/dev/null
  [ "$(jq -r '.mcpServers | keys | join(",")' "$wd/.mcp.json")" = "readwise,wabox" ]
  [ "$(jq -r '.permissions.allow | sort | join(",")' "$wd/.claude/settings.local.json")" = "WebSearch,mcp__wabox" ]
  [ "$(jq -r '.enabledMcpjsonServers | sort | join(",")' "$wd/.claude/settings.local.json")" = "readwise,wabox" ]
  teardown_lib
}

@test "/mcp add is idempotent" {
  setup_mcp
  wd="$(conversation_workdir "$SLUG")"
  cmd_reply_mcp "/mcp add" >/dev/null
  cmd_reply_mcp "/mcp add" >/dev/null
  [ "$(jq -r '.enabledMcpjsonServers | length' "$wd/.claude/settings.local.json")" = "1" ]
  [ "$(jq -r '.permissions.allow | length' "$wd/.claude/settings.local.json")" = "1" ]
  teardown_lib
}

@test "/mcp remove undoes both files but leaves the neighbours alone" {
  setup_mcp
  wd="$(conversation_workdir "$SLUG")"
  mkdir -p "$wd/.claude"
  printf '%s' '{"mcpServers":{"readwise":{"command":"x"}}}' >"$wd/.mcp.json"
  cmd_reply_mcp "/mcp add" >/dev/null
  cmd_reply_mcp "/mcp remove" >/dev/null
  [ "$(jq -r '.mcpServers | keys | join(",")' "$wd/.mcp.json")" = "readwise" ]
  [ "$(jq -r '.enabledMcpjsonServers | length' "$wd/.claude/settings.local.json")" = "0" ]
  teardown_lib
}

@test "/mcp status reports registered vs not, and warns about an untrusted folder" {
  setup_mcp
  out="$(cmd_reply_mcp "/mcp")"
  [[ "$out" == *"not registered"* ]]
  cmd_reply_mcp "/mcp add" >/dev/null
  out="$(cmd_reply_mcp "/mcp")"
  [[ "$out" == *"registered in"* ]]
  # HOME is the tempdir here, so there is no ~/.claude.json ⇒ untrusted.
  [[ "$out" == *"isn't trusted"* ]]
  teardown_lib
}

@test "/mcp with a junk argument explains itself" {
  setup_mcp
  out="$(cmd_reply_mcp "/mcp wat")"
  [[ "$out" == *"Usage: /mcp"* ]]
  teardown_lib
}

@test "/help lists the /mcp commands" {
  setup_mcp
  out="$(cmd_reply_mcp "/help")"
  [[ "$out" == *"/mcp add"* ]]
  teardown_lib
}
