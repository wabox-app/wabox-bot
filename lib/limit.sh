# shellcheck shell=bash
# Usage limits: the backend's account ran out of quota until a known time.
#
# A subscription login ("You've hit your session limit · resets 11am (…)") fails
# every turn, instantly, until the reset. Treated as an ordinary error, that
# went badly: the scheduler retried a due reminder on every tick (182 calls in
# an hour on one install), then gave the one-shot up an hour *before* the limit
# lifted, so the reminder was never delivered. A limit is not a failure of the
# turn, it's a wall with a known end, so the backend reports it with its own
# exit code and the time it lifts, and callers wait for that instead.
#
# The limit belongs to the account, not to a conversation, so the record is one
# daemon-wide file. It is kept after it expires: the scheduler measures a held
# job's lateness from when the limit lifted (see sched_fire).

# Exit code a backend returns for "rate/usage limited" — EX_TEMPFAIL.
LIMIT_RC=75
LIMIT_FILE="${LIMIT_FILE:-$STATE_DIR/limit}"
# When a limit's message names no reset time we can read, wait this long
# before trying again rather than not at all.
WABOX_LIMIT_RETRY="${WABOX_LIMIT_RETRY:-900}"
[[ "$WABOX_LIMIT_RETRY" =~ ^[0-9]+$ ]] && ((WABOX_LIMIT_RETRY > 0)) || WABOX_LIMIT_RETRY=900

# limit_text_matches <text> — rc 0 when <text> is a usage-limit message.
# Covers the current wording ("hit your session/weekly/usage limit") and the
# older "usage limit reached|<epoch>".
limit_text_matches() {
  # Bash's own matcher rather than grep: grep's flavour varies by host (ugrep
  # rejects patterns GNU grep takes), and a grep error must not read as "no".
  local text="${1,,}" re='hit your [a-z ]*limit|usage limit reached|limit[^a-z0-9]+resets'
  [[ "$text" =~ $re ]]
}

# limit_parse_reset <text> [now] — echo the epoch the limit lifts, read from
# the message, or nothing when it names none. "resets 11am (America/Sao_Paulo)"
# is a wall-clock time in that zone, today or — once that has passed — tomorrow;
# "resets Oct 9, 5pm (…)" carries its own date.
limit_parse_reset() {
  local text="$1" now="${2:-$(date +%s)}"
  if [[ "$text" =~ \|([0-9]{9,11}) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  local re='resets[[:space:]]+(at[[:space:]]+)?([^("]+)[(]([A-Za-z_/+-]+)[)]'
  [[ "$text" =~ $re ]] || return 0
  local when="${BASH_REMATCH[2]}" zone="${BASH_REMATCH[3]}" at
  when="${when//,/}"
  when="${when%"${when##*[![:space:]]}"}"
  # An unknown zone is UTC to date(1) — wrong by hours, silently. Same check
  # lib/tz.sh applies to /tz.
  [[ -e "/usr/share/zoneinfo/$zone" ]] || zone=""
  # A bare time is on <now>'s day in that zone — anchored explicitly, since
  # date(1) would otherwise read it against the wall clock — or, once that has
  # passed, the next day's.
  local dated=0
  [[ "$when" =~ [A-Za-z]{3}[a-z]*[[:space:]]+[0-9] ]] && dated=1
  if ((!dated)); then
    when="$(TZ="${zone:-UTC}" date -d "@$now" +%F) $when"
  fi
  at="$(TZ="${zone:-UTC}" date -d "$when" +%s 2>/dev/null)" || return 0
  [[ -n "$at" ]] || return 0
  if ((at <= now && !dated)); then
    at=$((at + 86400))
  fi
  printf '%s' "$at"
}

# limit_hit <text> — record a limit from the backend's message. Echoes the
# epoch it lifts.
limit_hit() {
  local text="$1" now until
  now="$(date +%s)"
  until="$(limit_parse_reset "$text" "$now")"
  # A reset in the past, or absurdly far off, is a misread; fall back.
  if [[ -z "$until" ]] || ((until <= now || until > now + 8 * 86400)); then
    until=$((now + WABOX_LIMIT_RETRY))
  fi
  local tmp="$LIMIT_FILE.tmp.$$"
  jq -cn --argjson until "$until" --argjson at "$now" --arg text "$text" \
    '{until: $until, at: $at, text: $text}' >"$tmp" && mv -- "$tmp" "$LIMIT_FILE"
  log_warn "usage limit hit; holding until $(date -d "@$until" '+%Y-%m-%d %H:%M %Z'): $text"
  printf '%s' "$until"
}

# limit_until — echo the epoch the last recorded limit lifts (past or future),
# or nothing when none was ever recorded.
limit_until() {
  [[ -s "$LIMIT_FILE" ]] || return 0
  jq -r '.until // empty' "$LIMIT_FILE" 2>/dev/null || true
}

# limit_active [now] — rc 0 while a recorded limit is still in force.
limit_active() {
  local now="${1:-$(date +%s)}" until
  until="$(limit_until)"
  [[ -n "$until" ]] && ((now < until))
}

# limit_when_label <tz> — "11:00", or "Thu 09/10 11:00" when not today, in the
# conversation's zone: the user reads it, so it's their clock.
limit_when_label() {
  local tz="$1" until today day
  until="$(limit_until)"
  [[ -n "$until" ]] || return 0
  today="$(_limit_date "$tz" '+%F')"
  day="$(_limit_date "$tz" -d "@$until" '+%F')"
  if [[ "$day" == "$today" ]]; then
    _limit_date "$tz" -d "@$until" '+%H:%M'
  else
    _limit_date "$tz" -d "@$until" '+%a %d/%m %H:%M'
  fi
}

# date(1) in <tz>, or in the daemon's own zone when empty — TZ="" means UTC,
# not "inherit".
_limit_date() {
  local tz="$1"
  shift
  if [[ -n "$tz" ]]; then
    TZ="$tz" date "$@"
  else
    date "$@"
  fi
}
