# shellcheck shell=bash
# `wabox-bot mcp <slug>` — the scheduler as an MCP server over stdio.
#
# Why this exists: the slash commands (/in, /at, /every, /daily, /jobs, /cancel)
# are typed by the *user*. An agent asked "me lembra amanhã às 9" can't use them
# — it has no way to name its own conversation, and telling it to shell out to
# `wabox-bot cmd <slug> …` needs a slug it doesn't know plus a Bash permission.
# An MCP server closes both gaps: the slug is baked into the server's argv when
# the conversation registers it (see the claude-code backend's /mcp), so each
# tool call is already scoped, and MCP tools are permissioned as themselves
# rather than as arbitrary shell.
#
# Every tool is a thin wrapper over cmd_main — the same handle_slash_command the
# daemon and the CLI use. Nothing here re-validates a duration or a time: one
# grammar, one set of error messages, one place where WABOX_JOB_MAX is enforced.
#
# Transport: newline-delimited JSON-RPC 2.0 on stdin/stdout, which is what MCP's
# stdio transport is. Only complete JSON objects, one per line, may ever reach
# stdout — see the fd 3 discipline in mcp_main.

# The server's name in .mcp.json, and therefore the `mcp__<name>__<tool>` prefix
# the client permissions against. Guarded (not a plain assignment) because the
# claude-code backend defines the same default for /mcp without sourcing this
# file — the two halves must agree whichever loads first.
MCP_SERVER_NAME="${MCP_SERVER_NAME:-wabox}"

# The tools, verbatim as `tools/list` returns them. Descriptions are prompt
# surface, not documentation: they are what decides whether the model reaches
# for a tool at all, so they say what a job *is* (a turn in this conversation)
# and how it comes back (tagged, so the model recognises its own handiwork).
mcp_tools_json() {
  cat <<'EOF'
[
  {
    "name": "schedule_in",
    "description": "Schedule a one-off reminder for this WhatsApp conversation, a while from now. Use for \"remind me in two hours\". The reminder is delivered as a turn in this same chat, so write `text` as the instruction you want to receive later, not as a message to the user.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "delay": {"type": "string", "description": "How long from now: 90s, 30m, 2h, 1d, 1w, or a combination like 1h30m. A bare number means minutes."},
        "text": {"type": "string", "description": "What to remind about, or what to do when it fires."}
      },
      "required": ["delay", "text"]
    }
  },
  {
    "name": "schedule_at",
    "description": "Schedule a one-off reminder for this WhatsApp conversation at a wall-clock time. A bare time that has already passed today means tomorrow.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "time": {"type": "string", "description": "18:00, 9h30, 9am, or a date and time: 2026-08-12 09:00."},
        "text": {"type": "string", "description": "What to remind about, or what to do when it fires."}
      },
      "required": ["time", "text"]
    }
  },
  {
    "name": "schedule_every",
    "description": "Register a repeating check on an interval. It fires as a standing turn that is told to reply NOOP when nothing needs attention, so a quiet check sends the user nothing. Prefer this over a reminder for \"keep an eye on X\".",
    "inputSchema": {
      "type": "object",
      "properties": {
        "interval": {"type": "string", "description": "How often: 30m, 2h, 1d. Subject to a configured minimum."},
        "text": {"type": "string", "description": "What to check each time, and what is worth messaging about."}
      },
      "required": ["interval", "text"]
    }
  },
  {
    "name": "schedule_daily",
    "description": "Register a repeating check at a wall-clock time each day. Holds its hour across DST changes. Fires as a standing turn with the same NOOP suppression as schedule_every.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "time": {"type": "string", "description": "Time of day: 09:00, 9h30, 9am."},
        "text": {"type": "string", "description": "What to check, and what is worth messaging about."}
      },
      "required": ["time", "text"]
    }
  },
  {
    "name": "schedule_message",
    "description": "Schedule a message to be sent verbatim at a given time — no agent turn runs, so it costs nothing and arrives exactly as written. Prefer this over schedule_in/schedule_at whenever you already know the final wording now (\"take the pills\", \"leave for the airport\"): a reminder that only has to be repeated back should not be re-composed by a model that might reword it, pad it, or decide it isn't worth sending. Use schedule_in/schedule_at instead when the message depends on something that has to be looked up at the time.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "when": {"type": "string", "description": "A delay (2h, 30m, 1d), a time (22:00, 9am), a date and time (2026-08-12 09:00), or a repeat: \"every 2h\", \"daily 09:00\"."},
        "text": {"type": "string", "description": "The exact message to send, in the user's language. It is delivered as written."}
      },
      "required": ["when", "text"]
    }
  },
  {
    "name": "list_jobs",
    "description": "List every job scheduled in this conversation, with its id, rule, next run and text. Call this before cancelling, and to answer \"what have you got scheduled for me?\".",
    "inputSchema": {"type": "object", "properties": {}}
  },
  {
    "name": "cancel_job",
    "description": "Cancel one scheduled job by the id shown in list_jobs, or every job in this conversation.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "id": {"type": "string", "description": "The job number, or \"all\" to cancel every job in this conversation."}
      },
      "required": ["id"]
    }
  }
]
EOF
}

