# shellcheck shell=bash
# Pre-turn triage: decide how much agent a text turn actually needs.
#
# Every inbound turn costs a full agent call, and most of the bill is turns that
# didn't need one — a "valeu!" that wants no answer, a "what's 30% of 80?" that a
# small model handles as well as a big one. Jev (TypeSafe's System One model)
# answers typed questions about a message in ~100ms for a fraction of a cent, so
# before spending a turn we ask it two:
#
#   needs_reply (Noul)  — P(the message needs anything from the assistant)
#   effort (Choice)     — light (chit-chat, quick fact) vs full (tools, files,
#                         reasoning, acting for the user), with a confidence
#
# and map the answers onto a tier, printed on stdout:
#
#   skip   — react with WABOX_TRIAGE_SKIP_REACT instead of running a turn
#   light  — run the turn on WABOX_TRIAGE_LIGHT_MODEL (the backend reads it from
#            WABOX_TURN_MODEL; a conversation's explicit /model still wins)
#   full   — run the turn exactly as without triage
#
# Fail-open is the whole contract: an API error, a timeout, a malformed or
# low-confidence answer all mean `full`. Triage may make a turn cheaper; it must
# never lose one. Skipping is the only lossy outcome, so it needs Jev to be
# *very* sure (P(needs_reply) below WABOX_TRIAGE_SKIP_BELOW, default 0.05) and
# it's never silent — the reaction tells the user the message was seen.
#
# Off unless WABOX_TRIAGE=1 and an API key is set (triage_enabled).

WABOX_TRIAGE="${WABOX_TRIAGE:-0}"
# TYPESAFE_API_KEY is the name TypeSafe's own SDKs read; accept it as a fallback
# so a key already exported for them just works.
WABOX_TRIAGE_API_KEY="${WABOX_TRIAGE_API_KEY:-${TYPESAFE_API_KEY:-}}"
WABOX_TRIAGE_API_URL="${WABOX_TRIAGE_API_URL:-https://api.typesafe.ai/v1/systemone}"
WABOX_TRIAGE_MODEL="${WABOX_TRIAGE_MODEL:-jev-latest}"
WABOX_TRIAGE_TIMEOUT="${WABOX_TRIAGE_TIMEOUT:-3}"
[[ "$WABOX_TRIAGE_TIMEOUT" =~ ^[0-9]+(\.[0-9]+)?$ ]] || WABOX_TRIAGE_TIMEOUT=3
WABOX_TRIAGE_LIGHT_MODEL="${WABOX_TRIAGE_LIGHT_MODEL:-haiku}"
# Same shape check /model applies: this goes straight to `claude --model`.
[[ "$WABOX_TRIAGE_LIGHT_MODEL" =~ ^[A-Za-z][A-Za-z0-9._-]{0,63}$ ]] || WABOX_TRIAGE_LIGHT_MODEL=""
WABOX_TRIAGE_MIN_CONFIDENCE="${WABOX_TRIAGE_MIN_CONFIDENCE:-0.8}"
WABOX_TRIAGE_SKIP_BELOW="${WABOX_TRIAGE_SKIP_BELOW:-0.05}"
WABOX_TRIAGE_SKIP_REACT="${WABOX_TRIAGE_SKIP_REACT:-👍}"

triage_enabled() {
  [[ "$WABOX_TRIAGE" == "1" && -n "$WABOX_TRIAGE_API_KEY" ]]
}

# Startup check, called by the entrypoint after log.sh. Asking for triage
# without a key or curl degrades to "off" with a warning rather than refusing
# to start — the bot works fine without it, it just costs more.
triage_check() {
  [[ "$WABOX_TRIAGE" == "1" ]] || return 0
  if [[ -z "$WABOX_TRIAGE_API_KEY" ]]; then
    log_warn "WABOX_TRIAGE=1 but no WABOX_TRIAGE_API_KEY (or TYPESAFE_API_KEY); triage off"
    WABOX_TRIAGE=0
  elif ! command -v curl >/dev/null 2>&1; then
    log_warn "WABOX_TRIAGE=1 but curl is not installed; triage off"
    WABOX_TRIAGE=0
  else
    log_info "triage on: $WABOX_TRIAGE_MODEL, light=${WABOX_TRIAGE_LIGHT_MODEL:-(none)}, skip<$WABOX_TRIAGE_SKIP_BELOW"
  fi
}

