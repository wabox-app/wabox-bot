# Per-envelope handler.
#
# Picks up an inbox envelope, fires the WhatsApp read receipt by moving it
# to PROCESSED_DIR, dispatches slash commands, and otherwise runs the
# Claude turn under a per-conversation flock.

handle_envelope() {
  local in_path="$1"
  local in_name
  in_name="$(basename "$in_path")"
  local stem="${in_name%.json}"

  log_info "[$stem] picked up"

  # ---- Step 1: capture content into memory before touching the FS --------
  local envelope
  if ! envelope="$(cat -- "$in_path" 2>/dev/null)"; then
    log_warn "[$stem] gone before we could read it (already handled?)"
    return 0
  fi
  if ! jq -e . >/dev/null 2>&1 <<<"$envelope"; then
    log_error "[$stem] invalid JSON; quarantining"
    mv -f -- "$in_path" "$PROCESSED_DIR/$in_name.invalid" 2>/dev/null || true
    return 1
  fi

  # ---- Step 2: read media filename (we won't process it here, just move it)
  local media_file
  media_file="$(jq -r '.media.file // empty' <<<"$envelope")"

  # ---- Step 3: MOVE the inbox files out NOW → triggers WhatsApp read tick.
  # Do this *before* calling Claude so the user sees blue checks immediately.
  local staged="$PROCESSED_DIR/$in_name"
  if ! mv -- "$in_path" "$staged" 2>/dev/null; then
    log_warn "[$stem] lost the race to move envelope; another worker has it"
    return 0
  fi
  if [[ -n "$media_file" ]]; then
    local media_src="$WABOX_INBOX/$media_file"
    if [[ -e "$media_src" ]]; then
      mv -- "$media_src" "$PROCESSED_DIR/$media_file" 2>/dev/null ||
        log_warn "[$stem] failed to move media $media_file"
    fi
  fi
  log_debug "[$stem] moved to $PROCESSED_DIR (read receipt fired)"

  # ---- Step 4: extract the bits we need ---------------------------------
  local id from participant text from_me conv_key slug
  id="$(jq -r '.id        // empty' <<<"$envelope")"
  from="$(jq -r '.from    // empty' <<<"$envelope")"
  participant="$(jq -r '.participant // empty' <<<"$envelope")"
  text="$(jq -r '.text    // empty' <<<"$envelope")"
  from_me="$(jq -r '.fromMe // false' <<<"$envelope")"

  if [[ "$IGNORE_FROM_ME" == "1" && "$from_me" == "true" ]]; then
    log_debug "[$stem] skipping fromMe=true"
    return 0
  fi
  if [[ -z "$from" ]]; then
    log_error "[$stem] envelope has no 'from' field; cannot route"
    return 1
  fi

  # Always reply on the exact JID the message arrived on. WhatsApp 1:1 chats
  # can be routed via either `<number>@s.whatsapp.net` or `<lid>@lid`, and
  # each identity has its own Signal session. Replying on the wrong one
  # desyncs the session and the recipient gets stuck on
  # "Waiting for this message" — so we mirror the inbound JID verbatim.
  # Groups (`<gid>@g.us`) carry the right JID in `from` too, so this works
  # uniformly for DMs and groups.
  local to="$from"
  if [[ -z "$to" ]]; then
    log_error "[$stem] envelope has no 'from'; cannot route reply"
    return 1
  fi

  conv_key="$(conversation_key "$envelope")"
  slug="$(key_slug "$conv_key")"

  # Treat empty text as no-op (media-only messages). A real integration
  # would download the media and feed it to Claude here.
  if [[ -z "$text" ]]; then
    log_info "[$stem] empty text (likely media-only); not replying"
    return 0
  fi

  # ---- Step 5: agent-level slash commands -------------------------------
  # /clear and friends manipulate the agent's own state and never reach
  # Claude. We still write a confirmation to the outbox so the sender sees
  # the ack (and the blue ticks already fired when we moved the envelope).
  if [[ "$text" =~ ^/[A-Za-z][A-Za-z0-9_-]*([[:space:]]|$) ]]; then
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
          rm -f -- "$SESSIONS_DIR/$slug.session"
        )
        reply_path="$(write_outbox "$to" \
          "Conversation cleared. The next message will start a fresh Claude session." \
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
        local sid_now model_now mode_now system_now system_info status_text
        sid_now="$(session_id_for "$slug" || true)"
        model_now="$(model_for "$slug" || true)"
        mode_now="$(mode_for "$slug" || true)"
        system_now="$(system_for "$slug" || true)"
        if [[ -z "$system_now" ]]; then
          system_info="(none)"
        else
          system_info="(set, ${#system_now} chars)"
        fi
        status_text="Status:
