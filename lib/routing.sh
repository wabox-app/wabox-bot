# Conversation routing + per-conversation state on disk.
#
# A "conversation key" maps an inbox envelope to a logical Claude thread:
#   DM            → from JID (e.g. "5511...@s.whatsapp.net" or "...@lid")
#   Group         → from JID (the @g.us)
#   Group, per-participant → "from|participant"
# We hash that to a short filename slug. The state files (session id, model,
# mode, system prompt overrides) live under $SESSIONS_DIR keyed by slug.

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

session_id_for() {
  local f="$SESSIONS_DIR/$1.session"
  [[ -s "$f" ]] && cat "$f"
}

save_session_id() {
  local slug="$1" sid="$2"
  printf '%s\n' "$sid" >"$SESSIONS_DIR/$slug.session"
}

# Per-conversation model override — set via /model and consumed when
# building the claude command. Lives alongside the session file.
model_for() {
  local f="$SESSIONS_DIR/$1.model"
  [[ -s "$f" ]] && cat "$f"
}

save_model_for() {
  local slug="$1" name="$2"
  printf '%s\n' "$name" >"$SESSIONS_DIR/$slug.model"
}

# Per-conversation --permission-mode override. Same lifecycle as model.
mode_for() {
  local f="$SESSIONS_DIR/$1.mode"
  [[ -s "$f" ]] && cat "$f"
}

save_mode_for() {
  local slug="$1" name="$2"
  printf '%s\n' "$name" >"$SESSIONS_DIR/$slug.mode"
}

# Per-conversation system prompt override. Stored verbatim (no trailing
# newline added) so multi-line prompts round-trip; appended via
# --append-system-prompt on top of any global SYSTEM_PROMPT_FILE.
system_for() {
  local f="$SESSIONS_DIR/$1.system"
  [[ -s "$f" ]] && cat "$f"
}

save_system_for() {
  local slug="$1" prompt="$2"
  printf '%s' "$prompt" >"$SESSIONS_DIR/$slug.system"
}
