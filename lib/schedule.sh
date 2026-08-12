# Scheduled jobs — one-shot and recurring agent turns registered from the chat.
#
# Design: docs/superpowers/specs/2026-08-09-scheduled-jobs-design.md
#
# One job per file: $JOBS_DIR/<slug>/<id>.json, so /jobs scoping and `rm <slug>`
# cleanup are directory operations rather than filters. The daemon's main loop
# calls sched_tick every WABOX_JOB_TICK seconds; a due job fires in a background
# child running the *same* prompt_main an operator or a cron heartbeat would —
# same conversation flock, workdir, send folder, NOOP suppression. The scheduler
# decides only *when* and *what text*, then reads the exit code.
#
# Two scheduler-private locks, so neither ever contends with a live turn:
#   fd 7  $LOCKS_DIR/jobs-<slug>.lock          — id allocation + record writes,
#         which is also what serializes an advancing fire against a /cancel.
#   fd 6  $LOCKS_DIR/jobfire-<slug>-<id>.lock  — one run of a job at a time, so
#         a tick can't launch a second copy of a job that's still thinking.
# The per-conversation lock (fd 8) stays where it always was: inside prompt_main.

# Last tick timestamp. 0 means "scan on the first loop iteration", which is what
# gives us catch-up for jobs that came due while the daemon was down.
SCHED_LAST_TICK=0

# ---- time helpers -----------------------------------------------------------

# Run date(1) under an explicit zone; empty tz ⇒ the daemon's local time. The
# daemon already requires inotifywait (Linux-only), so GNU date's -d is fair game.
sched_date() {
  local tz="$1"
  shift
  if [[ -n "$tz" ]]; then
    TZ="$tz" date "$@"
  else
    date "$@"
  fi
}

# sched_parse_dur <str> → seconds on stdout, rc 1 on junk.
# Accepts 90s / 30m / 2h / 1d / 1w and concatenations (1h30m). A bare integer is
# minutes — on a phone `/in 30` overwhelmingly means half an hour, not 30 seconds.
sched_parse_dur() {
  local s="${1,,}" total=0 n u rest
  [[ -n "$s" ]] || return 1
  if [[ "$s" =~ ^[0-9]+$ ]]; then
    printf '%d' $((10#$s * 60))
    return 0
  fi
  [[ "$s" =~ ^([0-9]+[smhdw])+$ ]] || return 1
  rest="$s"
  while [[ -n "$rest" ]]; do
    [[ "$rest" =~ ^([0-9]+)([smhdw])(.*)$ ]] || return 1
    n="$((10#${BASH_REMATCH[1]}))"
    u="${BASH_REMATCH[2]}"
    rest="${BASH_REMATCH[3]}"
    case "$u" in
      s) total=$((total + n)) ;;
      m) total=$((total + n * 60)) ;;
      h) total=$((total + n * 3600)) ;;
      d) total=$((total + n * 86400)) ;;
      w) total=$((total + n * 604800)) ;;
    esac
  done
  ((total > 0)) || return 1
  printf '%d' "$total"
}

