# Shared writer for a conversation's last_message.json.
#
# Records a lightweight {at, direction, text_preview} so `wabox-bot state` can
# list and sort conversations by activity without scanning processed/. Three
# writers now race for the same file — the inbound handler (lib/inbox.sh) and
# the two outbound verbs (send, prompt) — so the write is atomic (temp +
# rename); a plain `>` could interleave into a corrupt file. The temp name
# carries $BASHPID (unique per subshell, unlike $$ which stays the daemon's PID
# inside a backgrounded handler) plus $RANDOM so two concurrent writers for the
# same slug can't clobber each other's temp mid-write.
#
# direction is "in" (inbound) or "out" (a send/prompt delivery). The preview is
# truncated to 120 chars here; media placeholders like "[audio]" are composed
# by the caller and passed through as ordinary text.
lastmsg_write() {
  local slug="$1" direction="$2" preview="$3"
  local dir="$SESSIONS_DIR/$slug"
  mkdir -p "$dir"

  local tmp="$dir/.last_message.tmp.$BASHPID.$RANDOM"
  if jq -n \
    --argjson at "$(date +%s)" \
    --arg dir "$direction" \
    --arg text "${preview:0:120}" \
    '{at: $at, direction: $dir, text_preview: $text}' >"$tmp" 2>/dev/null; then
    mv -f -- "$tmp" "$dir/last_message.json" 2>/dev/null || rm -f -- "$tmp"
  fi
}
