# Per-envelope handler.
#
# Picks up an inbox envelope, fires the WhatsApp read receipt by moving it
# to PROCESSED_DIR, dispatches slash commands via lib/commands.sh, and
# otherwise hands the user's text to the active backend's backend_reply
# under a per-conversation flock.

# Persist the slug↔conv_key mapping and a last-message record so
# `wabox-bot state` can enumerate conversations and sort them by activity.
# Written atomically (temp + rename) because two messages from the same sender
# can be handled concurrently, before the per-conversation flock in step 6
# serializes the backend call — a plain `>` could interleave into a corrupt
# file. conv_key is idempotent (same content every time); last_message is a
# fresh inbound record ({at, direction, text_preview}).
persist_conversation_meta() {
  local slug="$1" conv_key="$2" preview="$3"
  local dir="$SESSIONS_DIR/$slug"
  mkdir -p "$dir"

  local ktmp="$dir/.conv_key.tmp.$$"
  if printf '%s\n' "$conv_key" >"$ktmp" 2>/dev/null; then
    mv -f -- "$ktmp" "$dir/conv_key" 2>/dev/null || rm -f -- "$ktmp"
  fi

  local mtmp="$dir/.last_message.tmp.$$"
  if jq -n \
    --argjson at "$(date +%s)" \
    --arg text "$preview" \
    '{at: $at, direction: "in", text_preview: $text}' >"$mtmp" 2>/dev/null; then
    mv -f -- "$mtmp" "$dir/last_message.json" 2>/dev/null || rm -f -- "$mtmp"
  fi
}

