load test_helper

# Scheduled jobs — /in /at /every /daily /jobs /cancel, and the tick that fires
# them. Design: docs/superpowers/specs/2026-08-09-scheduled-jobs-design.md
#
# Firing is exercised with a stubbed prompt_main: the real one is already
# covered by prompt.bats, and stubbing lets us drive the exit codes that decide
# advance-vs-defer (0 delivered, 5 NOOP, 3 lock busy, 124 timeout).

setup_sched() {
  setup_lib
  export WABOX_BOT_BACKEND=echo
  # A fixed zone keeps wall-clock assertions (and the DST case) reproducible
  # wherever the suite runs.
  export WABOX_JOB_TZ="America/Sao_Paulo"
  load_core
  SLUG="feed1234"
  JID="5511@s.whatsapp.net"
  mkdir -p "$SESSIONS_DIR/$SLUG"
  printf '%s\n' "$JID" >"$SESSIONS_DIR/$SLUG/conv_key"
}

# Run a slash command through the real dispatcher and echo the reply text.
cmd_reply() {
  local text="$1" stem="t$RANDOM$RANDOM" job
  handle_slash_command "$text" "$SLUG" "$JID" "$JID" "" "$stem" || return $?
  job="$WABOX_OUTBOX/$stem.json"
  [ -f "$job" ] || return 1
  jq -r '.text' "$job"
}

job_file() { printf '%s/%s/%s.json' "$JOBS_DIR" "$SLUG" "$1"; }
job_field() { jq -r "$2" "$(job_file "$1")"; }

# ---- duration parsing -------------------------------------------------------

@test "sched_parse_dur: units and concatenations" {
  setup_sched
  [ "$(sched_parse_dur 90s)" -eq 90 ]
  [ "$(sched_parse_dur 30m)" -eq 1800 ]
  [ "$(sched_parse_dur 2h)" -eq 7200 ]
  [ "$(sched_parse_dur 1d)" -eq 86400 ]
  [ "$(sched_parse_dur 1w)" -eq 604800 ]
  [ "$(sched_parse_dur 1h30m)" -eq 5400 ]
  teardown_lib
}

@test "sched_parse_dur: a bare integer means minutes" {
  setup_sched
  # `/in 30` on a phone means half an hour, not thirty seconds.
  [ "$(sched_parse_dur 30)" -eq 1800 ]
  # Leading zeros must not be read as octal.
  [ "$(sched_parse_dur 09)" -eq 540 ]
  teardown_lib
}

@test "sched_parse_dur: junk is rejected" {
  setup_sched
  run sched_parse_dur "soon"
  [ "$status" -ne 0 ]
  run sched_parse_dur "2x"
  [ "$status" -ne 0 ]
  run sched_parse_dur ""
  [ "$status" -ne 0 ]
  run sched_parse_dur "0m"
  [ "$status" -ne 0 ]
  teardown_lib
}

# ---- time parsing -----------------------------------------------------------

@test "sched_parse_time: the forms a phone actually produces" {
  setup_sched
  [ "$(sched_parse_time 9)" = "09:00" ]
  [ "$(sched_parse_time 09)" = "09:00" ]
  [ "$(sched_parse_time 9:00)" = "09:00" ]
  [ "$(sched_parse_time 09:00)" = "09:00" ]
  [ "$(sched_parse_time 9h)" = "09:00" ]
  [ "$(sched_parse_time 9h30)" = "09:30" ]
  [ "$(sched_parse_time 0930)" = "09:30" ]
  [ "$(sched_parse_time 21:30)" = "21:30" ]
  teardown_lib
}

@test "sched_parse_time: am/pm, including the 12 o'clock corners" {
  setup_sched
  [ "$(sched_parse_time 9am)" = "09:00" ]
  [ "$(sched_parse_time 9pm)" = "21:00" ]
  [ "$(sched_parse_time "9:30pm")" = "21:30" ]
  [ "$(sched_parse_time 12am)" = "00:00" ]
  [ "$(sched_parse_time 12pm)" = "12:00" ]
  teardown_lib
}

