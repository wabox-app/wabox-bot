# shellcheck shell=bash
# Bob Shell backend.
#
# Drives IBM's `bob` CLI (Bob Shell, a gemini-cli derivative) in one-shot mode
# with `-o json`, giving each WhatsApp conversation its own persistent thread.
#
# Bob's session model differs from Claude's: there is no `--session-id` to
# pre-assign. Bob stores sessions *per project* (keyed on the working
# directory) and you reattach with `--resume latest`. That dovetails with how
# wabox-bot already runs every conversation inside its own
# `conversation_workdir "$slug"` — so "latest" in that cwd is *this*
# conversation's last turn, with no cross-talk between conversations. We only
# pass `--resume latest` once a turn has actually created a session (tracked by
# the `started` marker), because resuming with no session present errors out.
#
# Owns the per-conversation `started`, `model`, and `mode` state files for its
# slug. Implements the wabox-bot backend contract:
#
#   backend_name              — short id ("bob")
#   backend_reply             — runs the Bob turn (stdin → stdout)
#   backend_handle_command    — handles /model, /mode; falls through (99) for the rest
#   backend_clear             — drops the session marker on /clear
#   backend_help              — supplies the /help lines for our commands
#   backend_status_lines      — supplies the /status block

# Backend-specific env defaults. Users can still override any of these via
# their shell environment or the wabox-bot config file — these are only
# consulted if the var is unset.
#
# `-o json` is deliberately NOT part of BOB_ARGS: we parse the JSON envelope
# below, so it's hardcoded into the command and can't be overridden away.
BOB_BIN="${BOB_BIN:-bob}"
BOB_ARGS="${BOB_ARGS:---yolo --chat-mode advanced}"
BOB_TIMEOUT="${BOB_TIMEOUT:-180}"

# Bob's chat modes, per `bob --help`. The per-conversation /mode override is
# validated against this closed set before being passed to `--chat-mode`.
BOB_CHAT_MODES="plan code advanced ask"

backend_name() {
  printf 'bob\n'
}

backend_check_dependencies() {
  need "$BOB_BIN"
  need jq
  # Auth is via BOBSHELL_API_KEY; warn (don't die) so the daemon still starts
  # and the failure surfaces as a per-message error rather than a hard exit.
  [[ -n "${BOBSHELL_API_KEY:-}" ]] ||
    log_warn "BOBSHELL_API_KEY is unset — bob turns will fail until it's set"
}

# ---- Per-conversation state files ------------------------------------------
#
# All state lives under $(backend_state_dir "$slug"), which expands to
# $SESSIONS_DIR/<slug>/bob/. Keeping it per-backend means switching backends
# for the same conversation never smushes state together.

# Bob has no addressable session id we can store — we only track *whether* a
# session exists in this conversation's workdir, so we know to pass
# `--resume latest`. The marker is written after the first successful turn.
bob_started_marker() {
  printf '%s' "$(backend_state_dir "$1")/started"
}

bob_has_session() {
  [[ -e "$(bob_started_marker "$1")" ]]
}

bob_mark_started() {
  : >"$(bob_started_marker "$1")"
}

bob_model_for() {
  local f
  f="$(backend_state_dir "$1")/model"
  [[ -s "$f" ]] && cat "$f"
}

bob_save_model_for() {
  local slug="$1" name="$2"
  printf '%s\n' "$name" >"$(backend_state_dir "$slug")/model"
}

bob_mode_for() {
  local f
  f="$(backend_state_dir "$1")/mode"
  [[ -s "$f" ]] && cat "$f"
}

bob_save_mode_for() {
  local slug="$1" name="$2"
  printf '%s\n' "$name" >"$(backend_state_dir "$slug")/mode"
}

# Compose the prompt fed to bob on stdin. With an image we prepend a short
# instruction pointing the agent at the staged file using bob's `@path` file
# reference syntax (path is already relative to the agent's cwd), then the
# caption. Any other media type (audio is transcribed into text upstream)
# passes the text through unchanged.
bob_compose_prompt() {
  local text="$1" media_path="$2" media_type="$3"
  if [[ "$media_type" == "image" && -n "$media_path" ]]; then
    if [[ -n "$text" ]]; then
      printf 'The user sent an image at @%s — view it and respond.\n\n%s' "$media_path" "$text"
    else
      printf 'The user sent an image at @%s — view it and respond.' "$media_path"
    fi
  else
    printf '%s' "$text"
  fi
}

