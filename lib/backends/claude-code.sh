# shellcheck shell=bash
# Claude Code backend.
#
# Drives the `claude` CLI with `-p`, `--output-format json`, and
# `--session-id` / `--resume` so each WhatsApp conversation gets its own
# persistent thread.
#
# Owns the per-conversation `.session`, `.model`, `.mode`, and `.system`
# state files for its slug. Implements the wabox-bot backend contract:
#
#   backend_name              — short id ("claude-code")
#   backend_reply             — runs the Claude turn (stdin → stdout)
#   backend_handle_command    — handles /model, /mode, /system; falls through (99) for the rest
#   backend_clear             — drops the session file on /clear
#   backend_help              — supplies the /help lines for our commands
#   backend_status_lines      — supplies the /status block

# Backend-specific env defaults. Users can still override any of these via
# their shell environment — these are only consulted if the var is unset.
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
CLAUDE_ARGS="${CLAUDE_ARGS:---permission-mode auto}"
CLAUDE_TIMEOUT="${CLAUDE_TIMEOUT:-180}"
SYSTEM_PROMPT_FILE="${SYSTEM_PROMPT_FILE:-}"

backend_name() {
  printf 'claude-code\n'
}

backend_check_dependencies() {
  need "$CLAUDE_BIN"
}

# ---- Per-conversation state files ------------------------------------------
#
# All state lives under $(backend_state_dir "$slug"), which expands to
# $SESSIONS_DIR/<slug>/claude-code/. Switching backends for the same
# conversation doesn't smush state together; legacy flat files are migrated
# into this layout by lib/migrate.sh on first run.

cc_session_id_for() {
  local f
  f="$(backend_state_dir "$1")/session"
  [[ -s "$f" ]] && cat "$f"
}

cc_save_session_id() {
  local slug="$1" sid="$2"
  printf '%s\n' "$sid" >"$(backend_state_dir "$slug")/session"
}

cc_model_for() {
  local f
  f="$(backend_state_dir "$1")/model"
  [[ -s "$f" ]] && cat "$f"
}

cc_save_model_for() {
  local slug="$1" name="$2"
  printf '%s\n' "$name" >"$(backend_state_dir "$slug")/model"
}

cc_mode_for() {
  local f
  f="$(backend_state_dir "$1")/mode"
  [[ -s "$f" ]] && cat "$f"
}

cc_save_mode_for() {
  local slug="$1" name="$2"
  printf '%s\n' "$name" >"$(backend_state_dir "$slug")/mode"
}

# Per-conversation system prompt override. Stored verbatim (no trailing
# newline added) so multi-line prompts round-trip; appended via
# --append-system-prompt on top of any global SYSTEM_PROMPT_FILE.
cc_system_for() {
  local f
  f="$(backend_state_dir "$1")/system"
  [[ -s "$f" ]] && cat "$f"
}

cc_save_system_for() {
  local slug="$1" prompt="$2"
  printf '%s' "$prompt" >"$(backend_state_dir "$slug")/system"
}

# ---- The Claude turn -------------------------------------------------------

# backend_reply(slug, conv_key, stem) — stdin = user text, stdout = reply.
# Exit: 0 ok, 124 timed out, anything else = error (caller substitutes a
# user-visible error message).
backend_reply() {
  local slug="$1" conv_key="$2" stem="$3"
  local text
  text="$(cat)"

  local sid_existing sid
  sid_existing="$(cc_session_id_for "$slug" || true)"

  local -a cmd=("$CLAUDE_BIN")
  # shellcheck disable=SC2206 # intentional word-splitting of CLAUDE_ARGS
  cmd+=($CLAUDE_ARGS)
  cmd+=(-p --output-format json)
  if [[ -n "$SYSTEM_PROMPT_FILE" && -r "$SYSTEM_PROMPT_FILE" ]]; then
    cmd+=(--append-system-prompt "$(cat -- "$SYSTEM_PROMPT_FILE")")
  fi
  local model_override
  model_override="$(cc_model_for "$slug" || true)"
  if [[ -n "$model_override" ]]; then
    cmd+=(--model "$model_override")
  fi
  local mode_override
  mode_override="$(cc_mode_for "$slug" || true)"
  if [[ -n "$mode_override" ]]; then
    # Comes after CLAUDE_ARGS so it overrides any --permission-mode there.
    cmd+=(--permission-mode "$mode_override")
  fi
  local system_override
  system_override="$(cc_system_for "$slug" || true)"
  if [[ -n "$system_override" ]]; then
    cmd+=(--append-system-prompt "$system_override")
  fi
  if [[ -n "$sid_existing" ]]; then
    cmd+=(--resume "$sid_existing")
    sid="$sid_existing"
    log_info "[$stem] conv=$conv_key resume session=$sid_existing"
  else
    sid="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)"
    cmd+=(--session-id "$sid")
    log_info "[$stem] conv=$conv_key new session=$sid"
  fi

  local response_json rc=0
  response_json="$(printf '%s' "$text" |
    timeout --kill-after=5 "$CLAUDE_TIMEOUT" "${cmd[@]}" 2>>"$LOG_FILE")" || rc=$?

  if ((rc != 0)); then
    return "$rc"
  fi

  # Persist whatever session id Claude reports back (it may rotate).
  local sid_returned
  sid_returned="$(jq -r '.session_id // empty' <<<"$response_json" 2>/dev/null || true)"
  [[ -n "$sid_returned" ]] && sid="$sid_returned"
  cc_save_session_id "$slug" "$sid"

  jq -r '.result // empty' <<<"$response_json" 2>/dev/null || true
}