@test "sched_parse_time: out-of-range and junk are rejected" {
  setup_sched
  run sched_parse_time "25:00"
  [ "$status" -ne 0 ]
  run sched_parse_time "9:75"
  [ "$status" -ne 0 ]
  run sched_parse_time "lunchtime"
  [ "$status" -ne 0 ]
  teardown_lib
}

# ---- wall-clock arithmetic --------------------------------------------------

@test "sched_next_daily lands on the stated wall-clock hour in the job's zone" {
  setup_sched
  now="$(date +%s)"
  nr="$(sched_next_daily "America/Sao_Paulo" "09:00" "$now")"
  [ "$nr" -gt "$now" ]
  [ "$(TZ=America/Sao_Paulo date -d "@$nr" +%H:%M)" = "09:00" ]
  teardown_lib
}

@test "sched_next_daily rolls to tomorrow when the time already passed today" {
  setup_sched
  # 10:00 local, asking for 09:00 ⇒ tomorrow.
  base="$(TZ=America/Sao_Paulo date -d '2026-03-10 10:00' +%s)"
  nr="$(sched_next_daily "America/Sao_Paulo" "09:00" "$base")"
  [ "$(TZ=America/Sao_Paulo date -d "@$nr" +%F\ %H:%M)" = "2026-03-11 09:00" ]
  teardown_lib
}

@test "a daily job keeps its hour across a DST change" {
  setup_sched
  # Brazil has no DST today, so use a zone that does: Europe/Lisbon springs
  # forward on 2026-03-29. Adding 86400 would land on 10:00; recomputing the
  # wall-clock time keeps it at 09:00, which is the whole point of the rule.
  base="$(TZ=Europe/Lisbon date -d '2026-03-28 09:30' +%s)"
  nr="$(sched_next_daily "Europe/Lisbon" "09:00" "$base")"
  [ "$(TZ=Europe/Lisbon date -d "@$nr" +%F\ %H:%M)" = "2026-03-29 09:00" ]
  [ "$((nr - base))" -ne 84600 ]
  teardown_lib
}

# ---- registering jobs from the chat -----------------------------------------

@test "/at registers a one-shot and confirms with the resolved local time" {
  setup_sched
  out="$(cmd_reply "/at 23:59 call the dentist")"
  [[ "$out" == *"#1"* ]]
  [[ "$out" == *"23:59"* ]]
  [[ "$out" == *"America/Sao_Paulo"* ]]
  [ "$(job_field 1 .kind)" = "once" ]
  [ "$(job_field 1 .text)" = "call the dentist" ]
  [ "$(job_field 1 .tz)" = "America/Sao_Paulo" ]
  [ "$(job_field 1 .next_run)" -gt "$(date +%s)" ]
  teardown_lib
}

@test "/at with an explicit date schedules on that date" {
  setup_sched
  cmd_reply "/at 2030-08-12 09:00 renew the passport" >/dev/null
  nr="$(job_field 1 .next_run)"
  [ "$(TZ=America/Sao_Paulo date -d "@$nr" +%F\ %H:%M)" = "2030-08-12 09:00" ]
  teardown_lib
}

@test "/at refuses a date in the past instead of scheduling backwards" {
  setup_sched
  out="$(cmd_reply "/at 2020-01-01 09:00 too late")"
  [[ "$out" == *"past"* ]]
  [ ! -f "$(job_file 1)" ]
  teardown_lib
}

@test "/every registers an interval job" {
  setup_sched
  out="$(cmd_reply "/every 30m check my calendar")"
  [[ "$out" == *"every 30min"* ]]
  [ "$(job_field 1 .kind)" = "interval" ]
  [ "$(job_field 1 .rule)" = "1800" ]
  teardown_lib
}

@test "/every under the minimum interval is refused" {
  setup_sched
  export WABOX_JOB_MIN_INTERVAL=60
  out="$(cmd_reply "/every 10s spam me")"
  [[ "$out" == *"too often"* ]]
  [ ! -f "$(job_file 1)" ]
  teardown_lib
}

