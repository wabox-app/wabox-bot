# Atomic outbox writer.
#
# wabox treats any *.json in outbox/ as a job and starts sending immediately,
# so writes MUST be atomic — a half-written file gets picked up. We write
# under a dot-prefixed temp name (which wabox ignores by glob) and rename
# into place.

write_outbox() {
  local to="$1" text="$2" reply_to_id="$3" stem="$4"

  local tmp="$WABOX_OUTBOX/.${stem}.tmp.json"
  local final="$WABOX_OUTBOX/${stem}.json"

  jq -n \
    --arg to "$to" \
    --arg text "$text" \
    --arg rid "$reply_to_id" \
    '{to: $to, text: $text} + (if $rid == "" then {} else {replyTo: {id: $rid}} end)' \
    >"$tmp"
  mv "$tmp" "$final"
  printf '%s' "$final"
}