# sched_parse_time <str> → HH:MM (24h) on stdout, rc 1 on junk.
# Forgiving about phone typing: 9, 09, 9:00, 09:00, 9h, 9h30, 0930, 9am, 9:30pm.
sched_parse_time() {
  local s="${1,,}" h m ampm=""
  s="${s// /}"
  [[ -n "$s" ]] || return 1
  if [[ "$s" =~ (am|pm)$ ]]; then
    ampm="${BASH_REMATCH[1]}"
    s="${s%"$ampm"}"
  fi
  if [[ "$s" =~ ^([0-9]{1,2})[:h]([0-9]{1,2})$ ]]; then
    h="${BASH_REMATCH[1]}"
    m="${BASH_REMATCH[2]}"
  elif [[ "$s" =~ ^([0-9]{1,2})h?$ ]]; then
    h="${BASH_REMATCH[1]}"
    m=0
  elif [[ "$s" =~ ^([0-9]{2})([0-9]{2})$ ]]; then
    h="${BASH_REMATCH[1]}"
    m="${BASH_REMATCH[2]}"
  else
    return 1
  fi
  h=$((10#$h))
  m=$((10#$m))
  case "$ampm" in
    am) ((h == 12)) && h=0 ;;
    pm) ((h < 12)) && h=$((h + 12)) ;;
  esac
  ((h >= 0 && h <= 23 && m >= 0 && m <= 59)) || return 1
  printf '%02d:%02d' "$h" "$m"
}

# sched_next_daily <tz> <HH:MM> [after_epoch] → epoch of the next occurrence
# strictly after `after`. Deliberately recomputed as a *wall-clock* time under
# the zone instead of adding 86400, so a daily job stays at its stated hour
# across a DST change rather than drifting by one.
sched_next_daily() {
  local tz="$1" hhmm="$2" after="${3:-}" day cand
  [[ -n "$after" ]] || after="$(date +%s)"
  day="$(sched_date "$tz" -d "@$after" +%F)" || return 1
  cand="$(sched_date "$tz" -d "$day $hhmm" +%s)" || return 1
  if ((cand <= after)); then
    # Advance the *date* on its own and re-resolve the wall-clock time. Rolling
    # the whole string ("$day $hhmm +1 day") looks equivalent and is not: GNU
    # date reads the `+1` in "09:00 +1 day" as a UTC offset, silently shifting
    # the result by an hour instead of by a day.
    day="$(sched_date "$tz" -d "$day +1 day" +%F)" || return 1
    cand="$(sched_date "$tz" -d "$day $hhmm" +%s)" || return 1
  fi
  printf '%d' "$cand"
}

# sched_human_dur <seconds> → "45s" / "20min" / "2h05min" / "1d3h"
sched_human_dur() {
  local s="$1"
  if ((s < 60)); then
    printf '%ds' "$s"
  elif ((s < 3600)); then
    printf '%dmin' $((s / 60))
  elif ((s < 86400)); then
    if (((s % 3600) / 60 == 0)); then
      printf '%dh' $((s / 3600))
    else
      printf '%dh%02dmin' $((s / 3600)) $(((s % 3600) / 60))
    fi
  else
    printf '%dd%dh' $((s / 86400)) $(((s % 86400) / 3600))
  fi
}

# sched_when_label <tz> <epoch> — "today 14:30" / "tomorrow 09:00" / "Sat 12/08 09:00"
sched_when_label() {
  local tz="$1" epoch="$2" today tomorrow day
  today="$(sched_date "$tz" +%F)"
  tomorrow="$(sched_date "$tz" -d tomorrow +%F)"
  day="$(sched_date "$tz" -d "@$epoch" +%F)"
  if [[ "$day" == "$today" ]]; then
    printf 'today %s' "$(sched_date "$tz" -d "@$epoch" +%H:%M)"
  elif [[ "$day" == "$tomorrow" ]]; then
    printf 'tomorrow %s' "$(sched_date "$tz" -d "@$epoch" +%H:%M)"
  else
    sched_date "$tz" -d "@$epoch" '+%a %d/%m %H:%M'
  fi
}

# ---- job records ------------------------------------------------------------

sched_job_file() { printf '%s/%s/%s.json' "$JOBS_DIR" "$1" "$2"; }

# Read a record's scalar fields in one jq, joined by an ASCII unit separator —
# NOT a tab. bash treats tab as IFS *whitespace*, so a run of tabs collapses into
# a single delimiter and one empty field (a one-shot's empty rule, or an unset
# tz — the default) silently shifts every field after it. \x1f is not IFS
# whitespace, so empty fields survive. Field order is shared by every caller.
SCHED_FS=$'\x1f'
sched_fields() {
  jq -r '[.kind, (.rule // ""), (.spec // ""), (.action // "prompt"),
          (.tz // ""), (.next_run // 0)] | map(tostring) | join("\u001f")' "$1"
}

# Next free id for a conversation: max existing + 1. Small integers, because
# /cancel 3 has to be typeable on a phone. Callers hold the fd 7 jobs lock.
sched_next_id() {
  local dir="$JOBS_DIR/$1" f id max=0
  for f in "$dir"/*.json; do
    [[ -f "$f" ]] || continue
    id="${f##*/}"
    id="${id%.json}"
    [[ "$id" =~ ^[0-9]+$ ]] || continue
    ((id > max)) && max="$id"
  done
  printf '%d' $((max + 1))
}

sched_count() {
  local dir="$JOBS_DIR/$1" f n=0
  for f in "$dir"/*.json; do
    [[ -f "$f" ]] && n=$((n + 1))
  done
  printf '%d' "$n"
}

# sched_add <slug> <kind> <rule> <spec> <action> <text> <next_run> → id on stdout.
# rc 2 when the conversation is at WABOX_JOB_MAX (the cap exists because the
# agent can create jobs too, and a loop of them would be expensive and silent).
sched_add() {
  local slug="$1" kind="$2" rule="$3" spec="$4" action="$5" text="$6" next_run="$7"
  # `raw` skips the wrapper at fire time. It travels with action="send" (a
  # message the user reads must not carry the agent preamble) but is separate
  # from it, because a byte-exact *prompt* is a legitimate combination too.
  local raw="${8:-false}"
  local dir="$JOBS_DIR/$slug"
  mkdir -p "$dir"

  local id rc=0
  # Whole allocate-and-write under the jobs lock: two commands arriving together
  # must not compute the same "max + 1".
  id="$(
    exec 7>"$LOCKS_DIR/jobs-$slug.lock"
    flock -x 7
    if (($(sched_count "$slug") >= WABOX_JOB_MAX)); then
      exit 2
    fi
    local new_id tmp
    new_id="$(sched_next_id "$slug")"
    tmp="$dir/.$new_id.tmp.json"
    jq -n \
      --argjson id "$new_id" \
      --arg kind "$kind" --arg rule "$rule" --arg spec "$spec" \
      --arg action "$action" --arg text "$text" \
      --arg tz "$(conversation_tz "$slug")" \
      --argjson next_run "$next_run" \
      --argjson created "$(date +%s)" \
      --argjson raw "$raw" \
      '{id: $id, kind: $kind, rule: $rule, spec: $spec, action: $action,
        text: $text, tz: $tz, raw: $raw, next_run: $next_run, created: $created,
        last_run: 0, runs: 0, deferred_since: 0}' >"$tmp"
    mv "$tmp" "$dir/$new_id.json"
    printf '%s' "$new_id"
  )" || rc=$?
  ((rc == 0)) || return "$rc"
  printf '%s' "$id"
}

# sched_cancel <slug> <id|all> → number removed on stdout.
sched_cancel() {
  local slug="$1" what="$2"
  (
    exec 7>"$LOCKS_DIR/jobs-$slug.lock"
    flock -x 7
    local f n=0
    if [[ "$what" == all ]]; then
      for f in "$JOBS_DIR/$slug"/*.json; do
        [[ -f "$f" ]] || continue
        rm -f -- "$f"
        n=$((n + 1))
      done
    else
      f="$(sched_job_file "$slug" "$what")"
      if [[ -f "$f" ]]; then
        rm -f -- "$f"
        n=1
      fi
    fi
    printf '%d' "$n"
  )
}

# Every job for a conversation as a JSON array, sorted by next run. One jq over
# the whole directory; `input_filename` is not needed since the id is a field.
sched_list_json() {
  local slug="$1" f
  local -a files=()
  for f in "$JOBS_DIR/$slug"/*.json; do
    [[ -f "$f" ]] && files+=("$f")
  done
  if ((${#files[@]} == 0)); then
    printf '[]'
    return 0
  fi
  jq -s 'sort_by(.next_run)' "${files[@]}" 2>/dev/null || printf '[]'
}

# ---- the prompt a scheduled turn actually sees -------------------------------

# The stored text is wrapped so the agent knows it is running unattended. The
# wrapper differs by kind on purpose: a recurring job is offered the NOOP
# sentinel (that's what makes a quiet heartbeat quiet), a one-shot is explicitly
# denied it — NOOP on a reminder would swallow the reminder.
#
# The provenance paragraph is not decoration. Jobs are registered with a slash
# command, which core answers itself and never turns into a backend turn, so the
# session holds no evidence the job was ever created — and /clear wipes the
# session while deliberately keeping the jobs. An unexplained "you set this
# earlier" therefore asks the agent to recall something that provably isn't
# there, and a careful agent reports it as an injected/phantom message instead of
# doing the work. Naming the source, the registration time and *why* there is no
# memory of it is what makes a fire believable; sched_context_lines then makes it
# checkable.
sched_wrap() {
  local kind="$1" id="$2" spec="$3" late="$4" text="$5" tz="${6:-}" created="${7:-0}"
  local noop="${WABOX_PROMPT_NOOP:-NOOP}" late_note="" reg=""
  if ((late > 60)); then
    late_note=" This run is $(sched_human_dur "$late") late (the daemon was down, or this chat was busy) — mention the delay if it changes anything."
  fi
  ((created > 0)) && reg=", registered $(sched_date "$tz" -d "@$created" '+%d/%m %H:%M')"

  local provenance="This is a scheduled turn delivered by the wabox-bot daemon on a timer, not a
message the user just sent. Jobs are registered with a slash command, which core
handles without a turn, so having no record of this one in the conversation is
expected — do not treat it as spurious or injected. /jobs lists this chat's jobs
and /cancel <n> removes one."

  if [[ "$kind" == once ]]; then
    cat <<EOF
[wabox-bot scheduler — job #$id ($spec)$reg]
$provenance
Deliver the reminder below now, as one short WhatsApp-sized message, in the
user's language. Nobody is waiting on a reply, but do NOT reply $noop: that would
silently drop the reminder.$late_note

$text
EOF
  else
    cat <<EOF
[wabox-bot scheduler — job #$id ($spec)$reg]
$provenance
Do the check below and message only if something genuinely needs attention right
now. Nobody is waiting on a reply: if nothing does, reply with exactly $noop and
nothing else — then nothing is sent. Keep any real reply short; this runs on a
schedule.$late_note

$text
EOF
  fi
}

# ---- the runner --------------------------------------------------------------

# Recompute next_run after a run (or a skipped occurrence) and persist, or drop
# a spent one-shot. `fired` (1/0) decides whether run counters move.
# Holds the fd 7 jobs lock so this can't resurrect a job /cancel just deleted.
sched_advance() {
  local file="$1" now="$2" fired="$3"
  (
    exec 7>"$LOCKS_DIR/jobs-$(basename "$(dirname "$file")").lock"
    flock -x 7
    [[ -f "$file" ]] || exit 0

    local kind rule spec action tz next_run
    IFS=$SCHED_FS read -r kind rule spec action tz next_run < <(sched_fields "$file") || true
    [[ -n "$kind" ]] || exit 0

    if [[ "$kind" == once ]]; then
      rm -f -- "$file"
      exit 0
    fi

    local nr="$next_run"
    if [[ "$kind" == interval ]]; then
      # Advance from the *scheduled* time, not from now: a turn that took four
      # minutes must not push an hourly job four minutes later every hour.
      ((rule > 0)) || rule=$WABOX_JOB_MIN_INTERVAL
      while ((nr <= now)); do
        nr=$((nr + rule))
      done
    else
      nr="$(sched_next_daily "$tz" "$rule" "$now")"
    fi

    local tmp="$file.tmp"
    if jq --argjson nr "$nr" --argjson now "$now" --argjson fired "$fired" \
      '.next_run = $nr | .deferred_since = 0
       | if $fired == 1 then .last_run = $now | .runs = ((.runs // 0) + 1) else . end' \
      "$file" >"$tmp"; then
      mv "$tmp" "$file"
    else
      # Leaving the record untouched means the job re-fires next tick rather
      # than silently stopping — noisy beats lost.
      rm -f -- "$tmp"
      log_warn "job: could not rewrite $file; it will be retried"
    fi
  )
}

# A run we could not complete *now* (the chat was mid-turn, or the backend
# errored on a one-shot). Leave next_run alone so the next tick retries — a
# reminder must not vanish because the user happened to be typing — but stamp
# when the deferral started, and give the occupancy up once it exceeds the
# catch-up window rather than retrying forever.
sched_defer() {
  local file="$1" now="$2" reason="$3"
  local slug id since
  id="${file##*/}"
  id="${id%.json}"
  slug="$(basename "$(dirname "$file")")"
  since="$(jq -r '.deferred_since // 0' "$file" 2>/dev/null || printf 0)"

  if ((since > 0 && now - since > WABOX_JOB_CATCHUP)); then
    log_warn "job[$slug#$id] giving up this run after $(sched_human_dur $((now - since))) of $reason"
    sched_advance "$file" "$now" 0
    return 0
  fi
  if ((since == 0)); then
    local tmp="$file.tmp"
    if jq --argjson now "$now" '.deferred_since = $now' "$file" >"$tmp" 2>/dev/null; then
      mv "$tmp" "$file"
    else
      rm -f -- "$tmp"
    fi
  fi
  log_info "job[$slug#$id] deferred ($reason); retrying next tick"
}

# Run one due job. Called as a background child of the main loop.
sched_fire() {
  local file="$1" now="$2"
  local id slug
  id="${file##*/}"
  id="${id%.json}"
  slug="$(basename "$(dirname "$file")")"

  # One run of a job at a time. A job that outlives its own interval must not
  # stack up copies of itself; -n so we simply skip this tick.
  exec 6>"$LOCKS_DIR/jobfire-$slug-$id.lock"
  if ! flock -n 6; then
    log_debug "job[$slug#$id] previous run still going; skipping this tick"
    exec 6>&-
    return 0
  fi

  # Re-read under the fire lock: the job may have been cancelled between the
  # scan and now, or already advanced by another run.
  if [[ ! -f "$file" ]]; then
    exec 6>&-
    return 0
  fi
  local kind rule spec action tz next_run text
  IFS=$SCHED_FS read -r kind rule spec action tz next_run < <(sched_fields "$file") || true
  if [[ -z "$kind" ]]; then
    log_warn "job[$slug#$id] unreadable record; skipping"
    exec 6>&-
    return 0
  fi
  # Not folded into sched_fields: its field order is shared by three readers and
  # `read` would fold a trailing seventh field into next_run.
  local created
  text="$(jq -r '.text' "$file")"
  created="$(jq -r '.created // 0' "$file")"
  if ((next_run > now)); then
    exec 6>&-
    return 0
  fi

  local late=$((now - next_run))

  # Missed-run policy: a recurring job whose slot is stale skips the occurrence
  # entirely, so a laptop asleep overnight doesn't wake to eight hourly checks.
  # A one-shot always fires, however late — see sched_wrap's delay note.
  if [[ "$kind" != once ]] && ((late > WABOX_JOB_CATCHUP)); then
    log_info "job[$slug#$id] skipping a missed run ($(sched_human_dur "$late") late)"
    sched_advance "$file" "$now" 0
    exec 6>&-
    return 0
  fi

  # Never fire into a parked permission. The conversation is waiting on the
  # user, and a turn now would either clobber that parked state or stack a
  # second question on top of it. Optional hook: backends without permission
  # gating don't define it.
  if declare -F backend_turn_parked >/dev/null && backend_turn_parked "$slug"; then
    log_info "job[$slug#$id] holding: the conversation is waiting on a permission"
    sched_defer "$file" "$now" "a permission is parked"
    exec 6>&-
    return 0
  fi

  local body
  if [[ "$(jq -r '.raw // false' "$file")" == true ]]; then
    body="$text"
  else
    body="$(sched_wrap "$kind" "$id" "$spec" "$late" "$text" "$tz" "$created")"
  fi

  local rc=0
  log_info "job[$slug#$id] firing ($spec, action=$action)"
  if [[ "$action" == send ]]; then
    send_main "$slug" "$body" >/dev/null || rc=$?
  else
    # WABOX_JOB_MODE, when set, overrides the conversation's /mode for this turn
    # only — a job runs unattended, so a tool that parks a yes/no doesn't delay
    # it, it replaces the reminder. Empty ⇒ prompt_main sees nothing and the
    # conversation's own mode applies, which is the old behaviour.
    WABOX_TURN_MODE="${WABOX_JOB_MODE:-}" prompt_main "$slug" "$body" >/dev/null || rc=$?
  fi

  case "$rc" in
    5)
      # The NOOP sentinel — nothing was delivered. For a recurring check that is
      # the feature (a quiet heartbeat stays quiet) and counts as a run. For a
      # one-shot it means the reminder was silently thrown away: the wrapper
      # tells it not to reply NOOP, but if it does anyway, deleting the job is
      # the worst possible outcome. Defer instead, loudly, and let the usual
      # catch-up window bound the retries.
      if [[ "$kind" == once ]]; then
        log_warn "job[$slug#$id] one-shot replied ${WABOX_PROMPT_NOOP:-NOOP} — nothing delivered; retrying"
        sched_defer "$file" "$now" "the reminder was suppressed"
      else
        sched_advance "$file" "$now" 1
      fi
      ;;
    0)
      sched_advance "$file" "$now" 1
      ;;
    3)
      sched_defer "$file" "$now" "the conversation was busy"
      ;;
    *)
      if [[ "$kind" == once ]]; then
        # Don't burn a reminder on a transient backend failure.
        sched_defer "$file" "$now" "backend rc=$rc"
      else
        log_warn "job[$slug#$id] backend rc=$rc; skipping to the next run"
        sched_advance "$file" "$now" 0
      fi
      ;;
  esac
  exec 6>&-
  return 0
}