@test "/daily registers a wall-clock repeat" {
  setup_sched
  out="$(cmd_reply "/daily 09:00 morning digest")"
  [[ "$out" == *"daily 09:00"* ]]
  [ "$(job_field 1 .kind)" = "daily" ]
  [ "$(job_field 1 .rule)" = "09:00" ]
  [ "$(TZ=America/Sao_Paulo date -d "@$(job_field 1 .next_run)" +%H:%M)" = "09:00" ]
  teardown_lib
}

@test "/in schedules relative to now" {
  setup_sched
  before="$(date +%s)"
  cmd_reply "/in 2h take the chicken out" >/dev/null
  nr="$(job_field 1 .next_run)"
  [ "$nr" -ge "$((before + 7200))" ]
  [ "$nr" -le "$((before + 7205))" ]
  teardown_lib
}

@test "a multi-line instruction survives registration verbatim" {
  setup_sched
  cmd_reply "$(printf '/daily 09:00 check:\n- calendar\n- todos')" >/dev/null
  [ "$(job_field 1 .text)" = "$(printf 'check:\n- calendar\n- todos')" ]
  teardown_lib
}

@test "a scheduling verb with no instruction explains itself" {
  setup_sched
  out="$(cmd_reply "/in 2h")"
  [[ "$out" == *"Schedule what?"* ]]
  [ ! -f "$(job_file 1)" ]
  teardown_lib
}

@test "an unreadable duration or time is reported, not swallowed" {
  setup_sched
  out="$(cmd_reply "/in soon do the thing")"
  [[ "$out" == *"duration"* ]]
  out="$(cmd_reply "/daily lunchtime do the thing")"
  [[ "$out" == *"time"* ]]
  [ ! -f "$(job_file 1)" ]
  teardown_lib
}

@test "the per-conversation job cap is enforced" {
  setup_sched
  export WABOX_JOB_MAX=2
  cmd_reply "/daily 09:00 one" >/dev/null
  cmd_reply "/daily 10:00 two" >/dev/null
  out="$(cmd_reply "/daily 11:00 three")"
  [[ "$out" == *"already has 2"* ]]
  [ ! -f "$(job_file 3)" ]
  teardown_lib
}

@test "ids are allocated per conversation, not globally" {
  setup_sched
  other="beef5678"
  mkdir -p "$SESSIONS_DIR/$other"
  printf '5522@s.whatsapp.net\n' >"$SESSIONS_DIR/$other/conv_key"
  cmd_reply "/daily 09:00 mine" >/dev/null
  handle_slash_command "/daily 09:00 theirs" "$other" "x" "x" "" "s2"
  [ -f "$JOBS_DIR/$SLUG/1.json" ]
  [ -f "$JOBS_DIR/$other/1.json" ]
  teardown_lib
}

# ---- listing and cancelling --------------------------------------------------

@test "/jobs lists this conversation's jobs with their next run" {
  setup_sched
  cmd_reply "/daily 09:00 morning digest" >/dev/null
  cmd_reply "/every 1h check the calendar" >/dev/null
  out="$(cmd_reply "/jobs")"
  [[ "$out" == *"#1"* ]]
  [[ "$out" == *"daily 09:00"* ]]
  [[ "$out" == *"morning digest"* ]]
  [[ "$out" == *"#2"* ]]
  [[ "$out" == *"every 1h"* ]]
  [[ "$out" == *"America/Sao_Paulo"* ]]
  teardown_lib
}

@test "/jobs is scoped to the conversation that asks" {
  setup_sched
  other="beef5678"
  mkdir -p "$JOBS_DIR/$other"
  handle_slash_command "/daily 07:00 not yours" "$other" "x" "x" "" "s2"
  out="$(cmd_reply "/jobs")"
  [[ "$out" == *"No scheduled jobs"* ]]
  [[ "$out" != *"not yours"* ]]
  teardown_lib
}