# tools/call → the slash command it stands for. Echoes the command's own reply
# verbatim: the agent sees exactly what the user would have seen in the chat,
# including the usage text when it passes something unparseable.
# Prints the reply on stdout; returns 1 when the tool name is unknown.
mcp_call_tool() {
  local slug="$1" name="$2" args_json="$3"
  local a b
  case "$name" in
    schedule_in)
      a="$(jq -r '.delay // ""' <<<"$args_json")"
      b="$(jq -r '.text // ""' <<<"$args_json")"
      cmd_main "$slug" "/in $a $b"
      ;;
    schedule_at)
      a="$(jq -r '.time // ""' <<<"$args_json")"
      b="$(jq -r '.text // ""' <<<"$args_json")"
      cmd_main "$slug" "/at $a $b"
      ;;
    schedule_every)
      a="$(jq -r '.interval // ""' <<<"$args_json")"
      b="$(jq -r '.text // ""' <<<"$args_json")"
      cmd_main "$slug" "/every $a $b"
      ;;
    schedule_daily)
      a="$(jq -r '.time // ""' <<<"$args_json")"
      b="$(jq -r '.text // ""' <<<"$args_json")"
      cmd_main "$slug" "/daily $a $b"
      ;;
    schedule_message)
      a="$(jq -r '.when // ""' <<<"$args_json")"
      b="$(jq -r '.text // ""' <<<"$args_json")"
      cmd_main "$slug" "/remind $a $b"
      ;;
    list_jobs)
      cmd_main "$slug" "/jobs"
      ;;
    cancel_job)
      a="$(jq -r '.id // ""' <<<"$args_json")"
      cmd_main "$slug" "/cancel $a"
      ;;
    *)
      return 1
      ;;
  esac
}

# ---- JSON-RPC plumbing -------------------------------------------------------
# All three write to fd 3, which mcp_main points at the real stdout. Nothing
# else in this process may.

mcp_emit_result() {
  jq -cn --argjson id "$1" --argjson r "$2" '{jsonrpc:"2.0", id:$id, result:$r}' >&3
}

mcp_emit_error() {
  jq -cn --argjson id "$1" --argjson c "$2" --arg m "$3" \
    '{jsonrpc:"2.0", id:$id, error:{code:$c, message:$m}}' >&3
}

# A tool failure is a *result* with isError, not a JSON-RPC error: the model is
# meant to read it and try again, which a protocol-level error wouldn't allow.
mcp_emit_text() {
  local id="$1" text="$2" is_error="${3:-false}"
  mcp_emit_result "$id" \
    "$(jq -cn --arg t "$text" --argjson e "$is_error" \
      '{content:[{type:"text", text:$t}], isError:$e}')"
}

