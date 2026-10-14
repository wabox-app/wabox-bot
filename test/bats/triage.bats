load test_helper

# Pre-turn triage (lib/triage.sh) wired through the drain in lib/inbox.sh. The
# network is a stub `curl` on PATH that replays $STUB_RESPONSE (or fails when
# $STUB_FAIL=1) and records its stdin/body, so no test talks to TypeSafe.

setup() {
  setup_lib
  export WABOX_BOT_BACKEND=echo
  load_core
  # shellcheck source=lib/inbox.sh
  source "$LIB_DIR/inbox.sh"
  DM="5511999999999@s.whatsapp.net"
  SLUG="$(printf '%s' "$DM" | sha1sum | awk '{print $1}')"

  WABOX_TRIAGE=1
  WABOX_TRIAGE_API_KEY="test-key"

  STUB_BIN="$TMPDIR_TEST/bin"
  mkdir -p "$STUB_BIN"
  export STUB_RESPONSE="$TMPDIR_TEST/response.json"
  export STUB_LOG="$TMPDIR_TEST/curl.log"
  cat >"$STUB_BIN/curl" <<'EOF'
#!/usr/bin/env bash
# Record the config fed on stdin (the auth header) and the --data-binary body.
cat >"$STUB_LOG.stdin"
while (($#)); do
  [[ "$1" == "--data-binary" ]] && printf '%s' "$2" >"$STUB_LOG.body"
  printf '%s\n' "$1" >>"$STUB_LOG.argv"
  shift
done
[[ "${STUB_FAIL:-0}" == "1" ]] && { echo "curl: (28) timed out" >&2; exit 28; }
cat "$STUB_RESPONSE"
EOF
  chmod +x "$STUB_BIN/curl"
  export PATH="$STUB_BIN:$PATH"

  # Report the model the backend was asked to use, so the tier is observable.
  backend_reply() {
    cat >/dev/null
    printf 'model=%s' "${WABOX_TURN_MODEL:-}"
  }
}

teardown() {
  teardown_lib
}

mk_text() {
  local stem="$1" id="$2" text="$3"
  jq -nc --arg j "$DM" --arg id "$id" --arg t "$text" '{id:$id, from:$j, text:$t}' \
    >"$WABOX_INBOX/$stem.json"
}

answers() {
  local nr="$1" eff="$2" conf="$3"
  jq -nc --argjson nr "$nr" --arg eff "$eff" --argjson conf "$conf" \
    '{model:"jev-1.13.0", answers:{
        needs_reply:{type:"noul", noul:$nr},
        effort:{type:"choice", choice:$eff, confidence:$conf}}}' >"$STUB_RESPONSE"
}

# ---- triage_decide (pure policy) -------------------------------------------

@test "decide: confident light → light; low confidence → full" {
  [ "$(triage_decide '{"answers":{"needs_reply":{"noul":0.9},"effort":{"choice":"light","confidence":0.95}}}')" = light ]
  [ "$(triage_decide '{"answers":{"needs_reply":{"noul":0.9},"effort":{"choice":"light","confidence":0.5}}}')" = full ]
  [ "$(triage_decide '{"answers":{"needs_reply":{"noul":0.9},"effort":{"choice":"full","confidence":0.99}}}')" = full ]
}

@test "decide: needs_reply under the threshold → skip; 0 disables skipping" {
  [ "$(triage_decide '{"answers":{"needs_reply":{"noul":0.01},"effort":{"choice":"light","confidence":1}}}')" = skip ]
  WABOX_TRIAGE_SKIP_BELOW=0
  [ "$(triage_decide '{"answers":{"needs_reply":{"noul":0.01},"effort":{"choice":"light","confidence":1}}}')" = light ]
}

@test "decide: garbage, errors, and missing answers fail open to full" {
  [ "$(triage_decide 'not json')" = full ]
  [ "$(triage_decide '{"error":"bad request"}')" = full ]
  [ "$(triage_decide '{"answers":{}}')" = full ]
}

@test "decide: an empty light model disables the light tier" {
  WABOX_TRIAGE_LIGHT_MODEL=""
  [ "$(triage_decide '{"answers":{"needs_reply":{"noul":0.9},"effort":{"choice":"light","confidence":1}}}')" = full ]
}

# ---- through the handler ---------------------------------------------------

@test "light tier runs the turn on WABOX_TRIAGE_LIGHT_MODEL" {
  answers 0.9 light 0.97
  mk_text s1 M1 "bom dia!"
  handle_envelope "$WABOX_INBOX/s1.json"
  [ "$(jq -r '.text' "$WABOX_OUTBOX/s1.json")" = "model=haiku" ]
}

@test "full tier runs the turn with no model hint" {
  answers 0.99 full 0.9
  mk_text s2 M2 "refatora o script de backup"
  handle_envelope "$WABOX_INBOX/s2.json"
  [ "$(jq -r '.text' "$WABOX_OUTBOX/s2.json")" = "model=" ]
}

@test "skip tier reacts instead of replying" {
  answers 0.01 light 0.99
  mk_text s3 M3 "valeu!"
  handle_envelope "$WABOX_INBOX/s3.json"
  [ ! -e "$WABOX_OUTBOX/s3.json" ]
  [ "$(jq -r '.react.emoji' "$WABOX_OUTBOX/s3-skip.json")" = "👍" ]
  [ "$(jq -r '.react.messageId' "$WABOX_OUTBOX/s3-skip.json")" = "M3" ]
}

@test "a failed triage call falls back to a full turn" {
  export STUB_FAIL=1
  mk_text s4 M4 "oi"
  handle_envelope "$WABOX_INBOX/s4.json"
  [ "$(jq -r '.text' "$WABOX_OUTBOX/s4.json")" = "model=" ]
  grep -q "triage call failed" "$LOG_FILE"
}

@test "triage off (default) never calls the API" {
  WABOX_TRIAGE=0
  answers 0.01 light 1
  mk_text s5 M5 "valeu"
  handle_envelope "$WABOX_INBOX/s5.json"
  [ "$(jq -r '.text' "$WABOX_OUTBOX/s5.json")" = "model=" ]
  [ ! -e "$STUB_LOG.body" ]
}

@test "a parked permission bypasses triage so the yes/no reaches the backend" {
  backend_turn_parked() { return 0; }
  answers 0.01 light 1
  mk_text s6 M6 "sim"
  handle_envelope "$WABOX_INBOX/s6.json"
  [ -e "$WABOX_OUTBOX/s6.json" ]
  [ ! -e "$STUB_LOG.body" ]
}

@test "the request carries the bot's last reply as context and the key off argv" {
  answers 0.9 full 0.9
  mk_text s7 M7 "primeiro"
  handle_envelope "$WABOX_INBOX/s7.json"
  mk_text s8 M8 "ok"
  handle_envelope "$WABOX_INBOX/s8.json"
  [ "$(jq -r '.state.assistant_last_message' "$STUB_LOG.body")" = "model=" ]
  [ "$(jq -r '.state.user_message' "$STUB_LOG.body")" = "ok" ]
  [ "$(jq -r '.model' "$STUB_LOG.body")" = "jev-latest" ]
  grep -q 'Authorization: Bearer test-key' "$STUB_LOG.stdin"
  ! grep -q 'test-key' "$STUB_LOG.argv"
}

@test "lastreply keeps the tail of a long reply" {
  long="$(printf 'a%.0s' {1..1000})FIM?"
  lastreply_write "$SLUG" "$long"
  got="$(lastreply_read "$SLUG")"
  [ "${#got}" -eq 600 ]
  [[ "$got" == *"FIM?" ]]
}