# ---- /clear, /help, /status hooks ------------------------------------------

backend_clear() {
  local slug="$1"
  rm -f -- "$(backend_state_dir "$slug")/session"
}

backend_help() {
  cat <<'EOF'
/model <name>    set per-conversation model (opus, sonnet, haiku, or full id)
/model default   remove the model override
/mode <name>     set per-conversation --permission-mode
/mode default    remove the mode override
/system <text>   set per-conversation system prompt (multi-line ok)
/system clear    remove the system prompt
EOF
}

backend_status_lines() {
  local slug="$1"
  local sid_now model_now mode_now system_now system_info
  sid_now="$(cc_session_id_for "$slug" || true)"
  model_now="$(cc_model_for "$slug" || true)"
  mode_now="$(cc_mode_for "$slug" || true)"
  system_now="$(cc_system_for "$slug" || true)"
  if [[ -z "$system_now" ]]; then
    system_info="(none)"
  else
    system_info="(set, ${#system_now} chars)"
  fi
  cat <<EOF
session: ${sid_now:-(none — next message starts fresh)}
model:   ${model_now:-(default)}
mode:    ${mode_now:-(default)}
system:  $system_info
EOF
}

# ---- /model, /mode, /system dispatch ---------------------------------------

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
        model_now="$(cc_model_for "$slug" || true)"
        reply_path="$(write_outbox "$to" \
          "Current model: ${model_now:-(default)}
Usage:
  /model <name>     set per-conversation model (opus, sonnet, haiku, or full id)
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
          "Model override removed; using Claude's default." \
          "$id" "$stem")"
        log_info "[$stem] /model default → $reply_path"
        return 0
      fi
      # Sanity-check the model name before persisting it — we'll pass it
      # straight to `claude --model`, so reject anything that looks like
      # shell metacharacters or an attempt at argument injection.
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
        cc_save_model_for "$slug" "$model_arg"
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
        mode_now="$(cc_mode_for "$slug" || true)"
        reply_path="$(write_outbox "$to" \
          "Current mode: ${mode_now:-(default from CLAUDE_ARGS)}
Usage:
  /mode <name>      set per-conversation --permission-mode
                    (e.g. plan, acceptEdits, bypassPermissions)
  /mode default     remove the override" \
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
          "Mode override removed; using CLAUDE_ARGS default." \
          "$id" "$stem")"
        log_info "[$stem] /mode default → $reply_path"
        return 0
      fi
      # Same safety check as /model — this gets passed verbatim to
      # `claude --permission-mode`.
      if [[ ! "$mode_arg" =~ ^[A-Za-z][A-Za-z0-9_-]{0,31}$ ]]; then
        reply_path="$(write_outbox "$to" \
          "Invalid mode name: $mode_arg" \
          "$id" "$stem")"
        log_warn "[$stem] /mode rejected name=$mode_arg → $reply_path"
        return 0
      fi
      (
        exec 8>"$LOCKS_DIR/$slug.lock"
        flock -x 8
        cc_save_mode_for "$slug" "$mode_arg"
      )
      reply_path="$(write_outbox "$to" \
        "Mode for this conversation set to: $mode_arg" \
        "$id" "$stem")"
      log_info "[$stem] /mode → $mode_arg → $reply_path"
      return 0
      ;;
    /system)
      # /system takes the *entire rest* of the message (newlines kept),
      # so a multi-line prompt works. The literal tokens "clear" and
      # "default" are reserved for removal — to use one of those as your
      # actual prompt, prepend a space, capitalize, or add punctuation.
      if [[ -z "$cmd_args" ]]; then
        local system_now
        system_now="$(cc_system_for "$slug" || true)"
        if [[ -z "$system_now" ]]; then
          reply_path="$(write_outbox "$to" \
            "No system prompt set for this conversation.
Usage:
  /system <prompt>     set (can span multiple lines)
  /system clear        remove" \
            "$id" "$stem")"
        else
          reply_path="$(write_outbox "$to" \
            "Current system prompt (${#system_now} chars):
$system_now" \
            "$id" "$stem")"
        fi
        log_info "[$stem] /system (show) → $reply_path"
        return 0
      fi
      if [[ "$cmd_args" == "clear" || "$cmd_args" == "default" ]]; then
        (
          exec 8>"$LOCKS_DIR/$slug.lock"
          flock -x 8
          rm -f -- "$(backend_state_dir "$slug")/system"
        )
        reply_path="$(write_outbox "$to" \
          "System prompt removed for this conversation." \
          "$id" "$stem")"
        log_info "[$stem] /system clear → $reply_path"
        return 0
      fi
      (
        exec 8>"$LOCKS_DIR/$slug.lock"
        flock -x 8
        cc_save_system_for "$slug" "$cmd_args"
      )
      reply_path="$(write_outbox "$to" \
        "System prompt set for this conversation (${#cmd_args} chars)." \
        "$id" "$stem")"
      log_info "[$stem] /system → set (${#cmd_args} chars) → $reply_path"
      return 0
      ;;
    *)
      return 99
      ;;
  esac
}
