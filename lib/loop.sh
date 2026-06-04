# Catch-up + inotify FIFO main loop.
#
# inotifywait is routed through a FIFO so:
#   - inotifywait has a known PID we can signal from the shutdown trap, and
#   - the while-loop runs in *this* shell (so the CHILDREN map and traps
#     stay live).
# The 1s read timeout lets SIGTERM/SIGINT break us out within a second even
# when no events are arriving.

run_main_loop() {
  log_info "starting"
  log_info "  inbox     = $WABOX_INBOX"
  log_info "  outbox    = $WABOX_OUTBOX"
  log_info "  state     = $STATE_DIR"
  log_info "  processed = $PROCESSED_DIR$([[ $KEEP_PROCESSED == 1 ]] && echo "" || echo " (deleted after reply)")"
  log_info "  groupMode = $([[ $GROUP_PER_PARTICIPANT == 1 ]] && echo per-participant || echo per-chat)"

  if [[ ! -d "$WABOX_INBOX" ]]; then
    log_error "inbox directory does not exist: $WABOX_INBOX"
    log_error "run \`wabox config\` to set up wabox first"
    exit 1
  fi

  # Catch-up: process anything already sitting in the inbox at startup
  local existing
  for existing in "$WABOX_INBOX"/*.json; do
    [[ -f "$existing" ]] || continue
    safe_handle_envelope "$existing" &
    CHILDREN[$!]=1
  done

  local FIFO="$STATE_DIR/.inotify.fifo"
  rm -f -- "$FIFO"
  mkfifo "$FIFO"

  inotifywait -m -q \
    -e close_write -e moved_to \
    --format '%w%f' \
    "$WABOX_INBOX" >"$FIFO" &
  INOTIFY_PID=$!

  # Open FIFO for read on fd 3 (blocks until inotifywait opens the write end).
  exec 3<"$FIFO"

  local path
  while ((!SHUTTING_DOWN)); do
    if IFS= read -r -t 1 path <&3; then
      [[ "$path" == *.json ]] || continue
      [[ -f "$path" ]] || continue
      safe_handle_envelope "$path" &
      CHILDREN[$!]=1
      reap_children
    else
      # Either the 1s timeout fired or inotifywait died. If the latter,
      # abort so systemd/launchd can restart us.
      if ! kill -0 "$INOTIFY_PID" 2>/dev/null; then
        log_error "inotifywait died unexpectedly; exiting"
        break
      fi
      reap_children
    fi
  done

  exec 3<&-
  rm -f -- "$FIFO"
  shutdown
}
