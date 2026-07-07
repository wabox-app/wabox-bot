# Read-only state snapshot for external tooling (`wabox-bot state --json`).
#
# Emits a single versioned JSON object describing the daemon and every
# conversation. This is the stable contract for tools like wabox-tui; the
# on-disk $STATE_DIR layout stays private and refactorable behind it.
#
# Everything here is a pure read plus non-blocking `flock -n` *probes*
# (acquire-and-release on a private fd) — state never takes a lock a running
# daemon would contend for. The daemon's blocking `flock -x` tolerates a probe
# holding a free lock for microseconds. JSON is assembled with `jq -n`; no
# hand-concatenated strings.
#
# See docs/superpowers/specs/2026-07-06-state-and-answer-design.md for the
# schema and the exit-code contract.

# The default backend fragment used when a backend doesn't implement
# backend_state_json (echo, or any minimal backend).
_STATE_DEFAULT_BACKEND_FRAGMENT='{"session_id":null,"overrides":{"model":null,"mode":null,"system":null},"pending_permission":null}'

# 0 if a daemon holds the single-instance lock, 1 if not. Non-blocking probe on
# a private fd, append-open so the probe can never truncate the daemon's PID.
state_daemon_running() {
  local fd
  exec {fd}>>"$PID_LOCK" || return 1
  if flock -n "$fd"; then
    # Grabbed it ⇒ nobody's holding it ⇒ no daemon. Release and report stopped.
    flock -u "$fd"
    exec {fd}>&-
    return 1
  fi
  exec {fd}>&-
  return 0
}

# 0 if the per-conversation lock for a slug is currently held, 1 otherwise.
state_slug_locked() {
  local f="$LOCKS_DIR/$1.lock"
  [[ -e "$f" ]] || return 1
  local fd
  exec {fd}>>"$f" || return 1
  if flock -n "$fd"; then
    flock -u "$fd"
    exec {fd}>&-
    return 1
  fi
  exec {fd}>&-
  return 0
}

# Build the per-conversation JSON object for one slug directory. Merges the
# core fields (conv_key, workdir, lock probe, last_message) with the backend's
# own fragment (session/overrides/pending_permission), or the null default when
# the backend doesn't implement backend_state_json.
_state_conversation_json() {
  local slug="$1" with_sizes="${2:-0}"

  local conv_key="" has_conv_key=false
  if [[ -s "$SESSIONS_DIR/$slug/conv_key" ]]; then
    conv_key="$(cat -- "$SESSIONS_DIR/$slug/conv_key")"
    has_conv_key=true
  fi

  local is_default workdir winfo
  winfo="$(workdir_info "$slug")"
  is_default="${winfo%%$'\n'*}"
  workdir="${winfo#*$'\n'}"

  local locked=false
  state_slug_locked "$slug" && locked=true

  local last_message='null'
  if [[ -s "$SESSIONS_DIR/$slug/last_message.json" ]] &&
    jq -e . <"$SESSIONS_DIR/$slug/last_message.json" >/dev/null 2>&1; then
    last_message="$(cat -- "$SESSIONS_DIR/$slug/last_message.json")"
  fi

  local backend_frag="$_STATE_DEFAULT_BACKEND_FRAGMENT"
  if declare -F backend_state_json >/dev/null; then
    local candidate
    candidate="$(backend_state_json "$slug")"
    if jq -e . <<<"$candidate" >/dev/null 2>&1; then
      backend_frag="$candidate"
    fi
  fi

  # Sizes are opt-in (--sizes): du -sb per conversation is what makes the plain
  # `state` call slow on large workdirs, so keep it off the fast path. Fields
  # are always present (null without the flag) so the schema stays version: 1.
  # workdir_bytes = the whole conversation folder; botdir_bytes = the reclaimable
  # `.wabox/` share (what gc can prune), so a caller can tell agent content apart
  # from bot plumbing. Read-only: workdir_botdir_path never creates the dir.
  local workdir_bytes=null botdir_bytes=null
  if ((with_sizes)); then
    workdir_bytes="$(dir_bytes "$workdir")"
    botdir_bytes="$(dir_bytes "$(workdir_botdir_path "$workdir")")"
  fi

  jq -n \
    --arg slug "$slug" \
    --arg conv_key "$conv_key" \
    --argjson has_conv_key "$has_conv_key" \
    --arg workdir "$workdir" \
    --argjson is_default "$is_default" \
    --argjson locked "$locked" \
    --argjson last_message "$last_message" \
    --argjson workdir_bytes "$workdir_bytes" \
    --argjson botdir_bytes "$botdir_bytes" \
    --argjson backend "$backend_frag" \
    '{
       slug: $slug,
       conv_key: (if $has_conv_key then $conv_key else null end),
       workdir: $workdir,
       workdir_is_default: $is_default,
       locked: $locked,
       last_message: $last_message,
       workdir_bytes: $workdir_bytes,
       botdir_bytes: $botdir_bytes
     } + $backend'
}

# Emit the whole snapshot on stdout. $1 (0/1) toggles per-conversation sizes.
state_json() {
  local with_sizes="${1:-0}"
  local running=false pid_json=null
  if state_daemon_running; then
    running=true
    local pid
    pid="$(head -n1 -- "$PID_LOCK" 2>/dev/null || true)"
    [[ "$pid" =~ ^[0-9]+$ ]] && pid_json="$pid"
  fi

  local daemon_json
  daemon_json="$(jq -n \
    --argjson running "$running" \
    --argjson pid "$pid_json" \
    --arg version "$(wabox_bot_version)" \
    --arg backend "$(backend_name)" \
    --arg inbox "$WABOX_INBOX" \
    --arg outbox "$WABOX_OUTBOX" \
    --arg state_dir "$STATE_DIR" \
    --arg log_file "$LOG_FILE" \
    '{running: $running, pid: $pid, wabox_bot_version: $version, backend: $backend,
      inbox: $inbox, outbox: $outbox, state_dir: $state_dir, log_file: $log_file}')"

  # One JSON object per conversation, newline-separated, then slurped and sorted
  # by activity (newest first; conversations without a last_message sort last).
  local -a conv_objs=()
  local d slug
  for d in "$SESSIONS_DIR"/*/; do
    slug="$(basename -- "$d")"
    conv_objs+=("$(_state_conversation_json "$slug" "$with_sizes")")
  done

  { ((${#conv_objs[@]})) && printf '%s\n' "${conv_objs[@]}"; } |
    jq -s \
      --argjson daemon "$daemon_json" \
      '{version: 1,
        daemon: $daemon,
        conversations: (sort_by(.last_message.at // -1) | reverse)}'
}

# CLI entry point for the `state` subcommand. `--json` is required; `--sizes`
# additionally populates per-conversation byte counts (opt-in — it runs du).
state_cli() {
  local want_json=0 with_sizes=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) want_json=1; shift ;;
      --sizes) with_sizes=1; shift ;;
      *)
        printf 'wabox-bot state: unknown argument: %s\n' "$1" >&2
        return 1
        ;;
    esac
  done
  if ((!want_json)); then
    printf 'wabox-bot state: --json is required (only JSON output is supported in v1)\n' >&2
    return 1
  fi
  state_json "$with_sizes"
}