# Scan for due jobs and fire them. Called from the main loop on every pass and
# throttled here, so the loop stays a one-second loop and the scan doesn't.
# Daemon-only: it forks into CHILDREN (lib/locks.sh) so shutdown drains a job
# that is mid-turn.
sched_tick() {
  local now
  now="$(date +%s)"
  ((now - SCHED_LAST_TICK >= WABOX_JOB_TICK)) || return 0
  SCHED_LAST_TICK="$now"

  local f
  local -a files=()
  for f in "$JOBS_DIR"/*/*.json; do
    [[ -f "$f" ]] && files+=("$f")
  done
  ((${#files[@]} > 0)) || return 0

  # One jq for the whole scan; input_filename gives us back the path of each
  # record that selected. Nothing else in the tick touches the filesystem.
  local -a due=()
  mapfile -t due < <(jq -r --argjson now "$now" \
    'select((.next_run // 0) <= $now) | input_filename' "${files[@]}" 2>/dev/null)
  ((${#due[@]} > 0)) || return 0

  for f in "${due[@]}"; do
    [[ -f "$f" ]] || continue
    sched_fire "$f" "$now" &
    CHILDREN[$!]=1
  done
}

# ---- slash commands ----------------------------------------------------------

# One "#id  spec → when" line plus an indented text line per job, every line
# prefixed by <indent>. Shared by /jobs and the system-prompt fragment, so the
# listing the user reads and the one the agent sees can't drift apart.
sched_render_rows() {
  local jobs="$1" indent="${2:-}"
  local id spec next_run job_tz text
  # Each job renders under the zone it was *created* with, not the current
  # config — otherwise changing WABOX_JOB_TZ would silently relabel (but not
  # move) reminders that are still pinned to their original wall-clock time.
  while IFS=$SCHED_FS read -r id spec next_run job_tz; do
    [[ -n "$id" ]] || continue
    text="$(jq -r --argjson i "$id" '.[] | select(.id == $i) | .text' <<<"$jobs")"
    text="${text//$'\n'/ }"
    ((${#text} > 80)) && text="${text:0:80}…"
    printf '%s#%s  %s → %s\n%s    %s\n' \
      "$indent" "$id" "$spec" "$(sched_when_label "$job_tz" "$next_run")" \
      "$indent" "$text"
  done < <(jq -r '.[] | [.id, .spec, .next_run, (.tz // "")] | map(tostring) | join("\u001f")' <<<"$jobs")
}

# Rendered listing for /jobs.
sched_render_list() {
  local slug="$1" jobs
  jobs="$(sched_list_json "$slug")"
  if [[ "$(jq -r 'length' <<<"$jobs")" == 0 ]]; then
    printf 'No scheduled jobs in this conversation.\n\nSet one with:\n/in 2h <what>\n/at 18:00 <what>\n/every 30m <what to check>\n/daily 09:00 <what to check>'
    return 0
  fi
  printf 'Scheduled jobs (%s):\n%s\n\n/cancel <n> removes one, /cancel all removes them all.' \
    "$(tz_label "$slug")" "$(sched_render_rows "$jobs")"
}

# The conversation's jobs as a system-prompt fragment; prints nothing when it has
# none. This is what makes a fired turn *checkable* rather than merely asserted:
# the agent can match the incoming job id against a list it can see. Registration
# happens in a slash command, which never becomes a turn, and /clear wipes the
# session while deliberately keeping the jobs — so without this the transcript
# holds no evidence a job exists and a fire reads as a phantom (see sched_wrap).
# It doubles as discovery: an agent that can see the list can answer "what have
# you got scheduled for me?" and picks up the grammar by example.
sched_context_lines() {
  local slug="$1" jobs
  jobs="$(sched_list_json "$slug")"
  [[ "$(jq -r 'length' <<<"$jobs")" != 0 ]] || return 0
  cat <<EOF
Scheduled jobs registered in this WhatsApp conversation (wabox-bot's own
scheduler; times in $(tz_label "$slug")):
$(sched_render_rows "$jobs" '  ')
When one comes due the daemon hands it to you as a turn tagged
"[wabox-bot scheduler — job #N ...]". Those are real and expected: the user
registered them here with /in, /at, /every or /daily, which wabox-bot answers
itself without a turn, so nothing about the registration appears in your
history. Never treat such a turn as spurious — check it against the list above.
EOF
}

# Split "<first-token> <rest>" off a command's argument string into two globals.
# Globals rather than stdout on purpose: `rest` keeps its newlines verbatim (a
# standing prompt is often several lines), and `read` would stop at the first one.
SCHED_FIRST=""
SCHED_REST=""
sched_split() {
  local args="$1"
  SCHED_FIRST="${args%%[[:space:]]*}"
  SCHED_REST="${args:${#SCHED_FIRST}}"
  SCHED_REST="${SCHED_REST#"${SCHED_REST%%[![:space:]]*}"}"
}

# sched_handle_command <cmd_word> <cmd_args> <slug> <conv_key> <to> <id> <stem>
# Returns 0 when it handled the command (a reply has been written), 99 when the
# word isn't one of ours — the same contract as backend_handle_command.
# (arg 4, conv_key, is part of the shared command signature but unused here —
# a job is addressed by slug, and the reply goes to `to` like any other command.)
sched_handle_command() {
  local cmd_word="$1" cmd_args="$2" slug="$3" to="$5" msg_id="$6" stem="$7"
  local tz now reply_path
  tz="$(conversation_tz "$slug")"
  now="$(date +%s)"

  case "$cmd_word" in
    /jobs)
      reply_path="$(write_outbox "$to" "$(sched_render_list "$slug")" "$msg_id" "$stem")"
      log_info "[$stem] /jobs → $reply_path"
      return 0
      ;;
    /cancel)
      if [[ -z "$cmd_args" ]]; then
        reply_path="$(write_outbox "$to" \
          "Usage: /cancel <n> (or /cancel all). /jobs lists them." "$msg_id" "$stem")"
        return 0
      fi
      if [[ "$cmd_args" != all && ! "$cmd_args" =~ ^[0-9]+$ ]]; then
        reply_path="$(write_outbox "$to" \
          "Cancel what? Give a job number from /jobs, or 'all'." "$msg_id" "$stem")"
        return 0
      fi
      local removed
      removed="$(sched_cancel "$slug" "$cmd_args")"
      local msg
      if ((removed == 0)); then
        msg="No job #$cmd_args here. /jobs lists what's scheduled."
      elif [[ "$cmd_args" == all ]]; then
        msg="Cancelled $removed scheduled job(s)."
      else
        msg="Cancelled job #$cmd_args."
      fi
      reply_path="$(write_outbox "$to" "$msg" "$msg_id" "$stem")"
      log_info "[$stem] /cancel $cmd_args → removed=$removed → $reply_path"
      return 0
      ;;
    /in | /at | /every | /daily) ;;
    /remind) ;;
    *) return 99 ;;
  esac

  # ---- the four scheduling verbs ----
  local first rest kind rule spec next_run
  # A job either runs a turn (the default) or just delivers its text. `raw`
  # travels with send: the wrapper is instructions addressed to an agent, and
  # delivering it to a human would be gibberish.
  local job_action=prompt job_raw=false

  # /remind is the send-mode twin of the four verbs above, with the same
  # grammar folded into one command: an optional leading `every`/`daily` picks
  # the recurring form, and otherwise a duration means /in and anything else
  # means /at. Rewriting cmd_word here rather than duplicating the parsing keeps
  # one grammar and one set of error messages.
  if [[ "$cmd_word" == /remind ]]; then
    job_action=send
    job_raw=true
    sched_split "$cmd_args"
    case "$SCHED_FIRST" in
      every)
        cmd_word=/every
        cmd_args="$SCHED_REST"
        ;;
      daily)
        cmd_word=/daily
        cmd_args="$SCHED_REST"
        ;;
      *)
        # sched_parse_dur is the discriminator: it takes "2h" and "90" and
        # rejects "18:00" / "9h30" / "2026-08-12", which is exactly /at's half.
        if sched_parse_dur "$SCHED_FIRST" >/dev/null 2>&1; then
          cmd_word=/in
        else
          cmd_word=/at
        fi
        ;;
    esac
  fi

  sched_split "$cmd_args"
  first="$SCHED_FIRST"
  rest="$SCHED_REST"

  local usage="Usage:
/in 2h <what>            once, in a while (30m, 2h, 1d, 1h30m)
/at 18:00 <what>         once, at a time today or tomorrow
/at 2026-08-12 09:00 …   once, on a date
/every 30m <what>        repeating, on an interval
/daily 09:00 <what>      repeating, at a wall-clock time
/remind 22:00 <text>     same times, but sends that text verbatim — no agent
                         turn (also /remind every 2h … and /remind daily 09:00 …)
/jobs · /cancel <n>"

  case "$cmd_word" in
    /in | /every)
      local secs
      if ! secs="$(sched_parse_dur "$first")"; then
        reply_path="$(write_outbox "$to" "I couldn't read \"$first\" as a duration.

$usage" "$msg_id" "$stem")"
        return 0
      fi
      if [[ "$cmd_word" == /every ]]; then
        if ((secs < WABOX_JOB_MIN_INTERVAL)); then
          reply_path="$(write_outbox "$to" \
            "That's too often — the minimum repeat is $(sched_human_dur "$WABOX_JOB_MIN_INTERVAL")." \
            "$msg_id" "$stem")"
          return 0
        fi
        kind=interval
        rule="$secs"
        spec="every $(sched_human_dur "$secs")"
      else
        kind=once
        rule=""
        spec="once"
      fi
      next_run=$((now + secs))
      ;;
    /at)
      local when_date="" hhmm
      if [[ "$first" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        when_date="$first"
        sched_split "$rest"
        first="$SCHED_FIRST"
        rest="$SCHED_REST"
      fi
      if ! hhmm="$(sched_parse_time "$first")"; then
        reply_path="$(write_outbox "$to" "I couldn't read \"$first\" as a time.

$usage" "$msg_id" "$stem")"
        return 0
      fi
      kind=once
      rule=""
      if [[ -n "$when_date" ]]; then
        if ! next_run="$(sched_date "$tz" -d "$when_date $hhmm" +%s 2>/dev/null)"; then
          reply_path="$(write_outbox "$to" "That date doesn't look real: $when_date" "$msg_id" "$stem")"
          return 0
        fi
        if ((next_run <= now)); then
          reply_path="$(write_outbox "$to" \
            "$when_date $hhmm is in the past — I can't schedule backwards." "$msg_id" "$stem")"
          return 0
        fi
        spec="once"
      else
        # A bare time that has already passed today means tomorrow.
        next_run="$(sched_next_daily "$tz" "$hhmm" "$now")"
        spec="once"
      fi
      ;;
    /daily)
      local hhmm
      if ! hhmm="$(sched_parse_time "$first")"; then
        reply_path="$(write_outbox "$to" "I couldn't read \"$first\" as a time.

$usage" "$msg_id" "$stem")"
        return 0
      fi
      kind=daily
      rule="$hhmm"
      spec="daily $hhmm"
      next_run="$(sched_next_daily "$tz" "$hhmm" "$now")"
      ;;
  esac

  if [[ -z "$rest" ]]; then
    reply_path="$(write_outbox "$to" "Schedule what? Put the instruction after the time.

$usage" "$msg_id" "$stem")"
    return 0
  fi

  # `spec` is the human echo in /jobs, so it has to say when a job won't be an
  # agent turn — otherwise a message job and a standing prompt look identical.
  [[ "$job_action" == send ]] && spec="$spec (message)"

  local new_id add_rc=0
  new_id="$(sched_add "$slug" "$kind" "$rule" "$spec" "$job_action" "$rest" "$next_run" "$job_raw")" || add_rc=$?
  if ((add_rc == 2)); then
    reply_path="$(write_outbox "$to" \
      "This conversation already has $WABOX_JOB_MAX scheduled jobs — cancel one first (/jobs)." \
      "$msg_id" "$stem")"
    log_warn "[$stem] $cmd_word refused: job cap reached for $slug"
    return 0
  elif ((add_rc != 0)); then
    reply_path="$(write_outbox "$to" "Couldn't save that job (rc=$add_rc)." "$msg_id" "$stem")"
    log_error "[$stem] $cmd_word failed to save a job for $slug (rc=$add_rc)"
    return 0
  fi

  local confirm
  if [[ "$kind" == once ]]; then
    confirm="Got it — #$new_id, $(sched_when_label "$tz" "$next_run") ($(tz_label "$slug"))."
  else
    confirm="Got it — #$new_id, $spec, first run $(sched_when_label "$tz" "$next_run") ($(tz_label "$slug"))."
  fi
  [[ "$job_action" == send ]] && confirm+=" I'll send exactly that text — no agent turn."
  reply_path="$(write_outbox "$to" "$confirm" "$msg_id" "$stem")"
  log_info "[$stem] $cmd_word → job #$new_id kind=$kind next_run=$next_run → $reply_path"
  return 0
}
