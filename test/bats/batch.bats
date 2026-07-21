load test_helper

# Per-conversation message batching (lib/batch.sh): the queue primitives and an
# end-to-end coalesce through handle_envelope.

setup() {
  setup_lib
  export WABOX_BOT_BACKEND=echo
  load_core
  # shellcheck source=lib/inbox.sh
  source "$LIB_DIR/inbox.sh"
  SLUG="testslug"
}

teardown() {
  teardown_lib
}

# ---- queue primitives -----------------------------------------------------

@test "batch_settle returns 1 (empty) without sleeping when the queue is empty" {
  export WABOX_BATCH_WINDOW=99   # would hang if it ever slept
  run batch_settle "$SLUG"
  [ "$status" -eq 1 ]
}

@test "batch_append then batch_collect merges texts in arrival order, joined by blank lines" {
  batch_append "$SLUG" "primeira" "" "" "" "M1" "" "j@x" "s1"
  batch_append "$SLUG" "segunda" "" "" "" "M2" "" "j@x" "s2"
  merged="$(batch_collect "$SLUG")"
  [ "$(jq -r '.text' <<<"$merged")" = "primeira"$'\n\n'"segunda" ]
  [ "$(jq -r '.count' <<<"$merged")" = "2" ]
}

@test "batch_collect takes id/participant/to/stem from the newest (last) part" {
  batch_append "$SLUG" "a" "" "" "" "M1" "p1" "j@x" "s1"
  batch_append "$SLUG" "b" "" "" "" "M2" "p2" "j@x" "s2"
  merged="$(batch_collect "$SLUG")"
  [ "$(jq -r '.id' <<<"$merged")" = "M2" ]
  [ "$(jq -r '.participant' <<<"$merged")" = "p2" ]
  [ "$(jq -r '.stem' <<<"$merged")" = "s2" ]
}

@test "batch_collect gathers every part's media into the manifest, skipping text-only parts" {
  batch_append "$SLUG" "caption" ".wabox/media/a.jpg" "image" "image/jpeg" "M1" "" "j@x" "s1"
  batch_append "$SLUG" "just text" "" "" "" "M2" "" "j@x" "s2"
  batch_append "$SLUG" "" ".wabox/media/c.pdf" "document" "application/pdf" "M3" "" "j@x" "s3"
  merged="$(batch_collect "$SLUG")"
  [ "$(jq -r '.media | length' <<<"$merged")" = "2" ]
  [ "$(jq -r '.media[0].path' <<<"$merged")" = ".wabox/media/a.jpg" ]
  [ "$(jq -r '.media[1].type' <<<"$merged")" = "document" ]
  # Blank text parts are dropped from the joined text.
  [ "$(jq -r '.text' <<<"$merged")" = "caption"$'\n\n'"just text" ]
}

@test "batch_collect drains the queue: a second collect finds nothing (loser returns quietly)" {
  batch_append "$SLUG" "only" "" "" "" "M1" "" "j@x" "s1"
  batch_collect "$SLUG" >/dev/null
  run batch_collect "$SLUG"
  [ "$status" -eq 1 ]
}

# ---- end-to-end coalesce through handle_envelope --------------------------

@test "a burst coalesces into ONE turn: a queued part + a new envelope merge" {
  JID="5511999999999@s.whatsapp.net"
  DM_SLUG="$(printf '%s' "$JID" | sha1sum | awk '{print $1}')"

  # Simulate the first message of the burst already sitting in the queue (as a
  # parallel ingest worker would have left it), then let the second envelope's
  # handler drain both. WABOX_BATCH_WINDOW=0 (from setup_lib) drains at once.
  batch_append "$DM_SLUG" "primeira" "" "" "" "M1" "" "$JID" "burst-a"

  jq -nc --arg j "$JID" '{id:"M2", from:$j, text:"segunda"}' >"$WABOX_INBOX/burst-b.json"
  handle_envelope "$WABOX_INBOX/burst-b.json"

  # One merged echo turn, stem = newest part (burst-b); no separate turn for M1.
  [ -f "$WABOX_OUTBOX/burst-b.json" ]
  [ "$(jq -r '.text' "$WABOX_OUTBOX/burst-b.json")" = "echo: primeira"$'\n\n'"segunda" ]
}