@test "/jobs says so when there is nothing scheduled" {
  setup_sched
  out="$(cmd_reply "/jobs")"
  [[ "$out" == *"No scheduled jobs"* ]]
  teardown_lib
}

@test "/cancel removes one job, /cancel all removes the rest" {
  setup_sched
  cmd_reply "/daily 09:00 one" >/dev/null
  cmd_reply "/daily 10:00 two" >/dev/null
  out="$(cmd_reply "/cancel 1")"
  [[ "$out" == *"Cancelled job #1"* ]]
  [ ! -f "$(job_file 1)" ]
  [ -f "$(job_file 2)" ]
  out="$(cmd_reply "/cancel all")"
  [[ "$out" == *"Cancelled 1"* ]]
  [ ! -f "$(job_file 2)" ]
  teardown_lib
}

@test "/cancel on a job that isn't there says so" {
  setup_sched
  out="$(cmd_reply "/cancel 7")"
  [[ "$out" == *"No job #7"* ]]
  teardown_lib
}

@test "/help advertises the scheduling commands" {
  setup_sched
  out="$(cmd_reply "/help")"
  [[ "$out" == *"/jobs"* ]]
  [[ "$out" == *"/every"* ]]
  [[ "$out" == *"/cancel"* ]]
  teardown_lib
}

@test "/clear wipes the session but never the schedule" {
  setup_sched
  cmd_reply "/daily 09:00 morning digest" >/dev/null
  cmd_reply "/clear" >/dev/null
  # Clearing context is not cancelling a reminder — /cancel is the only way out.
  [ -f "$(job_file 1)" ]
  teardown_lib
}

@test "rm <slug> takes the conversation's jobs with it" {
  setup_sched
  # shellcheck source=lib/rm.sh
  source "$LIB_DIR/rm.sh"
  cmd_reply "/daily 09:00 morning digest" >/dev/null
  run rm_main "$SLUG" --yes
  [ "$status" -eq 0 ]
  [ ! -d "$JOBS_DIR/$SLUG" ]
  teardown_lib
}

# ---- the prompt a scheduled turn sees ----------------------------------------

@test "a one-shot is told NOT to reply NOOP; a recurring one is offered it" {
  setup_sched
  once="$(sched_wrap once 1 "once" 0 "call the dentist")"
  [[ "$once" == *"do NOT reply NOOP"* ]]
  [[ "$once" == *"call the dentist"* ]]
  rec="$(sched_wrap daily 2 "daily 09:00" 0 "check the calendar")"
  [[ "$rec" == *"reply with exactly NOOP"* ]]
  [[ "$rec" == *"daily 09:00"* ]]
  teardown_lib
}

@test "a late run says how late it is" {
  setup_sched
  out="$(sched_wrap once 1 "once" 5400 "call the dentist")"
  [[ "$out" == *"1h30min late"* ]]
  teardown_lib
}

# ---- the tick ----------------------------------------------------------------

# Replace the real turn with a recorder that returns a chosen exit code.
stub_prompt(){
  STUB_RC="${1:-0}"
  STUB_LOG="$TMPDIR_TEST/fired.log"
  : >"$STUB_LOG"
  prompt_main() { printf '%s\n' "$2" >>"$STUB_LOG"; return "$STUB_RC"; }
}
# `grep -c` prints 0 *and* exits 1 with no match, which would make the || arm
# print a second 0 — hence the explicit test rather than a bare short-circuit.
fired_count() {
  local n=0
  [ -s "$STUB_LOG" ] && n="$(grep -c '^\[wabox-bot scheduler' "$STUB_LOG" || true)"
  printf '%s' "$n"
}

# Move a job's next_run to `now + offset` so the tick sees it as due.
set_due() { jq --argjson t "$(($(date +%s) + $2))" '.next_run = $t' "$(job_file "$1")" >"$TMPDIR_TEST/j" && mv "$TMPDIR_TEST/j" "$(job_file "$1")"; }