conv:    $conv_key
session: ${sid_now:-(none — next message starts fresh)}
model:   ${model_now:-(default)}
mode:    ${mode_now:-(default)}
system:  $system_info"
        reply_path="$(write_outbox "$to" "$status_text" "$id" "$stem")"
        log_info "[$stem] /status → $reply_path"
        return 0
        ;;
      /model)
        local model_arg="${cmd_args%%[[:space:]]*}"
        if [[ -z "$model_arg" ]]; then
          local model_now
          model_now="$(model_for "$slug" || true)"
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
            rm -f -- "$SESSIONS_DIR/$slug.model"
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
          save_model_for "$slug" "$model_arg"
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
          mode_now="$(mode_for "$slug" || true)"
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
            rm -f -- "$SESSIONS_DIR/$slug.mode"
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
          save_mode_for "$slug" "$mode_arg"
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
          system_now="$(system_for "$slug" || true)"
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
            rm -f -- "$SESSIONS_DIR/$slug.system"
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
          save_system_for "$slug" "$cmd_args"
        )
        reply_path="$(write_outbox "$to" \
          "System prompt set for this conversation (${#cmd_args} chars)." \
          "$id" "$stem")"
        log_info "[$stem] /system → set (${#cmd_args} chars) → $reply_path"
        return 0
        ;;
      /help)
        reply_path="$(write_outbox "$to" \
          "Available commands:
/clear           forget this conversation and start fresh
/status          show session id, model, mode, system prompt
/ping            quick liveness check
/model <name>    set per-conversation model (opus, sonnet, haiku, or full id)
/model default   remove the model override
/mode <name>     set per-conversation --permission-mode
/mode default    remove the mode override
/system <text>   set per-conversation system prompt (multi-line ok)
/system clear    remove the system prompt
/help            show this message" \
          "$id" "$stem")"
        log_info "[$stem] /help → $reply_path"
        return 0
        ;;
      *)
        reply_path="$(write_outbox "$to" \
          "Unknown command: ${cmd_word}. Try /help." \
          "$id" "$stem")"
        log_info "[$stem] unknown slash command $cmd_word → $reply_path"
        return 0
        ;;
    esac
  fi

  # ---- Step 6: serialize per-conversation, talk to Claude ----------------
  # The flock ensures messages from the *same* sender are processed in order
  # (so the session file doesn't race), while different senders run in
  # parallel via the per-conversation lockfile.
  (
    exec 8>"$LOCKS_DIR/$slug.lock"
    flock -x 8

    local sid_existing sid
    sid_existing="$(session_id_for "$slug" || true)"

    local -a cmd=("$CLAUDE_BIN")
    # shellcheck disable=SC2206 # intentional word-splitting of CLAUDE_ARGS
    cmd+=($CLAUDE_ARGS)
    cmd+=(-p --output-format json)
    if [[ -n "$SYSTEM_PROMPT_FILE" && -r "$SYSTEM_PROMPT_FILE" ]]; then
      cmd+=(--append-system-prompt "$(cat -- "$SYSTEM_PROMPT_FILE")")
    fi
    local model_override
    model_override="$(model_for "$slug" || true)"
    if [[ -n "$model_override" ]]; then
      cmd+=(--model "$model_override")
    fi
    local mode_override
    mode_override="$(mode_for "$slug" || true)"
    if [[ -n "$mode_override" ]]; then
      # Comes after CLAUDE_ARGS so it overrides any --permission-mode there.
      cmd+=(--permission-mode "$mode_override")
    fi
    local system_override
    system_override="$(system_for "$slug" || true)"
    if [[ -n "$system_override" ]]; then
      cmd+=(--append-system-prompt "$system_override")
    fi
    if [[ -n "$sid_existing" ]]; then
      cmd+=(--resume "$sid_existing")
      sid="$sid_existing"
      log_info "[$stem] from=$from conv=$conv_key resume session=$sid_existing"
    else
      sid="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)"
      cmd+=(--session-id "$sid")
      log_info "[$stem] from=$from conv=$conv_key new session=$sid"
    fi

    local response_json reply rc=0
    # stdin = the user's message; stdout = JSON envelope with .result
    response_json="$(printf '%s' "$text" |
      timeout --kill-after=5 "$CLAUDE_TIMEOUT" "${cmd[@]}" 2>>"$LOG_FILE")" ||
      rc=$?

    if ((rc != 0)); then
      if ((rc == 124)); then
        log_error "[$stem] claude timed out after ${CLAUDE_TIMEOUT}s"
        reply="(Sorry — I took too long to think. Please try again.)"
      else
        log_error "[$stem] claude exited rc=$rc"
        reply="(Sorry — I hit an error processing that message.)"
      fi
    else
      reply="$(jq -r '.result // empty' <<<"$response_json" 2>/dev/null || true)"
      # Persist whatever session id Claude reports back (it may rotate)
      local sid_returned
      sid_returned="$(jq -r '.session_id // empty' <<<"$response_json" 2>/dev/null || true)"
      [[ -n "$sid_returned" ]] && sid="$sid_returned"
      save_session_id "$slug" "$sid"
      if [[ -z "$reply" ]]; then
        log_warn "[$stem] claude returned empty .result"
        reply="(no response)"
      fi
    fi

    local out_path
    out_path="$(write_outbox "$to" "$reply" "" "$stem")"
    log_info "[$stem] wrote reply → $out_path (session=$sid)"
  )

  if [[ "$KEEP_PROCESSED" != "1" ]]; then
    rm -f -- "$staged"
    [[ -n "$media_file" ]] && rm -f -- "$PROCESSED_DIR/$media_file"
  fi
}

# Wrap so a crash in one handler can't take down the agent.
safe_handle_envelope() {
  if ! handle_envelope "$1"; then
    log_error "handler failed for $1 (continuing)"
  fi
}
