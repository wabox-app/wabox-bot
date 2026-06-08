# shellcheck shell=bash
# Google Antigravity backend.
#
# Drives the `agy` CLI (Google's Antigravity coding agent) in print mode.
# Unlike the chat-style backends, agy is an *autonomous coding agent*: with
# --dangerously-skip-permissions it will read files, run commands, and edit
# code in the conversation's working folder. That's the intended use here — a
# coding agent reachable over WhatsApp.
#
# Two agy quirks shape this backend:
#
#   1. Sessions are server-side and `--continue` resumes the *globally* most
#      recent conversation — NOT scoped to the working directory. So the cwd
#      trick the bob/claude backends lean on would leak context between
#      different WhatsApp conversations. Instead we pin each conversation to an
#      explicit id: `agy` writes the conversation id into its --log-file, we
#      grep it out after each turn, persist it per slug, and resume with
#      `--conversation <id>` thereafter. A stale id self-heals: agy warns and
#      starts a fresh conversation, whose id we then re-capture.
#
#   2. Print mode streams the agent's whole trajectory narration ("I will list
#      the directory…", "I will run the tests…") to stdout, and there is no
#      flag to suppress it. We can't reliably parse the final answer out, so we
#      prepend a concise-answer instruction to every prompt (overridable via
#      AGY_REPLY_PREFIX) and send stdout through. agy also prints errors to
#      stdout and exits 0 even when a conversation isn't found, so failure
#      detection is limited to the timeout path.
#
# Owns the per-conversation `conversation` (id) and `model` state files plus a
# transient `last.log`. Implements the wabox-bot backend contract:
#
#   backend_name              — short id ("agy")
#   backend_reply             — runs the agy turn (stdin → stdout)
#   backend_handle_command    — handles /model; falls through (99) for the rest
#   backend_clear             — drops the conversation id on /clear
#   backend_help              — supplies the /help lines for our commands
#   backend_status_lines      — supplies the /status block

# Backend-specific env defaults. Users can still override any of these via
# their shell environment or the wabox-bot config file — these are only
# consulted if the var is unset.
AGY_BIN="${AGY_BIN:-agy}"
AGY_ARGS="${AGY_ARGS:---dangerously-skip-permissions}"
AGY_TIMEOUT="${AGY_TIMEOUT:-300}"
# Prepended to every prompt to keep agy from dumping its step-by-step
# narration into the WhatsApp reply. Set to empty to disable.
AGY_REPLY_PREFIX="${AGY_REPLY_PREFIX:-Respond concisely with only the final answer; do not narrate your steps.}"

backend_name() {
  printf 'agy\n'
}

backend_check_dependencies() {
  need "$AGY_BIN"
}

# ---- Per-conversation state files ------------------------------------------
#
# All state lives under $(backend_state_dir "$slug"), which expands to
# $SESSIONS_DIR/<slug>/agy/. Keeping it per-backend means switching backends
# for the same conversation never smushes state together.

agy_conversation_for() {
  local f
  f="$(backend_state_dir "$1")/conversation"
  [[ -s "$f" ]] && cat "$f"
}

agy_save_conversation_for() {
  local slug="$1" cid="$2"
  printf '%s\n' "$cid" >"$(backend_state_dir "$slug")/conversation"
}

agy_model_for() {
  local f
  f="$(backend_state_dir "$1")/model"
  [[ -s "$f" ]] && cat "$f"
}

agy_save_model_for() {
  local slug="$1" name="$2"
  printf '%s\n' "$name" >"$(backend_state_dir "$slug")/model"
}

# A model name is valid if it appears verbatim in `agy models`. agy's names
# carry spaces and parentheses (e.g. "Claude Opus 4.6 (Thinking)"), so we
# match whole lines rather than tokenising — and validate before persisting,
# since the value is passed straight to `agy --model`.
agy_model_is_valid() {
  "$AGY_BIN" models 2>/dev/null | grep -Fxq -- "$1"
}

# Compose the prompt fed to agy on stdin: the concise-answer instruction,
# then (for an image) a pointer to the staged file relative to the agent's
# cwd, then the user's text. Audio is transcribed upstream and arrives as
# plain text, so the only media type we special-case is "image".
agy_compose_prompt() {
  local text="$1" media_path="$2" media_type="$3"
  local prefix="$AGY_REPLY_PREFIX"
  [[ -n "$prefix" ]] && prefix="$prefix"$'\n\n'
  if [[ "$media_type" == "image" && -n "$media_path" ]]; then
    if [[ -n "$text" ]]; then
      printf '%sThe user sent an image at %s — view it and respond.\n\n%s' "$prefix" "$media_path" "$text"
    else
      printf '%sThe user sent an image at %s — view it and respond.' "$prefix" "$media_path"
    fi
  else
    printf '%s%s' "$prefix" "$text"
  fi
}

# Pull the conversation id agy recorded in its log this turn. The log lines
# look like "... conversation=b2d40765-7083-4473-8c1a-09f017f4ddad ...".
agy_conversation_id_from_log() {
  grep -aoE 'conversation=[0-9a-f-]{36}' "$1" 2>/dev/null | head -1 | cut -d= -f2
}

# ---- The agy turn ----------------------------------------------------------

