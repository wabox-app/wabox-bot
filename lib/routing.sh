# Conversation routing.
#
# A "conversation key" maps an inbox envelope to a logical agent thread:
#   DM            → from JID (e.g. "5511...@s.whatsapp.net" or "...@lid")
#   Group         → from JID (the @g.us)
#   Group, per-participant → "from|participant"
# We hash that to a short filename slug. Per-conversation state files
# (session id, overrides) are owned by the active backend and live under
# $SESSIONS_DIR keyed by slug.

conversation_key() {
  local envelope_json="$1"
  local from participant
  from="$(jq -r '.from // empty' <<<"$envelope_json")"
  participant="$(jq -r '.participant // empty' <<<"$envelope_json")"

  if [[ "$GROUP_PER_PARTICIPANT" == "1" && -n "$participant" ]]; then
    printf '%s|%s' "$from" "$participant"
  else
    printf '%s' "$from"
  fi
}

# Hash a conversation key into a safe filename slug.
key_slug() {
  printf '%s' "$1" | sha1sum | awk '{print $1}'
}