# ---- the server --------------------------------------------------------------

# mcp_main <slug> — serve until stdin closes. One conversation per process; the
# slug is fixed at spawn time and never comes from the client, so a tool call
# can't reach another conversation's jobs.
mcp_main() {
  local slug="${1:-}"
  if [[ -z "$slug" ]]; then
    printf 'Usage: wabox-bot mcp <slug>\n' >&2
    return 1
  fi
  if [[ ! -s "$SESSIONS_DIR/$slug/conv_key" ]]; then
    printf 'wabox-bot mcp: unknown conversation slug: %s\n' "$slug" >&2
    return 1
  fi

  # Protocol discipline: fd 3 becomes the only route to the real stdout, and
  # stdout itself is re-pointed at stderr. A stray echo — from a lib we source,
  # from a future edit here — then lands in the client's server log instead of
  # corrupting the message stream, which would desync the session irrecoverably.
  exec 3>&1 1>&2

  log_debug "mcp: serving conversation $slug"

  local line method id proto name args reply rc
  while IFS= read -r line; do
    [[ -n "${line//[[:space:]]/}" ]] || continue

    method="$(jq -r 'if type == "object" then (.method // "") else "" end' <<<"$line" 2>/dev/null || true)"
    # Keep the id as raw JSON: it is a string or a number, and echoing back the
    # wrong type is a protocol violation. Absent ⇒ this is a notification, and a
    # notification must never be answered.
    id="$(jq -c 'if type == "object" then (.id // null) else null end' <<<"$line" 2>/dev/null || true)"
    [[ -n "$id" ]] || id=null

    if [[ -z "$method" ]]; then
      [[ "$id" == null ]] || mcp_emit_error "$id" -32600 "invalid request"
      continue
    fi

    case "$method" in
      initialize)
        # Echo the client's protocol version when it sent one: we speak whatever
        # dialect it opened with, since every tool here is plain tools/call.
        proto="$(jq -r '.params.protocolVersion // ""' <<<"$line" 2>/dev/null || true)"
        [[ -n "$proto" ]] || proto="2025-06-18"
        mcp_emit_result "$id" "$(jq -cn \
          --arg p "$proto" --arg n "$MCP_SERVER_NAME" --arg v "$(wabox_bot_version)" \
          '{protocolVersion:$p, capabilities:{tools:{}}, serverInfo:{name:$n, version:$v}}')"
        ;;
      notifications/*)
        : # notifications carry no id and get no reply, initialized included
        ;;
      ping)
        mcp_emit_result "$id" '{}'
        ;;
      tools/list)
        mcp_emit_result "$id" "$(jq -cn --argjson t "$(mcp_tools_json)" '{tools:$t}')"
        ;;
      tools/call)
        name="$(jq -r '.params.name // ""' <<<"$line" 2>/dev/null || true)"
        args="$(jq -c '.params.arguments // {}' <<<"$line" 2>/dev/null || true)"
        [[ -n "$args" ]] || args='{}'
        rc=0
        reply="$(mcp_call_tool "$slug" "$name" "$args" 2>/dev/null)" || rc=$?
        if ((rc == 1)) && [[ -z "$reply" ]]; then
          mcp_emit_text "$id" "Unknown tool: $name" true
        elif ((rc != 0)); then
          mcp_emit_text "$id" "wabox-bot could not run $name (exit $rc)." true
        else
          log_info "mcp[$slug] $name → ${reply%%$'\n'*}"
          mcp_emit_text "$id" "$reply" false
        fi
        ;;
      *)
        [[ "$id" == null ]] || mcp_emit_error "$id" -32601 "method not found: $method"
        ;;
    esac
  done

  log_debug "mcp: stdin closed, exiting"
  return 0
}