# backend_reply(slug, conv_key, stem [, media_path [, media_type]]) — stdin = user text, stdout = reply.
# Exit: 0 ok, 124 timed out, anything else = error (caller substitutes a
# user-visible error message).
backend_reply() {
  local slug="$1" conv_key="$2" stem="$3"
  local media_path="${4:-}" media_type="${5:-}"
  local text
  text="$(cat)"

  # Run this turn in the conversation's working folder so the agent's file
  # operations stay isolated per conversation. We're already inside the
  # command-substitution subshell that captures backend_reply's output (see
  # lib/inbox.sh), so this cd is scoped to this one turn — no global CWD
  # change, no races between concurrent conversations.
  local workdir
  workdir="$(conversation_workdir "$slug")"
  if ! cd "$workdir"; then
    log_error "[$stem] cannot cd to working folder $workdir"
    return 1
  fi

  local d logf
  d="$(backend_state_dir "$slug")"
  logf="$d/last.log"

  local -a cmd=("$AGY_BIN")
  # shellcheck disable=SC2206 # intentional word-splitting of AGY_ARGS
  cmd+=($AGY_ARGS)
  cmd+=(--print-timeout "${AGY_TIMEOUT}s")
  cmd+=(--log-file "$logf")
  local model_override
  model_override="$(agy_model_for "$slug" || true)"
  if [[ -n "$model_override" ]]; then
    cmd+=(--model "$model_override")
  fi
  # Pin to this conversation's id (NOT --continue, which is global and would
  # bleed context across conversations). Absent on the first turn.
  local cid
  cid="$(agy_conversation_for "$slug" || true)"
  if [[ -n "$cid" ]]; then
    cmd+=(--conversation "$cid")
    log_info "[$stem] conv=$conv_key resume conversation=$cid"
  else
    log_info "[$stem] conv=$conv_key new conversation"
  fi

  local prompt
  prompt="$(agy_compose_prompt "$text" "$media_path" "$media_type")"
  # agy can spend minutes acting; wrap with a kill margin past --print-timeout.
  local out rc=0
  out="$(printf '%s' "$prompt" |
    timeout --kill-after=5 "$((AGY_TIMEOUT + 15))" "${cmd[@]}" 2>>"$LOG_FILE")" || rc=$?

  if ((rc != 0)); then
    return "$rc"
  fi

  # Persist the conversation id agy used this turn so the next turn resumes
  # it. This also self-heals a stale id: if the saved id was gone, agy started
  # a fresh conversation and the log now carries the new id.
  local new_cid
  new_cid="$(agy_conversation_id_from_log "$logf")"
  [[ -n "$new_cid" ]] && agy_save_conversation_for "$slug" "$new_cid"

  # Drop the "conversation not found" warning agy prints when a pinned id has
  # expired (we recover transparently above, so the user shouldn't see it).
  sed '/^Warning: conversation .* not found\.$/d' <<<"$out"
}

# ---- /clear, /help, /status hooks ------------------------------------------

backend_clear() {
  local slug="$1" d
  d="$(backend_state_dir "$slug")"
  # Drop the pinned conversation id (and the transient log) so the next
  # message starts a fresh agy conversation.
  rm -f -- "$d/conversation" "$d/last.log"
}

backend_help() {
  cat <<'EOF'
/model <name>    set model (must match a name from `agy models`)
/model           list available models
/model default   remove the model override
EOF
}

backend_status_lines() {
  local slug="$1"
  local cid_now model_now
  cid_now="$(agy_conversation_for "$slug" || true)"
  model_now="$(agy_model_for "$slug" || true)"
  cat <<EOF
conversation: ${cid_now:-(none — next message starts fresh)}
model:        ${model_now:-(default)}
EOF
}

# ---- /model dispatch -------------------------------------------------------

# Return 99 from unrecognised commands so the core dispatcher falls through
# to its "unknown command" reply.
backend_handle_command() {
  local cmd_word="$1" cmd_args="$2" slug="$3" conv_key="$4" to="$5" id="$6" stem="$7"
  local reply_path
  case "$cmd_word" in
    /model)
      # Model names contain spaces and parens, so the argument is the whole
      # rest of the message (trimmed), not just the first word.
      local model_arg="${cmd_args#"${cmd_args%%[![:space:]]*}"}"
      model_arg="${model_arg%"${model_arg##*[![:space:]]}"}"
      if [[ -z "$model_arg" ]]; then
        local model_now models_list
        model_now="$(agy_model_for "$slug" || true)"
        models_list="$("$AGY_BIN" models 2>/dev/null || true)"
        reply_path="$(write_outbox "$to" \
          "Current model: ${model_now:-(default)}
Available models:
${models_list:-(could not list models)}
Usage:
  /model <name>     set the model (exact name from the list)
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
          "Model override removed; using agy's default." \
          "$id" "$stem")"
        log_info "[$stem] /model default → $reply_path"
        return 0
      fi
      if ! agy_model_is_valid "$model_arg"; then
        local models_list
        models_list="$("$AGY_BIN" models 2>/dev/null || true)"
        reply_path="$(write_outbox "$to" \
          "Unknown model: $model_arg
Available models:
${models_list:-(could not list models)}" \
          "$id" "$stem")"
        log_warn "[$stem] /model rejected name=$model_arg → $reply_path"
        return 0
      fi
      (
        exec 8>"$LOCKS_DIR/$slug.lock"
        flock -x 8
        agy_save_model_for "$slug" "$model_arg"
      )
      reply_path="$(write_outbox "$to" \
        "Model for this conversation set to: $model_arg" \
        "$id" "$stem")"
      log_info "[$stem] /model → $model_arg → $reply_path"
      return 0
      ;;
    *)
      return 99
      ;;
  esac
}
