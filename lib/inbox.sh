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
# file. conv_key is idempotent (same content every time); the last_message
# inbound record is written by the shared lastmsg_write (lib/lastmsg.sh), which
# the send/prompt verbs reuse for their `direction:"out"` records.
persist_conversation_meta() {
  local slug="$1" conv_key="$2" preview="$3"
  local dir="$SESSIONS_DIR/$slug"
  mkdir -p "$dir"

  local ktmp="$dir/.conv_key.tmp.$BASHPID.$RANDOM"
  if printf '%s\n' "$conv_key" >"$ktmp" 2>/dev/null; then
    mv -f -- "$ktmp" "$dir/conv_key" 2>/dev/null || rm -f -- "$ktmp"
  fi

  lastmsg_write "$slug" in "$preview"
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
  # step 3. Audio is transcribed here (generic → becomes text); an image or a
  # document is staged and passed to the backend by reference. Types the agent
  # can't use (video, sticker, anything new) are not staged, but a caption on
  # one still carries real intent, so it's forwarded as text with a bracketed
  # note rather than dropped on the floor.
  local media_type media_mime media_rel="" had_media=0
  media_type="$(media_type_of "$envelope")"
  media_mime="$(media_mime_of "$envelope")"
  if [[ -n "$media_type" ]]; then
    had_media=1
    local workdir
    workdir="$(conversation_workdir "$slug")"

    # Oversize document guard, checked on the source in $PROCESSED_DIR *before*
    # any copy, so a 2 GB WhatsApp document is never blindly staged. Documents
    # only — images and audio ride WhatsApp's own ~16 MB ceiling. Oversize with
    # a caption degrades to a plain text turn; a bare one returns after the
    # notice (clearing media_type skips staging and the type case below).
    if [[ "$media_type" == "document" ]]; then
      local doc_mb
      doc_mb="$(media_size_mb "$PROCESSED_DIR/$media_file" 2>/dev/null)" || doc_mb=0
      if ((doc_mb > ${WABOX_DOC_MAX_MB:-100})); then
        log_info "[$stem] document ${doc_mb}MB over WABOX_DOC_MAX_MB=${WABOX_DOC_MAX_MB:-100}; not staging"
        # Distinct stem so a following caption reply (same $stem) can't clobber
        # the notice — both jobs must reach the user, notice first.
        write_outbox "$to" \
          "Arquivo muito grande (${doc_mb} MB) — consigo ler até ${WABOX_DOC_MAX_MB:-100} MB." \
          "$id" "${stem}-toobig" >/dev/null
        [[ -n "$text" ]] || return 0
        media_type="" media_mime=""
      fi
    fi

    # Stage only the types the agent can use (transcribe audio; hand image and
    # document over by reference). Unsupported types are never copied. An
    # oversize document cleared media_type above, so it skips this too.
    case "$media_type" in
      audio | image | document)
        if ! media_rel="$(media_stage "$PROCESSED_DIR/$media_file" "$workdir")"; then
          log_warn "[$stem] media file gone before staging; nothing to process"
          return 0
        fi
        ;;
    esac

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
      image | document)
        : # keep media_rel/media_type/media_mime; passed to the backend below
        ;;
      "")
        : # oversize document with a caption → plain text turn, nothing staged
        ;;
      *)
        # video, sticker, or any future unknown type. A bare one is skipped as
        # before; a captioned one is forwarded as text with a note so the agent
        # knows a file it can't read was attached (and can say so).
        if [[ -z "$text" ]]; then
          log_info "[$stem] unsupported media '$media_type' with no caption; skipping"
          return 0
        fi
        local unsup_note
        case "$media_type" in
          video)   unsup_note="[o usuário enviou um vídeo, que não consigo processar]" ;;
          sticker) unsup_note="[o usuário enviou uma figurinha, que não consigo processar]" ;;
          *)       unsup_note="[o usuário enviou um arquivo que não consigo processar]" ;;
        esac
        text="$unsup_note"$'\n\n'"$text"
        media_type="" media_mime="" media_rel=""
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

  # ---- Step 5b: enqueue this prepared turn-part ------------------------
  # Everything above ran per-envelope (read receipt, media staging, audio
  # transcription). From here the message is coalesced: append it to the
  # conversation's batch so the drain below can merge a whole burst — an image
  # plus its caption, several photos and a line of text — into ONE agent turn,
  # instead of firing a confusing turn per fragment. See lib/batch.sh for why
  # appends are lock-free and the drain is serialized.
  log_info "[$stem] from=$from conv=$conv_key → batched"
  batch_append "$slug" "$text" "$media_rel" "$media_type" "$media_mime" \
    "$id" "$participant" "$to" "$stem"

  # ---- Step 6: drain the batch under the per-conversation flock ---------
  # The flock serializes same-sender turns (so backend state doesn't race) and
  # is what makes batching work: the worker that wins the lock waits out the
  # quiet window and drains every part the others appended; they then find the
  # queue empty and return. Different senders still run in parallel.
  (
    exec 8>"$LOCKS_DIR/$slug.lock"
    flock -x 8

    # Wait for the burst to settle. Empty ⇒ another worker already drained our
    # part, so there's nothing to do (batch_settle checks before it waits, so a
    # loser doesn't burn the window).
    batch_settle "$slug" || exit 0

    local merged
    merged="$(batch_collect "$slug")" || exit 0

    # Unpack the merged turn. id/participant/to/stem describe the NEWEST message
    # of the burst, so the reply quotes and reacts to it and the outbox stem is
    # unique to this drain. $b_media is the full media manifest.
    local b_text b_media b_id b_part b_to b_stem b_count
    b_text="$(jq -r '.text' <<<"$merged")"
    b_media="$(jq -c '.media' <<<"$merged")"
    b_id="$(jq -r '.id' <<<"$merged")"
    b_part="$(jq -r '.participant' <<<"$merged")"
    b_to="$(jq -r '.to' <<<"$merged")"
    b_stem="$(jq -r '.stem' <<<"$merged")"
    b_count="$(jq -r '.count' <<<"$merged")"

    # First media item as the legacy positional args (for backends that read
    # them, e.g. bob/agy); the manifest $b_media carries every item for backends
    # that compose all of them (claude-code shows the agent all N images).
    local m1_path m1_type m1_mime
    m1_path="$(jq -r '.media[0].path // ""' <<<"$merged")"
    m1_type="$(jq -r '.media[0].type // ""' <<<"$merged")"
    m1_mime="$(jq -r '.media[0].mime // ""' <<<"$merged")"

    log_info "[$b_stem] draining $b_count message(s) for conv=$conv_key → backend"

    # Ack reaction (turn-in-progress signal): fired once, here, as the merged
    # turn starts — so it means "an agent turn is now running", reacting to the
    # newest message of the burst. It's a react-only job carrying that id (+
    # participant in groups). Default WABOX_ACK_REACT="" disables it.
    if [[ -n "$WABOX_ACK_REACT" && -n "$b_id" ]]; then
      local ack_extras
      ack_extras="$(jq -n \
        --arg emoji "$WABOX_ACK_REACT" \
        --arg mid "$b_id" \
        --arg part "$b_part" \
        '{react: ({emoji: $emoji, messageId: $mid}
                  + (if $part == "" then {} else {participant: $part} end))}')"
      write_outbox "$b_to" "" "" "${b_stem}-ack" "$ack_extras" >/dev/null
      log_debug "[$b_stem] ack reaction $WABOX_ACK_REACT queued"
    fi

    # Ready the outgoing-file folder *before* the agent runs so it sees a clean
    # workspace: leftovers from a prior turn are archived (not deleted — core
    # may still be reading them), and stale archives pruned. Same workdir the
    # backend cd's into (both mkdir -p it; idempotent).
    local workdir
    workdir="$(conversation_workdir "$slug")"
    senddir_prepare "$workdir" "$b_stem"
    senddir_prune "$workdir"

    local reply rc=0
    reply="$(printf '%s' "$b_text" |
      backend_reply "$slug" "$conv_key" "$b_stem" "$m1_path" "$m1_type" "$m1_mime" "$b_media")" || rc=$?

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
      log_error "[$b_stem] backend timed out"
      reply="(Sorry — I took too long to think. Please try again.)"
    elif ((rc != 0)); then
      log_error "[$b_stem] backend exited rc=$rc"
      reply="(Sorry — I hit an error processing that message.)"
    elif [[ -z "$reply" && ${#extra_files[@]} -eq 0 ]]; then
      log_warn "[$b_stem] backend returned empty reply"
      reply="(no response)"
    fi
    # Empty reply *with* files ⇒ a files-only delivery (write_outbox omits the
    # empty text); today that would have been "(no response)".

    # Build the job extras: a quote (replyTo) when policy says so, and the
    # attached files. The loop — never the model — computes both, so an agent
    # can't inject a recipient or an arbitrary file list into the job.
    local extras_json='{}'
    if should_quote_reply "$b_to" "$conv_key"; then
      extras_json="$(jq -cn \
        --argjson base "$extras_json" \
        --arg id "$b_id" \
        --arg part "$b_part" \
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
      log_info "[$b_stem] attaching ${#extra_files[@]} file(s) from send folder"
    fi

    local out_path extras_arg=""
    [[ "$extras_json" != "{}" ]] && extras_arg="$extras_json"
    out_path="$(write_outbox "$b_to" "$reply" "" "$b_stem" "$extras_arg")"
    log_info "[$b_stem] wrote reply → $out_path"
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