# ---- The Bob turn ----------------------------------------------------------

# backend_reply(slug, conv_key, stem [, media_path [, media_type]]) — stdin = user text, stdout = reply.
# Exit: 0 ok, 124 timed out, anything else = error (caller substitutes a
# user-visible error message).
backend_reply() {
  local slug="$1" conv_key="$2" stem="$3"
  local media_path="${4:-}" media_type="${5:-}"
  local text
  text="$(cat)"

  # Run this turn in the conversation's working folder so the agent's file
  # operations stay isolated per conversation AND bob's per-project session
  # store maps to this conversation. We're already inside the
  # command-substitution subshell that captures backend_reply's output (see
  # lib/inbox.sh), so this cd is scoped to this one turn — no global CWD
  # change, no races between concurrent conversations.
  local workdir
  workdir="$(conversation_workdir "$slug")"
  if ! cd "$workdir"; then
    log_error "[$stem] cannot cd to working folder $workdir"
    return 1
  fi

  local -a cmd=("$BOB_BIN")
  # shellcheck disable=SC2206 # intentional word-splitting of BOB_ARGS
  cmd+=($BOB_ARGS)
  cmd+=(-o json)
  local model_override
  model_override="$(bob_model_for "$slug" || true)"
  if [[ -n "$model_override" ]]; then
    cmd+=(--model "$model_override")
  fi
  local mode_override
  mode_override="$(bob_mode_for "$slug" || true)"
  if [[ -n "$mode_override" ]]; then
    # Comes after BOB_ARGS so it overrides the default --chat-mode there.
    cmd+=(--chat-mode "$mode_override")
  fi
  if bob_has_session "$slug"; then
    cmd+=(--resume latest)
    log_info "[$stem] conv=$conv_key resume latest"
  else
    log_info "[$stem] conv=$conv_key new session"
  fi

  local prompt
  prompt="$(bob_compose_prompt "$text" "$media_path" "$media_type")"
  # Prompt goes on stdin (not argv) so multi-line text and leading dashes
  # can't be mis-parsed as flags. stderr (bob's thinking/progress) is logged.
  local response_json rc=0
  response_json="$(printf '%s' "$prompt" |
    timeout --kill-after=5 "$BOB_TIMEOUT" "${cmd[@]}" 2>>"$LOG_FILE")" || rc=$?

  if ((rc != 0)); then
    # On a plan/auth/usage error bob prints a {"error":{...}} envelope to
    # stdout and exits non-zero; log it to aid debugging, then propagate.
    local errmsg
    errmsg="$(jq -r '.error.message // empty' <<<"$response_json" 2>/dev/null || true)"
    [[ -n "$errmsg" ]] && log_error "[$stem] bob error: $errmsg"
    return "$rc"
  fi

  # A turn completed, so a session now exists in this workdir — record it so
  # the next turn resumes instead of starting over.
  bob_mark_started "$slug"

  jq -r '.response // empty' <<<"$response_json" 2>/dev/null || true
}

# ---- /clear, /help, /status hooks ------------------------------------------

backend_clear() {
  local slug="$1"
  # Drop the marker so the next message starts a fresh bob session. Bob's own
  # session files are keyed on the workdir and not addressable from here;
  # dropping the marker means we stop passing --resume, and "latest"
  # thereafter points at the new session.
  rm -f -- "$(bob_started_marker "$slug")"
}

backend_help() {
  cat <<'EOF'
/model <name>    set per-conversation model
/model default   remove the model override
/mode <name>     set chat mode (plan, code, advanced, ask)
/mode default    remove the mode override (back to advanced)
EOF
}

backend_status_lines() {
  local slug="$1"
  local session_now model_now mode_now
  if bob_has_session "$slug"; then
    session_now="active (resumes latest)"
  else
    session_now="(none — next message starts fresh)"
  fi
  model_now="$(bob_model_for "$slug" || true)"
  mode_now="$(bob_mode_for "$slug" || true)"
  cat <<EOF
session: $session_now
model:   ${model_now:-(default)}
mode:    ${mode_now:-advanced (default)}
EOF
}

