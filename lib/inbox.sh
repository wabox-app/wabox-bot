# Per-envelope handler.
#
# Picks up an inbox envelope, fires the WhatsApp read receipt by moving it
# to PROCESSED_DIR, dispatches slash commands via lib/commands.sh, and
# otherwise hands the user's text to the active backend's backend_reply
# under a per-conversation flock.

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
  # Do this *before* calling the backend so the user sees blue checks immediately.
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
  # (`participant` is parsed inside conversation_key() rather than here so
  # it can pick its own routing strategy without us duplicating the jq.)
  local id from text from_me conv_key slug
  id="$(jq -r '.id     // empty' <<<"$envelope")"
  from="$(jq -r '.from // empty' <<<"$envelope")"
  text="$(jq -r '.text // empty' <<<"$envelope")"
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

  # ---- Step 4b: media handling ------------------------------------------
  # media_file was read in step 2 and the file moved to $PROCESSED_DIR in
  # step 3. Audio is transcribed here (generic → becomes text); an image is
  # staged and passed to the backend by reference. Other types are skipped.
  local media_type media_mime media_rel="" had_media=0
  media_type="$(media_type_of "$envelope")"
  media_mime="$(media_mime_of "$envelope")"
  if [[ -n "$media_type" ]]; then
    had_media=1
    local workdir
    workdir="$(conversation_workdir "$slug")"
    if ! media_rel="$(media_stage "$PROCESSED_DIR/$media_file" "$workdir")"; then
      log_warn "[$stem] media file gone before staging; nothing to process"
      return 0
    fi
    case "$media_type" in
      audio)
        if [[ -z "$WABOX_TRANSCRIBE_CMD" ]]; then
          log_info "[$stem] audio message but WABOX_TRANSCRIBE_CMD unset; skipping"
          return 0
        fi
        local transcript trc=0
        transcript="$(media_transcribe "$workdir/$media_rel")" || trc=$?
        if ((trc != 0)) || [[ -z "${transcript//[[:space:]]/}" ]]; then
          log_error "[$stem] transcription failed (rc=$trc)"
          write_outbox "$to" "(Não consegui transcrever o áudio.)" "$id" "$stem" >/dev/null
          return 0
        fi
        # Transcript becomes the message text (caption first, if any). The
        # media is now consumed — no media args go to the backend.
        if [[ -n "$text" ]]; then
          text="$text"$'\n\n'"$transcript"
        else
          text="$transcript"
        fi
        media_type="" media_mime="" media_rel=""
        ;;
      image)
        : # keep media_rel/media_type/media_mime; passed to the backend below
        ;;
      *)
        log_info "[$stem] unsupported media type '$media_type'; skipping"
        return 0
        ;;
    esac
  fi

  # Nothing actionable: no text and no image to forward.
  if [[ -z "$text" && -z "$media_rel" ]]; then
    log_info "[$stem] empty message (no text, no actionable media); not replying"
    return 0
  fi

  # ---- Step 5: agent-level slash commands (pure-text messages only) -----
  # A caption that happens to start with "/" is treated as a caption, not a
  # command, so media is never silently swallowed by the dispatcher.
  if ((!had_media)) && handle_slash_command "$text" "$slug" "$conv_key" "$to" "$id" "$stem"; then
    return 0
  fi

  # ---- Step 6: serialize per-conversation, hand off to backend ---------
  # The flock ensures messages from the *same* sender are processed in order
  # (so the backend's per-conversation state doesn't race), while different
  # senders run in parallel via the per-conversation lockfile.
  log_info "[$stem] from=$from conv=$conv_key → backend"
  (
    exec 8>"$LOCKS_DIR/$slug.lock"
    flock -x 8

    local reply rc=0
    reply="$(printf '%s' "$text" |
      backend_reply "$slug" "$conv_key" "$stem" "$media_rel" "$media_type" "$media_mime")" || rc=$?

    if ((rc == 124)); then
      log_error "[$stem] backend timed out"
      reply="(Sorry — I took too long to think. Please try again.)"
    elif ((rc != 0)); then
      log_error "[$stem] backend exited rc=$rc"
      reply="(Sorry — I hit an error processing that message.)"
    elif [[ -z "$reply" ]]; then
      log_warn "[$stem] backend returned empty reply"
      reply="(no response)"
    fi

    local out_path
    out_path="$(write_outbox "$to" "$reply" "" "$stem")"
    log_info "[$stem] wrote reply → $out_path"
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
