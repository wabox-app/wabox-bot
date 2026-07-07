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
# `default` (not `auto`) so tool uses Claude isn't pre-allowed to run surface
# as `permission_denials` in the JSON instead of being silently auto-approved.
# That's what drives the ask-over-WhatsApp flow below; with `auto`/`acceptEdits`/
# `bypassPermissions` nothing is denied and the flow stays dormant. Routine
# tools can still be pre-allowed via ~/.claude/settings.json so `default` only
# asks for the genuinely sensitive ones.
CLAUDE_ARGS="${CLAUDE_ARGS:---permission-mode default}"
CLAUDE_TIMEOUT="${CLAUDE_TIMEOUT:-180}"
SYSTEM_PROMPT_FILE="${SYSTEM_PROMPT_FILE:-}"
# How long a parked permission request stays answerable. After this many
# seconds the next message is treated as a fresh prompt, not a yes/no answer.
CC_PERMISSION_TIMEOUT="${CC_PERMISSION_TIMEOUT:-600}"
# Tell the agent, via one appended system-prompt sentence, that files it writes
# into the conversation's send folder are delivered over WhatsApp. Set 0 to keep
# the agent unaware of the outgoing-file convention.
CC_ADVERTISE_SEND_DIR="${CC_ADVERTISE_SEND_DIR:-1}"

backend_name() {
  printf 'claude-code\n'
}

backend_check_dependencies() {
  need "$CLAUDE_BIN"
}