# 0 if another envelope for the same conversation is currently queued in the
# inbox — a newer message that means our reply may otherwise land unthreaded
# after a later question. The current envelope was already moved to
# PROCESSED_DIR (Step 3), so a match here is a genuinely different, still-queued
# job. The inbox is small by design (jobs are picked up immediately), so this is
# a handful of jq reads at worst. A file another worker moves to processed/
# mid-probe just reads empty and is skipped (no backlog from that file).
inbox_has_backlog_for() {
  local conv_key="$1" f env cand_key
  for f in "$WABOX_INBOX"/*.json; do
    [[ -e "$f" ]] || continue          # no-match glob stays literal without nullglob
    env="$(cat -- "$f" 2>/dev/null)" || continue
    [[ -n "$env" ]] || continue
    jq -e . >/dev/null 2>&1 <<<"$env" || continue
    cand_key="$(conversation_key "$env")"
    [[ "$cand_key" == "$conv_key" ]] && return 0
  done
  return 1
}

# Decide whether this reply should quote the message it answers, per
# WABOX_QUOTE_REPLY: always ⇒ yes; never ⇒ no; auto ⇒ yes in a group (`*@g.us`,
# conventional there) or when a backlog is queued for this conversation.
should_quote_reply() {
  local to="$1" conv_key="$2"
  case "$WABOX_QUOTE_REPLY" in
    always) return 0 ;;
    never) return 1 ;;
  esac
  [[ "$to" == *@g.us ]] && return 0
  inbox_has_backlog_for "$conv_key"
}

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
  # `conversation_key()` re-parses `participant` for its own routing strategy;
  # we also extract it here because the reaction/quote jobs need it verbatim to
  # target the right group member's message (`react`/`replyTo` carry it).
  local id from participant text from_me conv_key slug
  id="$(jq -r '.id     // empty' <<<"$envelope")"
  from="$(jq -r '.from // empty' <<<"$envelope")"
  participant="$(jq -r '.participant // empty' <<<"$envelope")"
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

  # ---- Step 4a: persist the slug↔conv_key mapping + a last-message record.
  # Slugs are sha1(conv_key) — one-way — so this file is the only path back to
  # the JID for `wabox-bot state`. We also record a lightweight last_message so
  # state can list/sort conversations by activity without scanning processed/.
  # The preview is the message text (audio hasn't been transcribed yet, so an
  # audio/image without a caption records "[audio]"/"[image]"). Skipped only
  # for a truly empty envelope (no text, no media).
  local preview="" env_media_type
  env_media_type="$(media_type_of "$envelope")"
  if [[ -n "$text" ]]; then
    preview="${text:0:120}"
  elif [[ -n "$env_media_type" ]]; then
    preview="[$env_media_type]"
  fi
  if [[ -n "$preview" ]]; then
    persist_conversation_meta "$slug" "$conv_key" "$preview"
  fi

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

  # ---- Step 5b: ack reaction (turn-in-progress signal) ------------------
  # Fired here — after every slash-command / skip / empty / unsupported-media
  # return above, immediately before the backend flock — so the reaction means
  # specifically "an agent turn is now running", not merely "message received".
  # It's a react-only job carrying the inbound id (+ participant in groups, so
  # it targets the right member's message). Default WABOX_ACK_REACT="" disables
  # it, keeping outbox traffic byte-identical to prior releases.
  if [[ -n "$WABOX_ACK_REACT" && -n "$id" ]]; then
    local ack_extras
    ack_extras="$(jq -n \
      --arg emoji "$WABOX_ACK_REACT" \
      --arg mid "$id" \
      --arg part "$participant" \
      '{react: ({emoji: $emoji, messageId: $mid}
                + (if $part == "" then {} else {participant: $part} end))}')"
    write_outbox "$to" "" "" "${stem}-ack" "$ack_extras" >/dev/null
    log_debug "[$stem] ack reaction $WABOX_ACK_REACT queued"
  fi

  # ---- Step 6: serialize per-conversation, hand off to backend ---------
  # The flock ensures messages from the *same* sender are processed in order
  # (so the backend's per-conversation state doesn't race), while different
  # senders run in parallel via the per-conversation lockfile.
  log_info "[$stem] from=$from conv=$conv_key → backend"
  (
    exec 8>"$LOCKS_DIR/$slug.lock"
    flock -x 8

    # Ready the outgoing-file folder *before* the agent runs so it sees a clean
    # workspace: leftovers from a prior turn are archived (not deleted — core
    # may still be reading them), and stale archives pruned. Same workdir the
    # backend cd's into (both mkdir -p it; idempotent).
    local workdir
    workdir="$(conversation_workdir "$slug")"
    senddir_prepare "$workdir" "$stem"
    senddir_prune "$workdir"

    local reply rc=0
    reply="$(printf '%s' "$text" |
      backend_reply "$slug" "$conv_key" "$stem" "$media_rel" "$media_type" "$media_mime")" || rc=$?

    # Collect agent-produced files only on the success path — a failed or
    # timed-out turn's partial outputs stay in the folder and get archived at
    # the next turn's start rather than being delivered.
    local -a extra_files=()
    if ((rc == 0)); then
      local collected
      collected="$(senddir_collect "$workdir")"
      [[ -n "$collected" ]] && mapfile -t extra_files <<<"$collected"
    fi

    if ((rc == 124)); then
      log_error "[$stem] backend timed out"
      reply="(Sorry — I took too long to think. Please try again.)"
    elif ((rc != 0)); then
      log_error "[$stem] backend exited rc=$rc"
      reply="(Sorry — I hit an error processing that message.)"
    elif [[ -z "$reply" && ${#extra_files[@]} -eq 0 ]]; then
      log_warn "[$stem] backend returned empty reply"
      reply="(no response)"
    fi
    # Empty reply *with* files ⇒ a files-only delivery (write_outbox omits the
    # empty text); today that would have been "(no response)".

    # Build the job extras: a quote (replyTo) when policy says so, and the
    # attached files. The loop — never the model — computes both, so an agent
    # can't inject a recipient or an arbitrary file list into the job.
    local extras_json='{}'
    if should_quote_reply "$to" "$conv_key"; then
      extras_json="$(jq -cn \
        --argjson base "$extras_json" \
        --arg id "$id" \
        --arg part "$participant" \
        '$base + {replyTo: ({id: $id}
                  + (if $part == "" then {} else {participant: $part} end))}')"
    fi
    if ((${#extra_files[@]})); then
      local files_json
      files_json="$(printf '%s\n' "${extra_files[@]}" | jq -R . | jq -cs .)"
      extras_json="$(jq -cn \
        --argjson base "$extras_json" \
        --argjson files "$files_json" \
        '$base + {files: $files}')"
      log_info "[$stem] attaching ${#extra_files[@]} file(s) from send folder"
    fi

    local out_path extras_arg=""
    [[ "$extras_json" != "{}" ]] && extras_arg="$extras_json"
    out_path="$(write_outbox "$to" "$reply" "" "$stem" "$extras_arg")"
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
