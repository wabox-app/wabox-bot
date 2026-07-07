# Atomic outbox writer.
#
# wabox treats any *.json in outbox/ as a job and starts sending immediately,
# so writes MUST be atomic — a half-written file gets picked up. We write
# under a dot-prefixed temp name (which wabox ignores by glob) and rename
# into place.

# write_outbox <to> <text> <reply_to_id> <stem> [extras_json]
#
# `extras_json`, when given, is a JSON *object* merged into the job — it carries
# the richer fields core understands but the four-arg callers never need:
# `react`, `files`, and a full `replyTo` (with `participant`). It's merged last,
# so `extras.replyTo` wins over one synthesised from the `reply_to_id` arg (the
# quote path passes the richer object through extras). Merged via `--argjson`,
# never string-spliced. An empty/invalid extras degrades to the plain job rather
# than blocking delivery — a dropped reaction is better than a lost reply.
#
# `text` is omitted from the job when empty: a react-only ack or a files-only
# delivery is a valid job with no body, and core is happy with `{to, react}` or
# `{to, files}`. Real reply/​command callers always pass non-empty text, so the
# four-arg output stays byte-identical.
write_outbox() {
  local to="$1" text="$2" reply_to_id="$3" stem="$4" extras="${5:-}"

  local tmp="$WABOX_OUTBOX/.${stem}.tmp.json"
  local final="$WABOX_OUTBOX/${stem}.json"

  if [[ -n "$extras" ]] && ! jq -e 'type=="object"' >/dev/null 2>&1 <<<"$extras"; then
    log_warn "[$stem] ignoring invalid outbox extras: $extras"
    extras=""
  fi

  jq -n \
    --arg to "$to" \
    --arg text "$text" \
    --arg rid "$reply_to_id" \
    --argjson extras "${extras:-null}" \
    '{to: $to}
     + (if $text == "" then {} else {text: $text} end)
     + (if $rid == "" then {} else {replyTo: {id: $rid}} end)
     + (if $extras == null then {} else $extras end)' \
    >"$tmp"
  mv "$tmp" "$final"
  printf '%s' "$final"
}
