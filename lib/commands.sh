# Core slash command dispatcher.
#
# handle_slash_command returns:
#   0 — input was a slash command, response has been written to the outbox
#   1 — input is NOT a slash command (caller should hand off to backend_reply)
#
# Core owns /clear, /reset, /ping, /status, /help, /update. Everything else is offered
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
    /memory)
      # Read-only window into the conversation's durable memory (MEMORY.md in
      # the workdir — survives /clear, one file per conversation). Works for
      # every backend; it's just a file. Resolve the path WITHOUT creating the
      # dir (workdir_info's second line), so /memory never materializes a
      # workdir as a side effect. Editing stays in chat or $EDITOR on the file.
      local mem_dir mem_file mem_content fence='```'
      mem_dir="$(workdir_info "$slug" | tail -n1)"
      mem_file="$mem_dir/MEMORY.md"
      if [[ ! -s "$mem_file" ]]; then
        reply_path="$(write_outbox "$to" "Sem memória ainda." "$id" "$stem")"
        log_info "[$stem] /memory (empty) → $reply_path"
        return 0
      fi
      mem_content="$(cat -- "$mem_file")"
      # Cap the reply so a large MEMORY.md can't blow past WhatsApp's message
      # limit; point at the file on disk for the full text.
      if ((${#mem_content} > 3000)); then
        mem_content="${mem_content:0:3000}
… (arquivo completo em $mem_file)"
      fi
      # Monospace-wrap so WhatsApp shows the raw markdown, not a rendering of it.
      reply_path="$(write_outbox "$to" "$fence
$mem_content
$fence" "$id" "$stem")"
      log_info "[$stem] /memory → $reply_path"
      return 0
      ;;
    /status)
      local status_text
      status_text="Status:
conv:    $conv_key
backend: $(backend_name)
workdir: $(workdir_display "$slug")"
      if declare -f backend_status_lines >/dev/null; then
        status_text+="
$(backend_status_lines "$slug")"
      fi
      # Surface the cached startup update check (written by update_startup_notice)
      # without a live network call on every /status.
      if [[ -s "$STATE_DIR/update-available" ]]; then
        status_text+="
update:  v$(cat -- "$STATE_DIR/update-available") available — send /update now"
      fi
      reply_path="$(write_outbox "$to" "$status_text" "$id" "$stem")"
      log_info "[$stem] /status → $reply_path"
      return 0
      ;;
    /help)
      local help_text="Available commands:
/clear           forget this conversation and start fresh
/status          show session id, model, mode, system prompt
/cwd <path>      set this conversation's working folder (/cwd default to reset)
/memory          show what the agent remembers (MEMORY.md)
/update          check for a newer wabox-bot release (/update now to apply)
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
    /cwd)
      if [[ -z "$cmd_args" ]]; then
        reply_path="$(write_outbox "$to" \
          "Working folder: $(workdir_display "$slug")
Usage:
  /cwd <path>     set this conversation's working folder (absolute or ~)
  /cwd default    revert to the auto per-conversation folder" \
          "$id" "$stem")"
        log_info "[$stem] /cwd (show) → $reply_path"
        return 0
      fi
      if [[ "$cmd_args" == "default" || "$cmd_args" == "clear" ]]; then
        (
          exec 8>"$LOCKS_DIR/$slug.lock"
          flock -x 8
          rm -f -- "$(conversation_dir "$slug")/workdir"
        )
        reply_path="$(write_outbox "$to" \
          "Working folder reset to the auto per-conversation folder." \
          "$id" "$stem")"
        log_info "[$stem] /cwd default → $reply_path"
        return 0
      fi
      local cwd_path
      cwd_path="$(expand_tilde "$cmd_args")"
      if [[ "$cwd_path" != /* ]]; then
        reply_path="$(write_outbox "$to" \
          "Working folder must be an absolute path or start with ~ (got: $cmd_args)." \
          "$id" "$stem")"
        log_warn "[$stem] /cwd rejected non-absolute path=$cmd_args → $reply_path"
        return 0
      fi
      if [[ ! -e "$cwd_path" ]]; then
        reply_path="$(write_outbox "$to" \
          "No such directory: $cwd_path" \
          "$id" "$stem")"
        log_warn "[$stem] /cwd rejected missing dir=$cwd_path → $reply_path"
        return 0
      fi
      if [[ ! -d "$cwd_path" ]]; then
        reply_path="$(write_outbox "$to" \
          "Not a directory: $cwd_path" \
          "$id" "$stem")"
        log_warn "[$stem] /cwd rejected non-dir=$cwd_path → $reply_path"
        return 0
      fi
      (
        exec 8>"$LOCKS_DIR/$slug.lock"
        flock -x 8
        mkdir -p "$(conversation_dir "$slug")"
        printf '%s\n' "$cwd_path" >"$(conversation_dir "$slug")/workdir"
      )
      reply_path="$(write_outbox "$to" \
        "Working folder for this conversation set to: $cwd_path" \
        "$id" "$stem")"
      log_info "[$stem] /cwd → $cwd_path → $reply_path"
      return 0
      ;;
    /update)
      # Gate the self-update behind an opt-out toggle: it runs `git reset --hard`
      # on the install, so an instance exposed to untrusted chats can disable it.
      if [[ "${WABOX_BOT_ALLOW_REMOTE_UPDATE:-1}" != 1 ]]; then
        reply_path="$(write_outbox "$to" \
          "Self-update over WhatsApp is disabled on this instance (WABOX_BOT_ALLOW_REMOTE_UPDATE=0)." \
          "$id" "$stem")"
        log_info "[$stem] /update refused (remote update disabled) → $reply_path"
        return 0
      fi
      local upd_latest upd_rc=0 upd_msg
      upd_latest="$(update_check)" || upd_rc=$?
      case "$cmd_args" in
        now | yes | sim | apply | confirm)
          # Applying only rewrites the files on disk; this already-running daemon
          # keeps executing the old code until it's restarted — say so plainly.
          local upd_out upd_arc=0
          upd_out="$(update_apply)" || upd_arc=$?
          if ((upd_arc == 0)); then
            upd_msg="Updated to v$(wabox_bot_version). Restart the daemon for it to take effect (it's still running the old code until then)."
            log_info "[$stem] /update now → applied v$(wabox_bot_version)"
          else
            upd_msg="Update failed.
$upd_out"
            log_warn "[$stem] /update now failed (rc=$upd_arc)"
          fi
          ;;
        "" | check | status)
          case "$upd_rc" in
            0)  upd_msg="wabox-bot v$(wabox_bot_version) is up to date." ;;
            10) upd_msg="A newer version is available: v$upd_latest (you have v$(wabox_bot_version)).
Reply /update now to apply it. (Takes effect after the daemon restarts.)" ;;
            *)  upd_msg="Couldn't check for updates right now (offline?). Reply /update now to try applying anyway." ;;
          esac
          ;;
        *)
          upd_msg="Usage:
/update          check for a newer release
/update now      download and apply it"
          ;;
      esac
      reply_path="$(write_outbox "$to" "$upd_msg" "$id" "$stem")"
      log_info "[$stem] /update ($cmd_args) → $reply_path"
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