# backend_seed_workdir <slug> <workdir> — seed a freshly-resolved *default*
# workdir. Core only calls this for auto defaults (never a /cwd redirect), on
# every turn, so it must be cheap and idempotent and emit nothing on stdout
# (conversation_workdir's output is captured). Two seed-if-absent actions:
#   1. Copy the shipped instructions template as CLAUDE.md — claude auto-loads
#      CLAUDE.md from cwd, so this teaches WhatsApp etiquette + memory practice.
#   2. When CC_SHARED_SKILLS_DIR points at a readable folder, symlink it as
#      .claude/skills so every conversation shares one curated skill set.
# Never touches an existing file or link (even a broken one) — the user's or the
# agent's edits win forever.
backend_seed_workdir() {
  local slug="$1" workdir="$2"
  local template="${WABOX_WORKDIR_TEMPLATE:-}"
  if [[ -n "$template" && -r "$template" && ! -e "$workdir/CLAUDE.md" && ! -L "$workdir/CLAUDE.md" ]]; then
    cp -- "$template" "$workdir/CLAUDE.md"
  fi
  local shared="${CC_SHARED_SKILLS_DIR:-}"
  local skills="$workdir/.claude/skills"
  if [[ -n "$shared" && -r "$shared" && ! -e "$skills" && ! -L "$skills" ]]; then
    mkdir -p "$workdir/.claude"
    ln -s -- "$shared" "$skills"
  fi
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

# Persist the session id together with the working directory it was created
# in. Claude scopes sessions to the cwd (sessions live under
# ~/.claude/projects/<cwd-hash>/), so --resume only works from that same
# directory; we record the cwd to enforce that in cc_resumable_session.
cc_save_session_id() {
  local slug="$1" sid="$2" workdir="$3" d
  d="$(backend_state_dir "$slug")"
  printf '%s\n' "$sid" >"$d/session"
  printf '%s\n' "$workdir" >"$d/session.cwd"
}

cc_session_cwd_for() {
  local f
  f="$(backend_state_dir "$1")/session.cwd"
  [[ -s "$f" ]] && cat "$f"
}

# Echo the resumable session id (rc 0) only when a session exists AND it was
# created in $workdir. Resuming from a different cwd fails with "No
# conversation found with session ID" — so otherwise echo nothing and return
# 1, and the caller starts a fresh session in the current directory. Sessions
# predating this (no recorded cwd) are treated as non-resumable for safety.
cc_resumable_session() {
  local slug="$1" workdir="$2" sid cwd
  sid="$(cc_session_id_for "$slug" || true)"
  cwd="$(cc_session_cwd_for "$slug" || true)"
  [[ -n "$sid" && "$cwd" == "$workdir" ]] || return 1
  printf '%s' "$sid"
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

# ---- Pending-permission state ----------------------------------------------
#
# When a turn ends with the agent blocked on a tool it wasn't allowed to use,
# we park the turn: store what was denied + the prompt that triggered it, ask
# the user over WhatsApp, and pick the answer up on the *next* message. All of
# this lives in one JSON file in the conversation's backend state dir and is
# only ever touched inside the per-conversation flock (backend_reply already
# runs under it), so no extra locking is needed.

cc_pending_permission_path() {
  printf '%s/pending_permission.json' "$(backend_state_dir "$1")"
}

# Save the parked turn. `denials` is the raw `.permission_denials` JSON array
# from the run, stored verbatim so we can both describe it to the user and
# recover the exact tool names to grant on approval.
cc_save_pending_permission() {
  local slug="$1" original_prompt="$2" denials="$3" now="$4"
  jq -n \
    --arg p "$original_prompt" \
    --argjson d "$denials" \
    --argjson t "$now" \
    '{original_prompt: $p, denials: $d, asked_at: $t}' \
    >"$(cc_pending_permission_path "$slug")"
}

cc_load_pending_permission() {
  cat -- "$(cc_pending_permission_path "$1")"
}

cc_clear_pending_permission() {
  rm -f -- "$(cc_pending_permission_path "$1")"
}

# 0 if a *fresh* pending permission exists, 1 otherwise. An expired one (older
# than CC_PERMISSION_TIMEOUT) is cleared here and reported as absent, so the
# incoming message falls through and is handled as an ordinary new prompt — the
# user has clearly moved on.
cc_has_pending_permission() {
  local f
  f="$(cc_pending_permission_path "$1")"
  [[ -s "$f" ]] || return 1
  local asked_at now
  asked_at="$(jq -r '.asked_at // 0' <"$f" 2>/dev/null || echo 0)"
  now="$(date +%s)"
  if ((now - asked_at > CC_PERMISSION_TIMEOUT)); then
    cc_clear_pending_permission "$1"
    return 1
  fi
  return 0
}

# Compose the prompt fed to claude on stdin. With an image we prepend a short
# instruction pointing the agent at the staged file (relative to its cwd),
# then the caption. Any other media type (audio is already transcribed into
# text upstream) passes the text through unchanged.
cc_compose_prompt() {
  local text="$1" media_path="$2" media_type="$3"
  if [[ "$media_type" == "image" && -n "$media_path" ]]; then
    if [[ -n "$text" ]]; then
      printf 'The user sent an image at %s — view it and respond.\n\n%s' "$media_path" "$text"
    else
      printf 'The user sent an image at %s — view it and respond.' "$media_path"
    fi
  else
    printf '%s' "$text"
  fi
}

# ---- The Claude turn -------------------------------------------------------

# Run one Claude turn in $workdir and echo its raw response JSON on stdout.
# Returns claude's exit code (0 ok, 124 timed out, other = error); on a
# non-zero code nothing is echoed. `extra_allowed`, when non-empty, is
# word-split into `--allowedTools` — that's how an approved permission grants
# exactly the tools the user just said yes to, for this one turn only.
#
# Carries the model/mode/system overrides and the session resume/create logic
# so both the normal path and the approval path go through the same invocation.
cc_run_turn() {
  local slug="$1" conv_key="$2" stem="$3" workdir="$4" prompt="$5" extra_allowed="${6:-}"

  local sid_existing sid
  sid_existing="$(cc_resumable_session "$slug" "$workdir" || true)"

  local -a cmd=("$CLAUDE_BIN")
  # shellcheck disable=SC2206 # intentional word-splitting of CLAUDE_ARGS
  cmd+=($CLAUDE_ARGS)
  cmd+=(-p --output-format json)
  if [[ -n "$SYSTEM_PROMPT_FILE" && -r "$SYSTEM_PROMPT_FILE" ]]; then
    cmd+=(--append-system-prompt "$(cat -- "$SYSTEM_PROMPT_FILE")")
  fi
  # Advertise the outgoing-file folder (absolute, so the agent can write to it
  # regardless of any cd it does mid-turn). The loop attaches whatever lands
  # there to this turn's reply — see lib/senddir.sh / lib/inbox.sh.
  if [[ "$CC_ADVERTISE_SEND_DIR" == "1" ]]; then
    cmd+=(--append-system-prompt \
      "To send the user a file over WhatsApp, write it to $(senddir_path "$workdir")/ — any file you leave in that folder is attached to your reply and delivered.")
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
  if [[ -n "$extra_allowed" ]]; then
    # Tool names come from `.permission_denials[].tool_name` — bare identifiers
    # like `Write`/`Bash`, no shell metacharacters — so the split is safe.
    # shellcheck disable=SC2206
    cmd+=(--allowedTools $extra_allowed)
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
  response_json="$(printf '%s' "$prompt" |
    timeout --kill-after=5 "$CLAUDE_TIMEOUT" "${cmd[@]}" 2>>"$LOG_FILE")" || rc=$?
  if ((rc != 0)); then
    return "$rc"
  fi

  # Persist whatever session id Claude reports back (it may rotate).
  local sid_returned
  sid_returned="$(jq -r '.session_id // empty' <<<"$response_json" 2>/dev/null || true)"
  [[ -n "$sid_returned" ]] && sid="$sid_returned"
  cc_save_session_id "$slug" "$sid" "$workdir"

  printf '%s' "$response_json"
}

# Given a completed turn's response JSON, either return the agent's result text
# or — if it was blocked on a tool — park a pending permission and return the
# yes/no question to send the user. `prompt` is stored so the approval path can
# resume with context. Used by both the normal and the approval paths, so a
# resumed turn that hits a *new* denial parks again (the flow chains naturally).
cc_emit_or_park() {
  local slug="$1" prompt="$2" response_json="$3"
  local denials
  denials="$(jq -c '.permission_denials // []' <<<"$response_json" 2>/dev/null || echo '[]')"
  if [[ -n "$denials" && "$denials" != "[]" ]]; then
    cc_save_pending_permission "$slug" "$prompt" "$denials" "$(date +%s)"
    cc_format_permission_message "$denials"
    return 0
  fi
  jq -r '.result // empty' <<<"$response_json" 2>/dev/null || true
}

# Format the WhatsApp prompt for a blocked turn: header, one concise bullet per
# denied tool (its salient argument, whitespace collapsed so a multi-line
# command stays on one line), then the yes/no ask. We deliberately drop the
# agent's free-text `.result` — it tends to ramble — and let the tool list be
# the objective statement of exactly what's about to run.
cc_format_permission_message() {
  local denials="$1"
  local tools
  tools="$(jq -r '
    [ .[] | "• *\(.tool_name)*"
      + ( ( .tool_input.command // .tool_input.file_path // .tool_input.path
            // .tool_input.url // .tool_input.pattern // .tool_input.skill // "" )
          | gsub("[[:space:]]+"; " ")
          | if . == "" then "" else " — \(.)" end ) ]
    | join("\n")' <<<"$denials" 2>/dev/null || true)"
  printf '⚠️ *Claude precisa de permissão*\n\n%s\n\nResponda *sim* para autorizar ou *não* para cancelar.' "$tools"
}

# The user just answered a parked permission. Interpret yes/no, then: on yes,
# resume the session granting exactly the denied tools and let the agent carry
# on; on no, drop it; on anything else, keep the pending state and re-ask.
cc_handle_permission_response() {
  local slug="$1" conv_key="$2" stem="$3" workdir="$4" user_text="$5"

  local pending
  pending="$(cc_load_pending_permission "$slug")"

  # Normalise: lowercase, strip surrounding whitespace.
  local norm
  norm="$(printf '%s' "$user_text" | tr '[:upper:]' '[:lower:]')"
  norm="${norm#"${norm%%[![:space:]]*}"}"
  norm="${norm%"${norm##*[![:space:]]}"}"

  local approved
  case "$norm" in
    sim | s | yes | y | ok | pode | claro | autoriza | autorizo | aprova | aprovo | confirma | confirmo | 👍)
      approved=1 ;;
    não | nao | n | no | nega | nego | cancela | cancelo | recusa | recuso | 👎)
      approved=0 ;;
    *)
      # Unrecognised — leave the pending state in place and ask again.
      log_info "[$stem] permission response not understood: '$user_text'"
      printf 'Não entendi. Responda *sim* para autorizar ou *não* para cancelar.'
      return 0
      ;;
  esac

  cc_clear_pending_permission "$slug"

  if ((!approved)); then
    log_info "[$stem] permission denied by user for conv=$conv_key"
    printf 'Ok, cancelado. O Claude não vai executar essa ação.'
    return 0
  fi

  # Approved: grant exactly the tools that were denied, resume the parked
  # session, and tell the agent to proceed. The original prompt is kept only
  # as data (stored/echoed), never re-executed as a command.
  local allowed
  allowed="$(jq -r '[.denials[].tool_name] | unique | join(" ")' <<<"$pending" 2>/dev/null || true)"
  log_info "[$stem] permission granted by user; resuming with allowedTools=[$allowed]"

  local response_json rc=0
  response_json="$(cc_run_turn "$slug" "$conv_key" "$stem" "$workdir" \
    'O usuário autorizou. Pode prosseguir com a ação que você havia solicitado.' \
    "$allowed")" || rc=$?
  if ((rc != 0)); then
    return "$rc"
  fi

  cc_emit_or_park "$slug" "$user_text" "$response_json"
}

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

  # If we parked a permission request on the previous turn, this message is the
  # user's answer to it — not a fresh prompt. (Expired pendings are cleared by
  # cc_has_pending_permission and fall through to the normal path below.)
  if cc_has_pending_permission "$slug"; then
    cc_handle_permission_response "$slug" "$conv_key" "$stem" "$workdir" "$text"
    return $?
  fi

  local prompt
  prompt="$(cc_compose_prompt "$text" "$media_path" "$media_type")"
  local response_json rc=0
  response_json="$(cc_run_turn "$slug" "$conv_key" "$stem" "$workdir" "$prompt")" || rc=$?
  if ((rc != 0)); then
    return "$rc"
  fi

  cc_emit_or_park "$slug" "$prompt" "$response_json"
}

