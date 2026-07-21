# shellcheck shell=bash
# Per-conversation message batching (debounce).
#
# WhatsApp delivers a burst — an image with a caption, or several photos plus a
# line of text — as separate inbox envelopes arriving milliseconds apart. Each
# one lands as its own file and its own `handle_envelope` worker (loop.sh spawns
# one per file). Without coalescing, each becomes an independent agent turn: the
# agent sees fragments, and a piece can be misread as the answer to a parked
# yes/no while its real content is discarded.
#
# The fix is a two-phase handler (see lib/inbox.sh):
#   1. Ingest (per envelope, parallel, lock-free): prepare the turn-part — read,
#      fire the read receipt, stage media / transcribe audio — then `batch_append`
#      it to the conversation's pending queue.
#   2. Drain (per conversation, serialized by the fd-8 flock): `batch_settle`
#      waits out a quiet window, then `batch_collect` merges every queued part
#      into ONE turn.
#
# Because appends are lock-free but the drain holds the flock, the worker that
# wins the lock drains the parts appended by all the others; the losers then
# acquire the lock, find the queue empty, and return quietly. A part that arrives
# after a drain's snapshot simply stays for the next drain (correctly a new turn).
#
# The queue lives at $SESSIONS_DIR/<slug>/inbox_batch/. One JSON file per part,
# named with a nanosecond prefix so a lexical sort is arrival order.

batch_dir() {
  local d="$SESSIONS_DIR/$1/inbox_batch"
  mkdir -p "$d"
  printf '%s' "$d"
}

# Count *.json parts in a dir without relying on nullglob (tests source these
# libs without it; the daemon sets it globally).
batch_count() {
  local d="$1" f n=0
  for f in "$d"/*.json; do
    [[ -e "$f" ]] && ((n++))
  done
  printf '%d' "$n"
}

# batch_append <slug> <text> <media_rel> <media_type> <media_mime> <id> <participant> <to> <stem>
# Write one prepared turn-part to the queue, atomically (temp + rename), so a
# concurrent drain never reads a half-written part. Media is null when the part
# carries none (text-only, or audio already folded into the text upstream).
batch_append() {
  local slug="$1" text="$2" media_rel="$3" media_type="$4" media_mime="$5" \
        id="$6" participant="$7" to="$8" stem="$9"
  local dir part sfx tmp final
  dir="$(batch_dir "$slug")"
  part="$(jq -nc \
    --arg text "$text" --arg mp "$media_rel" --arg mt "$media_type" \
    --arg mm "$media_mime" --arg id "$id" --arg participant "$participant" \
    --arg to "$to" --arg stem "$stem" \
    '{text: $text, id: $id, participant: $participant, to: $to, stem: $stem,
      media: (if $mp == "" then null else {path: $mp, type: $mt, mime: $mm} end)}')" ||
    return 1
  # Nanosecond + pid + RANDOM keeps parallel same-instant appends distinct; the
  # ns prefix (fixed width today) sorts chronologically.
  sfx="$(date +%s%N).$BASHPID.$RANDOM"
  tmp="$dir/.$sfx.tmp"
  final="$dir/$sfx.json"
  if printf '%s\n' "$part" >"$tmp" 2>/dev/null; then
    mv -f -- "$tmp" "$final" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  else
    rm -f -- "$tmp"
    return 1
  fi
}

# batch_settle <slug> — MUST be called under the per-conversation flock. Returns
# 0 when a settled, non-empty batch is ready to collect; 1 when the queue is
# empty (another worker already drained it — the caller returns quietly, without
# sleeping). While we wait, ingest workers may append more parts (lock-free); a
# growing count means the burst is still arriving, so we keep waiting until it
# stops. Only appends (never deletes) can race us here, so the count is monotone
# within one settle and comparing counts is enough.
batch_settle() {
  local slug="$1" dir before now
  dir="$(batch_dir "$slug")"
  before="$(batch_count "$dir")"
  ((before > 0)) || return 1
  while :; do
    sleep "$WABOX_BATCH_WINDOW"
    now="$(batch_count "$dir")"
    ((now > before)) || break
    before="$now"
  done
  return 0
}

# batch_collect <slug> — MUST be called under the flock, after batch_settle.
# Snapshot the queued parts, delete them, and emit ONE merged turn as JSON:
#   {text, media:[{path,type,mime}...], id, participant, to, stem, count}
# text  — parts' texts joined by blank lines (empties skipped)
# media — every part's media object, in arrival order
# id/participant/to/stem — from the LAST (newest) part, so the reply quotes and
#         reacts to the most recent message and the outbox stem stays unique
# Returns 1 (emitting nothing) if the queue is empty. Parts appended after this
# snapshot are left in place for the next drain.
batch_collect() {
  local slug="$1" dir f merged
  dir="$(batch_dir "$slug")"
  local -a parts=()
  for f in "$dir"/*.json; do
    [[ -e "$f" ]] && parts+=("$f")
  done
  ((${#parts[@]})) || return 1
  # Sort by filename (nanosecond prefix) = arrival order.
  mapfile -t parts < <(printf '%s\n' "${parts[@]}" | sort)
  merged="$(jq -s '
    { text:        ([.[].text | select(. != "")] | join("\n\n")),
      media:       [.[].media | select(. != null)],
      id:          (.[-1].id),
      participant: (.[-1].participant),
      to:          (.[-1].to),
      stem:        (.[-1].stem),
      count:       length }' "${parts[@]}")" || return 1
  rm -f -- "${parts[@]}"
  printf '%s' "$merged"
}
