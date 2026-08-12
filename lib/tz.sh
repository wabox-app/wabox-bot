# shellcheck shell=bash
# Per-conversation timezone.
#
# The daemon usually runs under systemd with a stripped environment, so its
# local time is UTC while the person it talks to is not. That breaks two
# separate things, and only one of them was ever about the scheduler:
#
#   1. "/daily 09:00" resolves to 09:00 UTC — a message at 6am local;
#   2. the *agent's own clock* is the daemon's, so "amanhã", "hoje à noite" and
#      any `date` it runs are computed in the wrong zone before the scheduler is
#      even involved.
#
# WABOX_JOB_TZ fixes (1) for the whole daemon. This adds a per-conversation
# override on top, settable from the chat with /tz, and the claude-code backend
# exports it into the turn so (2) goes away too.
#
# Resolution order: conversation file > WABOX_JOB_TZ > the daemon's local time
# (an empty zone, which every sched_date call already understands as "don't set
# TZ"). Stored as core per-conversation state next to the /cwd override, because
# the scheduler is core and this outlives any one backend.

tz_file() { printf '%s/tz' "$(conversation_dir "$1")"; }

# The zone for a conversation, or empty for "the daemon's local time".
# An empty slug asks for the daemon-wide default, which is what the startup
# banner wants.
conversation_tz() {
  local slug="${1:-}" f
  if [[ -n "$slug" ]]; then
    f="$(tz_file "$slug")"
    if [[ -s "$f" ]]; then
      cat -- "$f"
      return 0
    fi
  fi
  printf '%s' "${WABOX_JOB_TZ:-}"
}

# A zone is valid only if tzdata actually has it. `TZ=Foo/Bar date` silently
# falls back to UTC, which is the failure mode this whole module exists to
# prevent — so check the database rather than trusting date(1). The character
# class also keeps `..`, absolute paths and shell metacharacters out of a value
# that ends up in an env var.
tz_valid() {
  local zone="$1" dir="${TZDIR:-/usr/share/zoneinfo}"
  [[ -n "$zone" ]] || return 1
  [[ "$zone" =~ ^[A-Za-z][A-Za-z0-9_+-]*(/[A-Za-z0-9_+-]+)*$ ]] || return 1
  [[ -f "$dir/$zone" ]]
}

# What to print when naming the zone: its name, or the daemon's abbreviation
# (BRT, UTC…) when we're just following local time.
tz_label() {
  local zone
  zone="$(conversation_tz "${1:-}")"
  if [[ -n "$zone" ]]; then
    printf '%s' "$zone"
  else
    date +%Z
  fi
}

# Current wall-clock time in a conversation's zone, for confirmations.
tz_now_label() {
  local zone
  zone="$(conversation_tz "${1:-}")"
  if [[ -n "$zone" ]]; then
    TZ="$zone" date '+%H:%M %Z'
  else
    date '+%H:%M %Z'
  fi
}

tz_save() {
  local slug="$1" zone="$2"
  printf '%s\n' "$zone" >"$(tz_file "$slug")"
}

tz_clear() { rm -f -- "$(tz_file "$1")"; }

# Jobs freeze their zone at creation on purpose (changing a setting must not
# move a reminder that is already booked), so a fresh /tz leaves them behind.
# Count them so the reply can say so instead of letting the user find out at 6am.
tz_stale_jobs() {
  local slug="$1" zone="$2" n=0 f
  for f in "$JOBS_DIR/$slug"/*.json; do
    [[ -f "$f" ]] || continue
    [[ "$(jq -r '.tz // ""' "$f" 2>/dev/null)" == "$zone" ]] || n=$((n + 1))
  done
  printf '%d' "$n"
}

# tz_handle_command <cmd_word> <cmd_args> <slug> <conv_key> <to> <id> <stem>
# Same signature and 0/99 contract as the other command handlers.
tz_handle_command() {
  local cmd_word="$1" cmd_args="$2" slug="$3" to="$5" msg_id="$6" stem="$7"
  [[ "$cmd_word" == /tz ]] || return 99

  local arg="${cmd_args%%[[:space:]]*}" reply_path

  if [[ -z "$arg" ]]; then
    local zone
    zone="$(conversation_tz "$slug")"
    local msg
    if [[ -n "$zone" ]]; then
      msg="Timezone: $zone — it's $(tz_now_label "$slug") for you now."
    else
      msg="Timezone: not set, so I use the daemon's clock ($(tz_label "$slug")) — it's $(tz_now_label "$slug") there now.
If that isn't your local time, reminders will land at the wrong hour."
    fi
    msg+="

/tz America/Sao_Paulo   set it
/tz default             follow the daemon again"
    reply_path="$(write_outbox "$to" "$msg" "$msg_id" "$stem")"
    log_info "[$stem] /tz (show) → $reply_path"
    return 0
  fi

  if [[ "$arg" == default || "$arg" == clear || "$arg" == reset ]]; then
    (
      exec 8>"$LOCKS_DIR/$slug.lock"
      flock -x 8
      tz_clear "$slug"
    )
    reply_path="$(write_outbox "$to" \
      "Timezone override removed — back to $(tz_label "$slug") ($(tz_now_label "$slug") now)." \
      "$msg_id" "$stem")"
    log_info "[$stem] /tz default → $reply_path"
    return 0
  fi

  if ! tz_valid "$arg"; then
    local hint=""
    # An offset is the obvious thing to type and the worst thing to accept:
    # tzdata's Etc/GMT+3 is UTC−3, sign inverted by POSIX inheritance, and a
    # zone without a DST rule silently stops tracking the user's clock anyway.
    if [[ "$arg" =~ ^(GMT|UTC)?[+-]?[0-9]{1,2}(:[0-9]{2})?$ ]]; then
      hint="
Offsets are a trap here (tzdata's Etc/GMT+3 means UTC−3, sign inverted, and an
offset can't follow daylight saving). Give me the city name instead — for
UTC−3 that's America/Sao_Paulo."
    fi
    reply_path="$(write_outbox "$to" \
      "I don't know the timezone \"$arg\".$hint

Use a tzdata name like America/Sao_Paulo, Europe/Lisbon or UTC." \
      "$msg_id" "$stem")"
    log_warn "[$stem] /tz rejected zone=$arg → $reply_path"
    return 0
  fi

  (
    exec 8>"$LOCKS_DIR/$slug.lock"
    flock -x 8
    tz_save "$slug" "$arg"
  )

  local msg stale
  msg="Timezone set to $arg — it's $(tz_now_label "$slug") for you now.
New reminders resolve in this zone."
  stale="$(tz_stale_jobs "$slug" "$arg")"
  if ((stale > 0)); then
    msg+="

⚠️ $stale job(s) already scheduled keep the zone they were created with — a
setting change must not silently move a reminder that's already booked. /jobs
shows each one's zone; cancel and re-add any that should follow this one."
  fi
  reply_path="$(write_outbox "$to" "$msg" "$msg_id" "$stem")"
  log_info "[$stem] /tz $arg (stale=$stale) → $reply_path"
  return 0
}
