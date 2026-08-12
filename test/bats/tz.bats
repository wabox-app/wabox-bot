#!/usr/bin/env bats
# Per-conversation timezone: /tz, and the two things it feeds — where the
# scheduler resolves wall-clock times, and what clock the agent's own turn runs
# under. The daemon usually runs UTC under systemd; the user does not.

load test_helper

setup_tz() {
  setup_lib
  export WABOX_BOT_BACKEND=echo
  load_core
  SLUG="feed1234"
  JID="5511@s.whatsapp.net"
  mkdir -p "$SESSIONS_DIR/$SLUG"
  printf '%s\n' "$JID" >"$SESSIONS_DIR/$SLUG/conv_key"
}

cmd_reply() {
  local text="$1" stem="t$RANDOM$RANDOM" job
  handle_slash_command "$text" "$SLUG" "$JID" "$JID" "" "$stem" || return $?
  job="$WABOX_OUTBOX/$stem.json"
  [ -f "$job" ] || return 1
  jq -r '.text' "$job"
}

job_field() { jq -r "$2" "$JOBS_DIR/$SLUG/$1.json"; }

# ---- validation --------------------------------------------------------------

@test "tz_valid accepts real zones and rejects everything else" {
  setup_tz
  run tz_valid "America/Sao_Paulo"; [ "$status" -eq 0 ]
  run tz_valid "UTC"; [ "$status" -eq 0 ]
  run tz_valid "Europe/Lisbon"; [ "$status" -eq 0 ]
  # TZ=Foo/Bar silently means UTC, which is the whole failure mode — so a name
  # tzdata doesn't have has to be refused, not accepted and quietly ignored.
  run tz_valid "Foo/Bar"; [ "$status" -ne 0 ]
  run tz_valid ""; [ "$status" -ne 0 ]
  run tz_valid "-03"; [ "$status" -ne 0 ]
  # No path escapes into something that becomes an env var.
  run tz_valid "../../etc/passwd"; [ "$status" -ne 0 ]
  run tz_valid "/etc/passwd"; [ "$status" -ne 0 ]
  teardown_lib
}

# ---- the command -------------------------------------------------------------

@test "/tz with no zone set says it's following the daemon" {
  setup_tz
  out="$(cmd_reply "/tz")"
  [[ "$out" == *"not set"* ]]
  [[ "$out" == *"wrong hour"* ]]
  teardown_lib
}

@test "/tz sets, shows and clears a conversation's zone" {
  setup_tz
  out="$(cmd_reply "/tz America/Sao_Paulo")"
  [[ "$out" == *"set to America/Sao_Paulo"* ]]
  [ "$(conversation_tz "$SLUG")" = "America/Sao_Paulo" ]
  out="$(cmd_reply "/tz")"
  [[ "$out" == *"Timezone: America/Sao_Paulo"* ]]
  out="$(cmd_reply "/tz default")"
  [[ "$out" == *"removed"* ]]
  [ -z "$(conversation_tz "$SLUG")" ]
  teardown_lib
}

@test "/tz refuses an unknown zone instead of silently meaning UTC" {
  setup_tz
  out="$(cmd_reply "/tz Mars/Olympus")"
  [[ "$out" == *"don't know the timezone"* ]]
  [ -z "$(conversation_tz "$SLUG")" ]
  teardown_lib
}

@test "/tz points an offset at the city name, because Etc/GMT+3 is UTC-3" {
  setup_tz
  out="$(cmd_reply "/tz -03")"
  [[ "$out" == *"sign inverted"* ]]
  [[ "$out" == *"America/Sao_Paulo"* ]]
  out="$(cmd_reply "/tz GMT-3")"
  [[ "$out" == *"Offsets are a trap"* ]]
  [ -z "$(conversation_tz "$SLUG")" ]
  teardown_lib
}

