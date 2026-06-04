# Core slash command dispatcher.
#
# handle_slash_command returns:
#   0 — input was a slash command, response has been written to the outbox
#   1 — input is NOT a slash command (caller should hand off to backend_reply)
#
# Core owns /clear, /reset, /ping, /status, /help. Everything else is offered
# to backend_handle_command, which returns 99 if it doesn't recognise it; the
# dispatcher then writes the canonical "Unknown command" reply.
#
# /help aggregates the core lines with backend_help (if defined).
# /status aggregates "conv:" and "backend:" with backend_status_lines (if defined).
# /clear also calls backend_clear (if defined) so backends can drop their
# per-conversation state inside the same flock.

handle_slash_command() {
  local text="$1" slug="$2" conv_key="$3" to="$4" id="$5" stem="$6"

  if ! [[ "$text" =~ ^/[A-Za-z][A-Za-z0-9_-]*([[:space:]]|$) ]]; then
    return 1
  fi

  # Pull the command word off the front, keep everything else verbatim
  # (newlines included) so /system can take a multi-line prompt.
  local cmd_original cmd_word cmd_args reply_path
  cmd_original="${text%%[[:space:]]*}"
  cmd_word="${cmd_original,,}"
  cmd_args="${text:${#cmd_original}}"
  cmd_args="${cmd_args#"${cmd_args%%[![:space:]]*}"}"
  cmd_args="${cmd_args%"${cmd_args##*[![:space:]]}"}"

  case "$cmd_word" in
    /clear | /reset)
      (
        exec 8>"$LOCKS_DIR/$slug.lock"
        flock -x 8
        if declare -f backend_clear >/dev/null; then
          backend_clear "$slug"
        fi
      )
      reply_path="$(write_outbox "$to" \
        "Conversation cleared. The next message will start a fresh agent session." \
        "$id" "$stem")"
      log_info "[$stem] /clear: dropped session for conv=$conv_key → $reply_path"
      return 0
      ;;
    /ping)
      reply_path="$(write_outbox "$to" "pong" "$id" "$stem")"
      log_info "[$stem] /ping → $reply_path"
      return 0
      ;;
    /status)
      local status_text="Status:
conv:    $conv_key
backend: $(backend_name)"
      if declare -f backend_status_lines >/dev/null; then
        status_text+="
$(backend_status_lines "$slug")"
      fi
      reply_path="$(write_outbox "$to" "$status_text" "$id" "$stem")"
      log_info "[$stem] /status → $reply_path"
      return 0
      ;;
    /help)
      local help_text="Available commands:
/clear           forget this conversation and start fresh
/status          show session id, model, mode, system prompt
/ping            quick liveness check"
      if declare -f backend_help >/dev/null; then
        help_text+="
$(backend_help)"
      fi
      help_text+="
/help            show this message"
      reply_path="$(write_outbox "$to" "$help_text" "$id" "$stem")"
      log_info "[$stem] /help → $reply_path"
      return 0
      ;;
    *)
      if declare -f backend_handle_command >/dev/null; then
        local rc=0
        backend_handle_command "$cmd_word" "$cmd_args" "$slug" "$conv_key" "$to" "$id" "$stem" || rc=$?
        if ((rc == 0)); then
          return 0
        elif ((rc != 99)); then
          log_warn "[$stem] backend command handler exited rc=$rc for $cmd_word"
          return 0
        fi
      fi
      reply_path="$(write_outbox "$to" \
        "Unknown command: ${cmd_word}. Try /help." \
        "$id" "$stem")"
      log_info "[$stem] unknown slash command $cmd_word → $reply_path"
      return 0
      ;;
  esac
}
