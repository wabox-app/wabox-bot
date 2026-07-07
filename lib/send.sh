# `wabox-bot send <slug> [text]` — deliver a message to a conversation with no
# agent turn involved. This is dumb delivery: it writes a single outbox job and
# returns. No daemon is required (wabox sends any *.json that lands in outbox/)
# and no lock is taken — the outbox write is atomic on its own.
#
# Recipient forms (mutually exclusive):
#   <slug>          an existing conversation; conv_key is resolved from
#                   $SESSIONS_DIR/<slug>/conv_key (the only way back from the
#                   one-way slug to the routable JID) and the reply lands on the
#                   chat JID (conv_key before the "|" for a group-per-participant
#                   key). A `direction:"out"` last_message record is written.
#   --to <jid|number>
#                   a raw recipient with no prior conversation — operator-only
#                   power, identical to typing into the app. Passed to the job
#                   verbatim (wabox normalizes a bare number to a JID). No
#                   last_message is written (there is no slug to key it under).
#
# Text: a positional after the recipient. Omitted or `-` reads stdin (multi-line
# friendly); with --file attachments on a terminal, an omitted text is a
# files-only delivery rather than a blocking stdin read. `--file <path>`
# (repeatable) attaches files via the outbox `extras` arg.
#
# Exit codes (stable contract):
#   0  delivered
#   1  usage / unknown slug / unreadable --file / nothing to send

send_main() {
  local to_flag="" slug="" text_arg="" text_set=0 pos_count=0
  local -a files=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --to)
        [[ $# -ge 2 ]] || { printf 'wabox-bot send: --to requires a value\n' >&2; return 1; }
        to_flag="$2"; shift 2 ;;
      --to=*)
        to_flag="${1#--to=}"; shift ;;
      --file)
        [[ $# -ge 2 ]] || { printf 'wabox-bot send: --file requires a value\n' >&2; return 1; }
        files+=("$2"); shift 2 ;;
      --file=*)
        files+=("${1#--file=}"); shift ;;
      --)
        shift
        # Everything after `--` is positional (lets a text start with a dash).
        while [[ $# -gt 0 ]]; do
          _send_take_positional "$1" || return 1
          shift
        done ;;
      -*)
        # A lone "-" is the stdin marker, a valid positional; other dash args
        # are unknown flags.
        if [[ "$1" == "-" ]]; then
          _send_take_positional "$1" || return 1
          shift
        else
          printf 'wabox-bot send: unknown option: %s\n' "$1" >&2
          return 1
        fi ;;
      *)
        _send_take_positional "$1" || return 1
        shift ;;
    esac
  done

  # Reconcile positionals against the recipient mode. With --to the only
  # positional is the text; with a slug the positionals are <slug> [text].
  if [[ -n "$to_flag" ]]; then
    if ((pos_count > 1)); then
      printf 'wabox-bot send: --to takes at most a text argument (got a slug too)\n' >&2
      return 1
    fi
    # The single positional collected (if any) is the text, not a slug.
    if [[ -n "$slug" ]]; then text_arg="$slug"; text_set=1; slug=""; fi
  else
    if [[ -z "$slug" ]]; then
      printf 'Usage: wabox-bot send <slug> [text] | send --to <jid> [text]\n' >&2
      return 1
    fi
    if ((pos_count > 2)); then
      printf 'wabox-bot send: too many arguments\n' >&2
      return 1
    fi
  fi

  # Resolve the recipient JID.
  local to conv_key=""
  if [[ -n "$to_flag" ]]; then
    to="$to_flag"
  else
    if [[ -s "$SESSIONS_DIR/$slug/conv_key" ]]; then
      conv_key="$(cat -- "$SESSIONS_DIR/$slug/conv_key")"
    fi
    if [[ -z "$conv_key" ]]; then
      printf 'wabox-bot send: unknown conversation slug: %s\n' "$slug" >&2
      return 1
    fi
    to="${conv_key%%|*}"
  fi

  # Validate attachments and resolve them to absolute paths — wabox reads the
  # files relative to its own cwd, not the caller's, so a relative path would
  # not be found. Build the extras object exactly as lib/inbox.sh does.
  local extras=""
  if ((${#files[@]})); then
    local -a abs=()
    local f real
    for f in "${files[@]}"; do
      if [[ ! -f "$f" || ! -r "$f" ]]; then
        printf 'wabox-bot send: file not found or unreadable: %s\n' "$f" >&2
        return 1
      fi
      real="$(readlink -f -- "$f")" || real="$f"
      abs+=("$real")
    done
    local files_json
    files_json="$(printf '%s\n' "${abs[@]}" | jq -R . | jq -cs .)"
    extras="$(jq -cn --argjson files "$files_json" '{files: $files}')"
  fi

  # Resolve the message text. `-` always reads stdin; an omitted text reads
  # stdin too, except when files are attached and stdin is a terminal (that's a
  # files-only delivery, and blocking on stdin would hang the operator).
  local text
  if ((text_set)); then
    if [[ "$text_arg" == "-" ]]; then
      text="$(cat)"
    else
      text="$text_arg"
    fi
  elif ((${#files[@]})) && [[ -t 0 ]]; then
    text=""
  else
    text="$(cat)"
  fi

  if [[ -z "$text" && ${#files[@]} -eq 0 ]]; then
    printf 'wabox-bot send: nothing to send (empty text and no --file)\n' >&2
    return 1
  fi

  local stem="send-$(date +%s)-$$"
  local out
  out="$(write_outbox "$to" "$text" "" "$stem" "$extras")"
  log_info "send[${slug:-$to}] delivered → $out"

  # Only the slug path has a conversation to record against.
  [[ -n "$slug" ]] && lastmsg_write "$slug" out "$text"
  return 0
}

# Collect a positional argument into slug/text. The first goes to `slug` (which
# `send_main` reinterprets as text under --to), the second to `text_arg`; a
# third is an error, flagged by the pos_count the caller checks.
_send_take_positional() {
  case "$pos_count" in
    0) slug="$1" ;;
    1) text_arg="$1"; text_set=1 ;;
  esac
  ((pos_count++)) || true
  return 0
}