@test "the conversation's zone wins over WABOX_JOB_TZ, which wins over local" {
  setup_tz
  [ -z "$(conversation_tz "$SLUG")" ]
  export WABOX_JOB_TZ="Europe/Lisbon"
  [ "$(conversation_tz "$SLUG")" = "Europe/Lisbon" ]
  cmd_reply "/tz America/Sao_Paulo" >/dev/null
  [ "$(conversation_tz "$SLUG")" = "America/Sao_Paulo" ]
  # An empty slug asks for the daemon-wide default (the startup banner).
  [ "$(conversation_tz)" = "Europe/Lisbon" ]
  teardown_lib
}

@test "/tz is per conversation, not global" {
  setup_tz
  other="beef5678"
  mkdir -p "$SESSIONS_DIR/$other"
  cmd_reply "/tz America/Sao_Paulo" >/dev/null
  [ -z "$(conversation_tz "$other")" ]
  teardown_lib
}

# ---- what it feeds -----------------------------------------------------------

@test "a job registered after /tz resolves in that zone and stores it" {
  setup_tz
  cmd_reply "/tz America/Sao_Paulo" >/dev/null
  cmd_reply "/daily 09:00 morning brief" >/dev/null
  [ "$(job_field 1 .tz)" = "America/Sao_Paulo" ]
  [ "$(TZ=America/Sao_Paulo date -d "@$(job_field 1 .next_run)" +%H:%M)" = "09:00" ]
  teardown_lib
}

@test "the same 09:00 lands at a different instant in a different zone" {
  setup_tz
  cmd_reply "/tz America/Sao_Paulo" >/dev/null
  cmd_reply "/daily 09:00 a" >/dev/null
  cmd_reply "/tz Europe/Lisbon" >/dev/null
  cmd_reply "/daily 09:00 b" >/dev/null
  [ "$(job_field 1 .next_run)" -ne "$(job_field 2 .next_run)" ]
  [ "$(TZ=Europe/Lisbon date -d "@$(job_field 2 .next_run)" +%H:%M)" = "09:00" ]
  teardown_lib
}

@test "changing /tz never moves a job that was already booked" {
  setup_tz
  cmd_reply "/tz America/Sao_Paulo" >/dev/null
  cmd_reply "/daily 09:00 morning brief" >/dev/null
  before="$(job_field 1 .next_run)"
  out="$(cmd_reply "/tz Europe/Lisbon")"
  [ "$(job_field 1 .next_run)" -eq "$before" ]
  [ "$(job_field 1 .tz)" = "America/Sao_Paulo" ]
  # …and the user is told, rather than finding out at the wrong hour.
  [[ "$out" == *"1 job(s) already scheduled keep the zone"* ]]
  teardown_lib
}

@test "/jobs and /status report the conversation's zone" {
  setup_tz
  cmd_reply "/tz America/Sao_Paulo" >/dev/null
  cmd_reply "/daily 09:00 morning brief" >/dev/null
  [[ "$(cmd_reply "/jobs")" == *"America/Sao_Paulo"* ]]
  [[ "$(cmd_reply "/status")" == *"tz:      America/Sao_Paulo"* ]]
  teardown_lib
}

@test "/help lists /tz" {
  setup_tz
  [[ "$(cmd_reply "/help")" == *"/tz <zone>"* ]]
  teardown_lib
}

@test "the claude-code turn runs under the conversation's zone" {
  setup_tz
  export WABOX_BOT_BACKEND=claude-code
  # A fake `claude` that just reports the clock it was given, in the response
  # shape the backend parses.
  fake="$TMPDIR_TEST/bin"
  mkdir -p "$fake"
  cat >"$fake/claude" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
jq -n --arg r "$(date +%Z)" '{result:$r, session_id:"s1", permission_denials:[]}'
EOF
  chmod +x "$fake/claude"
  export CLAUDE_BIN="$fake/claude"
  # backend.sh loads at source time; swap the implementation in directly.
  # shellcheck source=../../lib/backends/claude-code.sh
  source "$LIB_DIR/backends/claude-code.sh"
  cmd_reply "/tz America/Sao_Paulo" >/dev/null
  out="$(backend_reply "$SLUG" "$JID" "s2" <<<"que horas são?")"
  [ "$out" = "-03" ]
  teardown_lib
}