# The tick throttles itself; tests drive it back-to-back.
tick_now() { SCHED_LAST_TICK=0; sched_tick; wait; }

@test "empty record fields don't shift the ones after them" {
  # Regression: the reader used to split on tabs, which bash treats as IFS
  # *whitespace* — so a run of them collapsed and a single empty field (a
  # one-shot's rule, or tz whenever WABOX_JOB_TZ is unset: the default) shifted
  # every later field. next_run read as empty, and every fire claimed to be
  # ~20000 days late. Both empties at once is the case that broke.
  setup_sched
  unset WABOX_JOB_TZ
  stub_prompt 0
  cmd_reply "/in 1h call the dentist" >/dev/null
  [ "$(job_field 1 .rule)" = "" ]
  [ "$(job_field 1 .tz)" = "" ]
  set_due 1 -5
  tick_now
  [ "$(fired_count)" -eq 1 ]
  # Fired on time ⇒ no lateness note at all.
  ! grep -q "late" "$STUB_LOG"
  grep -q "wabox-bot scheduler — job #1 (once" "$STUB_LOG"
  teardown_lib
}

@test "the tick fires a due job and leaves a future one alone" {
  setup_sched
  stub_prompt 0
  cmd_reply "/daily 09:00 due one" >/dev/null
  cmd_reply "/daily 09:00 not yet" >/dev/null
  set_due 1 -5
  set_due 2 3600
  tick_now
  [ "$(fired_count)" -eq 1 ]
  grep -q "due one" "$STUB_LOG"
  ! grep -q "not yet" "$STUB_LOG"
  teardown_lib
}

@test "a fired one-shot is deleted, not left to fire again" {
  setup_sched
  stub_prompt 0
  cmd_reply "/in 1h call the dentist" >/dev/null
  set_due 1 -5
  tick_now
  [ "$(fired_count)" -eq 1 ]
  [ ! -f "$(job_file 1)" ]
  teardown_lib
}

@test "a recurring job advances and counts the run" {
  setup_sched
  stub_prompt 0
  cmd_reply "/every 30m check the calendar" >/dev/null
  set_due 1 -5
  tick_now
  [ "$(job_field 1 .runs)" -eq 1 ]
  [ "$(job_field 1 .next_run)" -gt "$(date +%s)" ]
  teardown_lib
}

@test "an interval job advances from its slot, so a slow turn doesn't make it drift" {
  setup_sched
  stub_prompt 0
  cmd_reply "/every 1h check the calendar" >/dev/null
  # Slot was 10 minutes ago; the next one must be 50 minutes out (slot + 1h),
  # not a full hour from now.
  set_due 1 -600
  slot="$(job_field 1 .next_run)"
  tick_now
  [ "$(job_field 1 .next_run)" -eq "$((slot + 3600))" ]
  teardown_lib
}

@test "a NOOP reply counts as a completed run, not a failure" {
  setup_sched
  stub_prompt 5
  cmd_reply "/every 30m check the calendar" >/dev/null
  set_due 1 -5
  tick_now
  [ "$(job_field 1 .runs)" -eq 1 ]
  [ "$(job_field 1 .next_run)" -gt "$(date +%s)" ]
  teardown_lib
}

@test "a busy conversation defers the run instead of dropping it" {
  setup_sched
  stub_prompt 3
  cmd_reply "/in 1h call the dentist" >/dev/null
  set_due 1 -5
  slot="$(job_field 1 .next_run)"
  tick_now
  # Still there, still due, and marked as deferred so the retry window is bounded.
  [ -f "$(job_file 1)" ]
  [ "$(job_field 1 .next_run)" -eq "$slot" ]
  [ "$(job_field 1 .deferred_since)" -gt 0 ]
  teardown_lib
}