# ---- /model, /mode dispatch ------------------------------------------------

# Return 99 from unrecognised commands so the core dispatcher falls through
# to its "unknown command" reply.
backend_handle_command() {
  local cmd_word="$1" cmd_args="$2" slug="$3" conv_key="$4" to="$5" id="$6" stem="$7"
  local reply_path
  case "$cmd_word" in
    /model)
      local model_arg="${cmd_args%%[[:space:]]*}"
      if [[ -z "$model_arg" ]]; then
        local model_now
        model_now="$(bob_model_for "$slug" || true)"
        reply_path="$(write_outbox "$to" \
          "Current model: ${model_now:-(default)}
Usage:
  /model <name>     set per-conversation model
  /model default    remove the override" \
          "$id" "$stem")"
        log_info "[$stem] /model (show) → $reply_path"
        return 0
      fi
      if [[ "$model_arg" == "default" || "$model_arg" == "clear" ]]; then
        (
          exec 8>"$LOCKS_DIR/$slug.lock"
          flock -x 8
          rm -f -- "$(backend_state_dir "$slug")/model"
        )
        reply_path="$(write_outbox "$to" \
          "Model override removed; using bob's default." \
          "$id" "$stem")"
        log_info "[$stem] /model default → $reply_path"
        return 0
      fi
      # Sanity-check the model name before persisting it — we'll pass it
      # straight to `bob --model`, so reject anything that looks like shell
      # metacharacters or an attempt at argument injection.
      if [[ ! "$model_arg" =~ ^[A-Za-z][A-Za-z0-9._-]{0,63}$ ]]; then
        reply_path="$(write_outbox "$to" \
          "Invalid model name: $model_arg" \
          "$id" "$stem")"
        log_warn "[$stem] /model rejected name=$model_arg → $reply_path"
        return 0
      fi
      (
        exec 8>"$LOCKS_DIR/$slug.lock"
        flock -x 8
        bob_save_model_for "$slug" "$model_arg"
      )
      reply_path="$(write_outbox "$to" \
        "Model for this conversation set to: $model_arg" \
        "$id" "$stem")"
      log_info "[$stem] /model → $model_arg → $reply_path"
      return 0
      ;;
    /mode)
      local mode_arg="${cmd_args%%[[:space:]]*}"
      if [[ -z "$mode_arg" ]]; then
        local mode_now
        mode_now="$(bob_mode_for "$slug" || true)"
        reply_path="$(write_outbox "$to" \
          "Current mode: ${mode_now:-advanced (default)}
Usage:
  /mode <name>      set chat mode ($BOB_CHAT_MODES)
  /mode default     remove the override (back to advanced)" \
          "$id" "$stem")"
        log_info "[$stem] /mode (show) → $reply_path"
        return 0
      fi
      if [[ "$mode_arg" == "default" || "$mode_arg" == "clear" ]]; then
        (
          exec 8>"$LOCKS_DIR/$slug.lock"
          flock -x 8
          rm -f -- "$(backend_state_dir "$slug")/mode"
        )
        reply_path="$(write_outbox "$to" \
          "Mode override removed; using the default (advanced)." \
          "$id" "$stem")"
        log_info "[$stem] /mode default → $reply_path"
        return 0
      fi
      # Unlike /model, bob's chat modes are a fixed enum — validate against it
      # rather than a character-class regex, so a typo gets a helpful reply
      # instead of bob rejecting an unknown --chat-mode mid-turn.
      if [[ " $BOB_CHAT_MODES " != *" $mode_arg "* ]]; then
        reply_path="$(write_outbox "$to" \
          "Invalid mode: $mode_arg (choose one of: $BOB_CHAT_MODES)" \
          "$id" "$stem")"
        log_warn "[$stem] /mode rejected name=$mode_arg → $reply_path"
        return 0
      fi
      (
        exec 8>"$LOCKS_DIR/$slug.lock"
        flock -x 8
        bob_save_mode_for "$slug" "$mode_arg"
      )
      reply_path="$(write_outbox "$to" \
        "Mode for this conversation set to: $mode_arg" \
        "$id" "$stem")"
      log_info "[$stem] /mode → $mode_arg → $reply_path"
      return 0
      ;;
    *)
      return 99
      ;;
  esac
}