# The request body. State is an object so Jev sees the bot's last words next to
# the user's — "ok" after "Want me to delete it?" is an answer, not a closer.
triage_request() {
  local text="$1" last_reply="$2"
  jq -n \
    --arg model "$WABOX_TRIAGE_MODEL" \
    --arg user "$text" \
    --arg bot "$last_reply" \
    '{
      model: $model,
      state: {assistant_last_message: $bot, user_message: $user},
      questions: {
        needs_reply: {
          type: "noul",
          instructions: "`user_message` needs a response or action from the assistant. False only for a pure acknowledgement, thanks, or sign-off (\"ok\", \"valeu\", \"👍\") that does not answer or react to a question or proposal in `assistant_last_message`."
        },
        effort: {
          type: "choice",
          instructions: "How much work answering `user_message` takes",
          criteria: {
            light: "Small talk, a greeting, or a short answer from general knowledge; no files, tools, web, code, scheduling, or multi-step reasoning",
            full: "Needs files, tools, the web, code, scheduling, acting on the user'"'"'s behalf, careful multi-step reasoning, or context from earlier in the conversation"
          }
        }
      }
    }'
}

# POST the request; the raw response JSON on stdout, non-zero on any failure.
# The key goes in via a curl config on stdin, not argv, so it never shows up in
# `ps` for the length of the call.
triage_call() {
  local body="$1"
  printf 'header = "Authorization: Bearer %s"\n' "$WABOX_TRIAGE_API_KEY" |
    curl --silent --show-error --fail \
      --max-time "$WABOX_TRIAGE_TIMEOUT" \
      --config - \
      -H "Content-Type: application/json" \
      --data-binary "$body" \
      "$WABOX_TRIAGE_API_URL"
}

# Map a Jev response to a tier. Pure (no I/O) so the policy is testable without
# the network. Anything missing or out of shape falls through to full.
triage_decide() {
  local response="$1"
  jq -r \
    --argjson skip_below "$WABOX_TRIAGE_SKIP_BELOW" \
    --argjson min_conf "$WABOX_TRIAGE_MIN_CONFIDENCE" \
    --arg light_model "$WABOX_TRIAGE_LIGHT_MODEL" \
    '(.answers.needs_reply.noul) as $nr
     | (.answers.effort.choice) as $eff
     | (.answers.effort.confidence) as $conf
     | if ($nr | type) == "number" and $nr < $skip_below then "skip"
       elif $light_model != "" and $eff == "light"
            and ($conf | type) == "number" and $conf >= $min_conf then "light"
       else "full" end' <<<"$response" 2>/dev/null || printf 'full'
}

# Tier for this turn on stdout (skip|light|full). Logs the raw answers so the
# thresholds can be tuned from agent.log.
triage_turn() {
  local slug="$1" stem="$2" text="$3"
  local body response tier
  body="$(triage_request "$text" "$(lastreply_read "$slug")")"
  if ! response="$(triage_call "$body" 2>&1)"; then
    log_warn "[$stem] triage call failed (${response:0:200}); full turn"
    printf 'full'
    return 0
  fi
  tier="$(triage_decide "$response")"
  [[ -n "$tier" ]] || tier=full
  log_info "[$stem] triage → $tier $(jq -c '{needs_reply: .answers.needs_reply.noul, effort: .answers.effort.choice, conf: .answers.effort.confidence}' <<<"$response" 2>/dev/null)"
  printf '%s' "$tier"
}
