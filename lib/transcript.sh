# Merged conversation transcript for external tooling (`wabox-bot transcript`).
#
# Renders one conversation's inbound+outbound timeline as versioned JSON, the
# stable contract wabox-tui reads instead of scanning wabox's directories
# itself. Everything here is a pure read: no locks, no mutations.
#
# The layout stays private, but the *envelope* and *outbox-job* JSON are public,
# documented wabox formats — so we read those and do the slug→conversation
# routing here (the same rule as lib/routing.sh), which is exactly the coupling
# we don't want consumers to reimplement. Inbound turns come from PROCESSED_DIR
# envelopes (needs KEEP_PROCESSED=1); outbound turns from wabox-core's
# "$WABOX_OUTBOX/sent" archive. If either source is pruned, that direction just
# renders empty — the other still shows.
#
# Ordering: inbound uses the envelope's own `.timestamp`; outbound uses the send
# time wabox-core encodes as the archived filename's leading epoch-ms.
#
# See docs/superpowers/specs/2026-07-06-state-and-answer-design.md for the
# sibling `state`/`answer` contract this extends.
#
# Exit codes:
#   0  ok (turns may be empty — unknown/未-messaged conversations render clean)
#   1  usage error

TRANSCRIPT_DEFAULT_LIMIT=200

# Inbound turns as a JSON array on stdout. One jq pass over every processed
# envelope, filtered by the routing rule: a DM matches on `.from`; a
# per-participant group also matches `.participant`. Envelopes are validated by
# inbox.sh before they land in PROCESSED_DIR (bad JSON is quarantined as
# `*.json.invalid`, which this glob skips), so the slurp won't hit malformed
# input. `at` parses the ISO `.timestamp`, tolerating a missing/odd value (⇒ 0).
_transcript_inbound() {
  local from="$1" participant="$2"
  shopt -s nullglob
  local -a files=("$PROCESSED_DIR"/*.json)
  shopt -u nullglob
  if ((${#files[@]} == 0)); then printf '[]'; return; fi

  jq -n \
    --arg from "$from" \
    --arg participant "$participant" \
    '[ inputs
       | select(.from == $from)
       | select($participant == "" or .participant == $participant)
       | { at: (.timestamp as $t
                | try ($t | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch 0),
           direction: "in",
           id: (.id // null),
           name: (.pushName // null),
           text: (.text // ""),
           media: (if (.media | type) == "object" then { type: .media.type } else null end) } ]' \
    "${files[@]}" 2>/dev/null || printf '[]'
}

# Outbound turns as a JSON array on stdout. wabox-core moves each sent job into
# "$WABOX_OUTBOX/sent" with a "<epoch-ms>_<localtime>_<jid>_<hash>.json" name;
# we match jobs addressed to this conversation's chat JID (the part before `|`
# for per-participant keys — outbox jobs aren't participant-tagged, so a
# per-participant group can't distinguish who a reply was "to") and read the
# send time from that filename via jq's `input_filename` (⇒ 0 if unparseable).
_transcript_outbound() {
  local to="$1"
  local sent_dir="$WABOX_OUTBOX/sent"
  [[ -d "$sent_dir" ]] || { printf '[]'; return; }

  shopt -s nullglob
  local -a files=("$sent_dir"/*.json)
  shopt -u nullglob
  if ((${#files[@]} == 0)); then printf '[]'; return; fi

  jq -n \
    --arg to "$to" \
    '[ inputs
       | select(.to == $to)
       | { at: (try (input_filename | sub(".*/"; "") | capture("^(?<ms>[0-9]{10,})_").ms
                     | tonumber / 1000 | floor) catch 0),
           direction: "out",
           id: (.replyTo.id // null),
           name: null,
           text: (.text // ""),
           media: null } ]' \
    "${files[@]}" 2>/dev/null || printf '[]'
}

# Emit the whole transcript object on stdout for one slug.
transcript_json() {
  local slug="$1" limit="$2"

  # conv_key is the only way back from the one-way slug to the routable JID.
  # Absent (a conversation predating conv_key persistence, or a bad slug) ⇒
  # render an empty-but-valid transcript rather than failing the TUI.
  local conv_key="" has_key=false
  if [[ -s "$SESSIONS_DIR/$slug/conv_key" ]]; then
    conv_key="$(cat -- "$SESSIONS_DIR/$slug/conv_key")"
    has_key=true
  fi

  # DM key is the JID; per-participant group key is "<from>|<participant>".
  local from="${conv_key%%|*}" participant=""
  [[ "$conv_key" == *"|"* ]] && participant="${conv_key#*|}"

  local inbound='[]' outbound='[]'
  if [[ -n "$conv_key" ]]; then
    inbound="$(_transcript_inbound "$from" "$participant")"
    outbound="$(_transcript_outbound "$from")"
  fi

  local keep=false
  [[ "$KEEP_PROCESSED" == "1" ]] && keep=true

  # sort_by is stable, so inbound wins ties against outbound (it's listed
  # first) — reads naturally as "question then answer" when both share a second.
  jq -n \
    --arg slug "$slug" \
    --arg conv_key "$conv_key" \
    --argjson has_key "$has_key" \
    --argjson keep "$keep" \
    --argjson limit "$limit" \
    --argjson inbound "$inbound" \
    --argjson outbound "$outbound" \
    '($inbound + $outbound | sort_by(.at)) as $all
     | (if $limit > 0 then $all[-$limit:] else $all end) as $shown
     | { version: 1,
         slug: $slug,
         conv_key: (if $has_key then $conv_key else null end),
         keep_processed: $keep,
         total: ($all | length),
         count: ($shown | length),
         turns: $shown }'
}

# CLI entry point for the `transcript` subcommand.
#   wabox-bot transcript <slug> [--limit N]   (JSON only in v1)
transcript_cli() {
  local slug="" limit="$TRANSCRIPT_DEFAULT_LIMIT"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) shift ;; # accepted for symmetry with `state --json`; JSON is the only mode
      --limit)
        [[ $# -ge 2 ]] || { printf 'wabox-bot transcript: --limit requires a value\n' >&2; return 1; }
        limit="$2"; shift 2 ;;
      --limit=*) limit="${1#--limit=}"; shift ;;
      -*)
        printf 'wabox-bot transcript: unknown argument: %s\n' "$1" >&2
        return 1 ;;
      *)
        if [[ -n "$slug" ]]; then
          printf 'wabox-bot transcript: unexpected argument: %s\n' "$1" >&2
          return 1
        fi
        slug="$1"; shift ;;
    esac
  done

  if [[ -z "$slug" ]]; then
    printf 'Usage: wabox-bot transcript <slug> [--limit N]\n' >&2
    return 1
  fi
  if [[ ! "$limit" =~ ^[0-9]+$ ]]; then
    printf 'wabox-bot transcript: --limit must be a non-negative integer (got: %s)\n' "$limit" >&2
    return 1
  fi

  transcript_json "$slug" "$limit"
}