# ---- /clear, /help, /status hooks ------------------------------------------

backend_clear() {
  local slug="$1" d
  d="$(backend_state_dir "$slug")"
  # Also drop any parked permission — a cleared conversation has no turn to
  # resume into, so a stale yes/no answer would have nowhere to go.
  rm -f -- "$d/session" "$d/session.cwd" "$d/pending_permission.json"
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
  local pending_info="(none)"
  if cc_has_pending_permission "$slug"; then
    pending_info="awaiting your *sim*/*não*"
  fi
  cat <<EOF
session: ${sid_now:-(none — next message starts fresh)}
model:   ${model_now:-(default)}
mode:    ${mode_now:-(default)}
system:  $system_info
pending: $pending_info
EOF
}

# ---- state / answer hooks (wabox-bot state / answer) -----------------------

# backend_state_json <slug> — echo this backend's view of a conversation for
# `wabox-bot state`: {session_id, overrides:{model,mode,system},
# pending_permission}. pending_permission is null unless a *fresh* request is
# parked (the cc_has_pending_permission expiry rule also prunes expired ones);
# when present it carries asked_at, expires_at (= asked_at + CC_PERMISSION_TIMEOUT),
# the denied tool names, and the same WhatsApp question text the user was asked.
backend_state_json() {
  local slug="$1"
  local sid model mode system
  sid="$(cc_session_id_for "$slug" || true)"
  model="$(cc_model_for "$slug" || true)"
  mode="$(cc_mode_for "$slug" || true)"
  system="$(cc_system_for "$slug" || true)"

  local pending='null'
  if cc_has_pending_permission "$slug"; then
    local pj asked_at denials question
    pj="$(cc_load_pending_permission "$slug")"
    asked_at="$(jq -r '.asked_at // 0' <<<"$pj" 2>/dev/null || echo 0)"
    denials="$(jq -c '.denials // []' <<<"$pj" 2>/dev/null || echo '[]')"
    question="$(cc_format_permission_message "$denials")"
    pending="$(jq -n \
      --argjson asked_at "$asked_at" \
      --argjson timeout "$CC_PERMISSION_TIMEOUT" \
      --argjson denials "$denials" \
      --arg question "$question" \
      '{asked_at: $asked_at,
        expires_at: ($asked_at + $timeout),
        tools: [$denials[].tool_name],
        question: $question}')"
  fi

  jq -n \
    --arg sid "$sid" \
    --arg model "$model" \
    --arg mode "$mode" \
    --arg system "$system" \
    --argjson pending "$pending" \
    '{
      session_id: (if $sid == "" then null else $sid end),
      overrides: {
        model:  (if $model  == "" then null else $model  end),
        mode:   (if $mode   == "" then null else $mode   end),
        system: (if $system == "" then null else $system end)
      },
      pending_permission: $pending
    }'
}

# backend_answer_permission <slug> <conv_key> <yes|no> — answer a parked
# permission from the `answer` CLI verb, through the same code path a WhatsApp
# "sim"/"não" would take. Runs under the per-conversation flock held by
# answer_main. Exit 2 if nothing fresh is parked; otherwise echoes the reply
# text (and re-parks if the resumed turn hits a new denial).
backend_answer_permission() {
  local slug="$1" conv_key="$2" decision="$3"
  cc_has_pending_permission "$slug" || return 2

  local synthetic
  case "$decision" in
    yes) synthetic="sim" ;;
    no)  synthetic="não" ;;
    *)   return 2 ;;
  esac

  # Resume in the conversation's working folder (claude scopes sessions to the
  # cwd). We're inside answer_main's command-substitution subshell, so this cd
  # is scoped to this one call and doesn't leak.
  local workdir
  workdir="$(conversation_workdir "$slug")"
  cd "$workdir" || return 1

  cc_handle_permission_response "$slug" "$conv_key" "answer-$(date +%s)" "$workdir" "$synthetic"
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