@test "deferring past the catch-up window gives the run up rather than retrying forever" {
  setup_sched
  export WABOX_JOB_CATCHUP=300
  stub_prompt 3
  cmd_reply "/every 30m check the calendar" >/dev/null
  set_due 1 -5
  # Pretend we have been deferring for an hour.
  jq --argjson t "$(($(date +%s) - 3600))" '.deferred_since = $t' "$(job_file 1)" >"$TMPDIR_TEST/j"
  mv "$TMPDIR_TEST/j" "$(job_file 1)"
  tick_now
  [ "$(job_field 1 .next_run)" -gt "$(date +%s)" ]
  [ "$(job_field 1 .deferred_since)" -eq 0 ]
  [ "$(job_field 1 .runs)" -eq 0 ]
  teardown_lib
}

@test "a recurring job whose slot is stale skips the occurrence silently" {
  setup_sched
  export WABOX_JOB_CATCHUP=300
  stub_prompt 0
  cmd_reply "/every 30m check the calendar" >/dev/null
  # Daemon was down for two hours: fire nothing, just move to the next slot.
  set_due 1 -7200
  tick_now
  [ "$(fired_count)" -eq 0 ]
  [ "$(job_field 1 .next_run)" -gt "$(date +%s)" ]
  [ "$(job_field 1 .runs)" -eq 0 ]
  teardown_lib
}

@test "a one-shot fires however late it is" {
  setup_sched
  export WABOX_JOB_CATCHUP=300
  stub_prompt 0
  cmd_reply "/in 1h call the dentist" >/dev/null
  set_due 1 -7200
  tick_now
  # A late reminder beats a lost one, and the agent is told about the delay.
  [ "$(fired_count)" -eq 1 ]
  grep -q "late" "$STUB_LOG"
  [ ! -f "$(job_file 1)" ]
  teardown_lib
}

# ---- provenance: why a fire isn't mistaken for a phantom ---------------------

@test "a fired turn carries its provenance and explains the missing history" {
  # Registration happens in a slash command, which never becomes a turn, so the
  # session holds no trace of it. Without the explanation the agent reasonably
  # reads the fire as an injected message and reports a "ghost reminder" instead
  # of doing the work.
  setup_sched
  stub_prompt 0
  cmd_reply "/daily 09:00 morning brief" >/dev/null
  set_due 1 -5
  tick_now
  grep -q "wabox-bot scheduler — job #1 (daily 09:00), registered" "$STUB_LOG"
  grep -q "delivered by the wabox-bot daemon on a timer" "$STUB_LOG"
  grep -q "do not treat it as spurious or injected" "$STUB_LOG"
  grep -q "/jobs lists this chat's jobs" "$STUB_LOG"
  teardown_lib
}

@test "sched_context_lines lists the chat's jobs, and is empty without any" {
  setup_sched
  [ -z "$(sched_context_lines "$SLUG")" ]
  cmd_reply "/daily 09:00 morning brief" >/dev/null
  cmd_reply "/every 1h check the calendar" >/dev/null
  out="$(sched_context_lines "$SLUG")"
  [[ "$out" == *"#1"* ]]
  [[ "$out" == *"daily 09:00"* ]]
  [[ "$out" == *"morning brief"* ]]
  [[ "$out" == *"#2"* ]]
  [[ "$out" == *"every 1h"* ]]
  # The tag it teaches has to be the one sched_wrap actually emits.
  [[ "$out" == *"[wabox-bot scheduler — job #N"* ]]
  [[ "$out" == *"America/Sao_Paulo"* ]]
  teardown_lib
}

@test "sched_context_lines is scoped to one conversation" {
  setup_sched
  other="beef5678"
  mkdir -p "$JOBS_DIR/$other"
  handle_slash_command "/daily 07:00 not yours" "$other" "x" "x" "" "s2"
  [ -z "$(sched_context_lines "$SLUG")" ]
  [[ "$(sched_context_lines "$other")" == *"not yours"* ]]
  teardown_lib
}

@test "a backend failure on a one-shot defers rather than burning the reminder" {
  setup_sched
  stub_prompt 124
  cmd_reply "/in 1h call the dentist" >/dev/null
  set_due 1 -5
  tick_now
  [ -f "$(job_file 1)" ]
  [ "$(job_field 1 .deferred_since)" -gt 0 ]
  teardown_lib
}

