load test_helper

# lib/transcript.sh merges a conversation's inbound (processed envelopes) and
# outbound (outbox/sent jobs) into one versioned, time-ordered JSON transcript.

setup() {
  setup_lib
  WABOX_BOT_BACKEND=claude-code load_core
  # shellcheck source=lib/transcript.sh
  source "$LIB_DIR/transcript.sh"
  mkdir -p "$PROCESSED_DIR" "$WABOX_OUTBOX/sent"
}

teardown() {
  teardown_lib
}

# Map a conv_key to a slug the way lib/inbox.sh does, and persist the reverse
# mapping transcript_json reads back.
seed_slug() {
  local conv_key="$1" slug
  slug="$(key_slug "$conv_key")"
  mkdir -p "$SESSIONS_DIR/$slug"
  printf '%s\n' "$conv_key" >"$SESSIONS_DIR/$slug/conv_key"
  printf '%s' "$slug"
}

# Drop a processed inbound envelope (public wabox format).
seed_inbound() {
  local name="$1" from="$2" ts="$3" text="$4" participant="${5:-null}" media="${6:-null}"
  jq -nc \
    --arg from "$from" --arg ts "$ts" --arg text "$text" \
    --argjson participant "$( [[ $participant == null ]] && echo null || printf '"%s"' "$participant")" \
    --argjson media "$media" \
    '{id:"MID", from:$from, participant:$participant, pushName:"Tester",
      fromMe:false, timestamp:$ts, text:$text, media:$media}' \
    >"$PROCESSED_DIR/$name.json"
}

# Drop an archived outbound job the way wabox-core names it: "<epoch-ms>_...".
seed_outbound() {
  local ms="$1" to="$2" text="$3"
  jq -nc --arg to "$to" --arg text "$text" '{to:$to, text:$text, replyTo:{id:"RID"}}' \
    >"$WABOX_OUTBOX/sent/${ms}_20260101-000000_x_ABCD.json"
}

@test "top-level schema: version, slug, conv_key, turns array" {
  slug="$(seed_slug "5511@s.whatsapp.net")"
  run transcript_json "$slug" 200
  [ "$status" -eq 0 ]
  [ "$(jq -r '.version' <<<"$output")" = "1" ]
  [ "$(jq -r '.slug' <<<"$output")" = "$slug" ]
  [ "$(jq -r '.conv_key' <<<"$output")" = "5511@s.whatsapp.net" ]
  [ "$(jq -r '.turns | type' <<<"$output")" = "array" ]
}

@test "an inbound envelope surfaces as an in turn with parsed timestamp" {
  slug="$(seed_slug "5511@s.whatsapp.net")"
  seed_inbound m1 "5511@s.whatsapp.net" "2026-06-03T08:36:21.000Z" "Eita"
  run transcript_json "$slug" 200
  [ "$(jq -r '.count' <<<"$output")" = "1" ]
  [ "$(jq -r '.turns[0].direction' <<<"$output")" = "in" ]
  [ "$(jq -r '.turns[0].text' <<<"$output")" = "Eita" ]
  # 2026-06-03T08:36:21Z == 1780475781
  [ "$(jq -r '.turns[0].at' <<<"$output")" = "1780475781" ]
}

@test "an outbound job surfaces with the send time from its filename" {
  slug="$(seed_slug "5511@s.whatsapp.net")"
  seed_outbound 1780475900000 "5511@s.whatsapp.net" "olá"
  run transcript_json "$slug" 200
  [ "$(jq -r '.count' <<<"$output")" = "1" ]
  [ "$(jq -r '.turns[0].direction' <<<"$output")" = "out" ]
  [ "$(jq -r '.turns[0].text' <<<"$output")" = "olá" ]
  [ "$(jq -r '.turns[0].at' <<<"$output")" = "1780475900" ]
}