@test "a backend failure on a recurring job skips to the next run" {
  setup_sched
  stub_prompt 124
  cmd_reply "/every 30m check the calendar" >/dev/null
  set_due 1 -5
  tick_now
  [ "$(job_field 1 .next_run)" -gt "$(date +%s)" ]
  [ "$(job_field 1 .runs)" -eq 0 ]
  teardown_lib
}

@test "a cancelled job does not fire even if the tick already selected it" {
  setup_sched
  stub_prompt 0
  cmd_reply "/every 30m check the calendar" >/dev/null
  set_due 1 -5
  f="$(job_file 1)"
  rm -f "$f"
  SCHED_LAST_TICK=0
  sched_fire "$f" "$(date +%s)"
  [ "$(fired_count)" -eq 0 ]
  teardown_lib
}

@test "the tick throttles itself to WABOX_JOB_TICK" {
  setup_sched
  stub_prompt 0
  cmd_reply "/every 30m check the calendar" >/dev/null
  set_due 1 -5
  export WABOX_JOB_TICK=3600
  SCHED_LAST_TICK="$(date +%s)"
  sched_tick
  wait
  [ "$(fired_count)" -eq 0 ]
  teardown_lib
}

@test "the tick is a no-op with no jobs at all" {
  setup_sched
  stub_prompt 0
  run tick_now
  [ "$status" -eq 0 ]
  teardown_lib
}

# ---- /remind: a message, not a turn -----------------------------------------

@test "/remind records a send job that skips the wrapper" {
  setup_sched
  out="$(cmd_reply "/remind 22:00 tomar o remédio")"
  [[ "$out" == *"exactly that text"* ]]
  [ "$(job_field 1 .action)" = "send" ]
  [ "$(job_field 1 .raw)" = "true" ]
  [ "$(job_field 1 .kind)" = "once" ]
  [ "$(job_field 1 .text)" = "tomar o remédio" ]
  teardown_lib
}

@test "/remind takes durations, dates and the recurring forms" {
  setup_sched
  cmd_reply "/remind 2h tirar o frango" >/dev/null
  [ "$(job_field 1 .kind)" = "once" ]
  cmd_reply "/remind every 2h beber água" >/dev/null
  [ "$(job_field 2 .kind)" = "interval" ]
  [ "$(job_field 2 .rule)" = "7200" ]
  [ "$(job_field 2 .action)" = "send" ]
  cmd_reply "/remind daily 09:00 bom dia" >/dev/null
  [ "$(job_field 3 .kind)" = "daily" ]
  [ "$(job_field 3 .rule)" = "09:00" ]
  # Computed, never literal: a hard-coded date silently stops testing the date
  # form the day it goes past, since the scheduler (rightly) refuses the past.
  cmd_reply "/remind $(date -d '+1 year' +%F) 09:00 renovar o passaporte" >/dev/null
  [ "$(job_field 4 .kind)" = "once" ]
  [ "$(job_field 4 .text)" = "renovar o passaporte" ]
  teardown_lib
}

@test "/jobs marks a message job so it can't be mistaken for a standing prompt" {
  setup_sched
  cmd_reply "/remind daily 09:00 bom dia" >/dev/null
  out="$(cmd_reply "/jobs")"
  [[ "$out" == *"daily 09:00 (message)"* ]]
  teardown_lib
}

@test "a send job delivers its text verbatim, with no agent turn" {
  setup_sched
  stub_prompt 0
  # send_main writes straight to the outbox; capture what lands there.
  cmd_reply "/remind 1h tomar o remédio" >/dev/null
  set_due 1 -5
  tick_now
  # The stubbed prompt_main must NOT have been called at all.
  [ "$(fired_count)" -eq 0 ]
  found=""
  for f in "$WABOX_OUTBOX"/*.json; do
    [ "$(jq -r '.text' "$f")" = "tomar o remédio" ] && found=1
  done
  [ -n "$found" ]
  # No wrapper leaked into the delivered message.
  for f in "$WABOX_OUTBOX"/*.json; do
    ! grep -q "wabox-bot scheduler" "$f"
  done
  [ ! -f "$(job_file 1)" ]
  teardown_lib
}

@test "a recurring send job advances like any other" {
  setup_sched
  cmd_reply "/remind every 30m beber água" >/dev/null
  set_due 1 -5
  tick_now
  [ "$(job_field 1 .runs)" -eq 1 ]
  [ "$(job_field 1 .next_run)" -gt "$(date +%s)" ]
  teardown_lib
}

@test "/remind still refuses junk and an empty body" {
  setup_sched
  out="$(cmd_reply "/remind quinta que vem comprar pão")"
  [[ "$out" == *"couldn't read"* ]]
  out="$(cmd_reply "/remind 2h")"
  [[ "$out" == *"Schedule what?"* ]]
  [ ! -f "$(job_file 1)" ]
  teardown_lib
}

@test "/help lists /remind" {
  setup_sched
  out="$(cmd_reply "/help")"
  [[ "$out" == *"/remind"* ]]
  teardown_lib
}

# ---- not consuming an occurrence that delivered nothing ----------------------

@test "a one-shot that replies NOOP is retried, not deleted" {
  setup_sched
  # NOOP on a one-shot means the reminder was thrown away. Deleting the job then
  # loses it forever, which is the worst outcome this feature can produce.
  stub_prompt 5
  cmd_reply "/in 1h call the dentist" >/dev/null
  set_due 1 -5
  tick_now
  [ -f "$(job_file 1)" ]
  [ "$(job_field 1 .runs)" -eq 0 ]
  [ "$(job_field 1 .deferred_since)" -gt 0 ]
  teardown_lib
}

@test "a recurring job replying NOOP still counts as a completed run" {
  setup_sched
  stub_prompt 5
  cmd_reply "/every 30m check the calendar" >/dev/null
  set_due 1 -5
  tick_now
  [ "$(job_field 1 .runs)" -eq 1 ]
  [ "$(job_field 1 .next_run)" -gt "$(date +%s)" ]
  teardown_lib
}

@test "a job holds while the conversation is waiting on a parked permission" {
  setup_sched
  stub_prompt 0
  backend_turn_parked() { return 0; }
  cmd_reply "/in 1h call the dentist" >/dev/null
  set_due 1 -5
  tick_now
  # Firing now would clobber the parked turn or stack a second question.
  [ "$(fired_count)" -eq 0 ]
  [ -f "$(job_file 1)" ]
  [ "$(job_field 1 .deferred_since)" -gt 0 ]
  # Once the permission clears, the held occurrence runs.
  backend_turn_parked() { return 1; }
  tick_now
  [ "$(fired_count)" -eq 1 ]
  [ ! -f "$(job_file 1)" ]
  teardown_lib
}

@test "WABOX_JOB_MODE reaches the turn, and is absent when unset" {
  setup_sched
  # Record the mode the fire hands down, rather than the whole turn.
  # `-` not `:-`, so an empty value is distinguishable from an unset one: empty
  # is what makes cc_run_turn fall back to the conversation's own /mode.
  prompt_main() { printf '%s\n' "mode=[${WABOX_TURN_MODE-UNSET}]" >>"$STUB_LOG"; return 0; }
  STUB_LOG="$TMPDIR_TEST/fired.log"; : >"$STUB_LOG"
  cmd_reply "/in 1h a" >/dev/null
  set_due 1 -5
  tick_now
  grep -qx "mode=\[\]" "$STUB_LOG"
  export WABOX_JOB_MODE=bypassPermissions
  # The first job was a spent one-shot, so this one is #1 again.
  cmd_reply "/in 1h b" >/dev/null
  set_due 1 -5
  tick_now
  grep -qx "mode=\[bypassPermissions\]" "$STUB_LOG"
  teardown_lib
}