@test "turns are merged and ordered oldest-first across directions" {
  slug="$(seed_slug "5511@s.whatsapp.net")"
  seed_inbound m1 "5511@s.whatsapp.net" "2026-06-03T08:00:00.000Z" "first-in"
  seed_outbound 1780473700000 "5511@s.whatsapp.net" "reply"   # 08:01:40Z
  seed_inbound m2 "5511@s.whatsapp.net" "2026-06-03T08:05:00.000Z" "second-in"
  run transcript_json "$slug" 200
  [ "$(jq -r '.count' <<<"$output")" = "3" ]
  [ "$(jq -r '[.turns[].text] | join(",")' <<<"$output")" = "first-in,reply,second-in" ]
}

@test "media envelope with no text records a media marker" {
  slug="$(seed_slug "5511@s.whatsapp.net")"
  seed_inbound m1 "5511@s.whatsapp.net" "2026-06-03T08:00:00.000Z" "" null \
    '{"type":"image","file":"p.jpg","mimetype":"image/jpeg"}'
  run transcript_json "$slug" 200
  [ "$(jq -r '.turns[0].media.type' <<<"$output")" = "image" ]
  [ "$(jq -r '.turns[0].text' <<<"$output")" = "" ]
}

@test "envelopes from other conversations are excluded" {
  slug="$(seed_slug "5511@s.whatsapp.net")"
  seed_inbound mine  "5511@s.whatsapp.net"  "2026-06-03T08:00:00.000Z" "mine"
  seed_inbound other "5522@s.whatsapp.net"  "2026-06-03T08:00:00.000Z" "not-mine"
  run transcript_json "$slug" 200
  [ "$(jq -r '.count' <<<"$output")" = "1" ]
  [ "$(jq -r '.turns[0].text' <<<"$output")" = "mine" ]
}

@test "per-participant group key filters on both from and participant" {
  export GROUP_PER_PARTICIPANT=1
  slug="$(seed_slug "123@g.us|5511@s.whatsapp.net")"
  seed_inbound a "123@g.us" "2026-06-03T08:00:00.000Z" "from-alice" "5511@s.whatsapp.net"
  seed_inbound b "123@g.us" "2026-06-03T08:00:00.000Z" "from-bob"   "5599@s.whatsapp.net"
  run transcript_json "$slug" 200
  [ "$(jq -r '.count' <<<"$output")" = "1" ]
  [ "$(jq -r '.turns[0].text' <<<"$output")" = "from-alice" ]
}

@test "unknown slug (no conv_key) renders empty but valid, exit 0" {
  run transcript_json "deadbeef" 200
  [ "$status" -eq 0 ]
  [ "$(jq -r '.conv_key' <<<"$output")" = "null" ]
  [ "$(jq -r '.count' <<<"$output")" = "0" ]
  [ "$(jq -r '.turns | length' <<<"$output")" = "0" ]
}

@test "limit keeps only the most recent N turns" {
  slug="$(seed_slug "5511@s.whatsapp.net")"
  seed_inbound m1 "5511@s.whatsapp.net" "2026-06-03T08:00:00.000Z" "one"
  seed_inbound m2 "5511@s.whatsapp.net" "2026-06-03T08:01:00.000Z" "two"
  seed_inbound m3 "5511@s.whatsapp.net" "2026-06-03T08:02:00.000Z" "three"
  run transcript_json "$slug" 2
  [ "$(jq -r '.total' <<<"$output")" = "3" ]
  [ "$(jq -r '.count' <<<"$output")" = "2" ]
  [ "$(jq -r '[.turns[].text] | join(",")' <<<"$output")" = "two,three" ]
}

@test "keep_processed mirrors KEEP_PROCESSED" {
  slug="$(seed_slug "5511@s.whatsapp.net")"
  KEEP_PROCESSED=1 run transcript_json "$slug" 200
  [ "$(jq -r '.keep_processed' <<<"$output")" = "true" ]
  KEEP_PROCESSED=0 run transcript_json "$slug" 200
  [ "$(jq -r '.keep_processed' <<<"$output")" = "false" ]
}

@test "transcript_cli requires a slug and validates --limit" {
  run transcript_cli
  [ "$status" -eq 1 ]
  run transcript_cli "somelug" --limit notanumber
  [ "$status" -eq 1 ]
}
