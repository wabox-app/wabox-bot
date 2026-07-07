load test_helper

# Self-update logic (lib/update.sh) and the /update slash command. The functions
# that touch the network (update_latest_published_version) and rewrite the tree
# (update_apply) are stubbed here so the tests stay offline and non-destructive —
# what's exercised is the comparison logic and the command dispatch around them.

setup() {
  setup_lib
  WABOX_BOT_BACKEND=claude-code load_core
  JID="5511999999999@s.whatsapp.net"
  SLUG="$(printf '%s' "$JID" | sha1sum | awk '{print $1}')"
}

teardown() {
  teardown_lib
}

@test "version_gt: strictly-newer semver comparisons" {
  run version_gt 0.5.0 0.4.0; [ "$status" -eq 0 ]
  run version_gt 0.4.1 0.4.0; [ "$status" -eq 0 ]
  run version_gt 1.0.0 0.9.9; [ "$status" -eq 0 ]
  run version_gt 0.10.0 0.9.0; [ "$status" -eq 0 ]
}

@test "version_gt: equal or older is not newer" {
  run version_gt 0.4.0 0.4.0; [ "$status" -ne 0 ]
  run version_gt 0.4.0 0.5.0; [ "$status" -ne 0 ]
  run version_gt 0.9.0 0.10.0; [ "$status" -ne 0 ]
}

@test "update_check returns 10 and echoes the latest when a newer release exists" {
  wabox_bot_version() { printf '0.4.0'; }
  update_latest_published_version() { printf '0.5.0'; }
  run update_check
  [ "$status" -eq 10 ]
  [ "$output" = "0.5.0" ]
}

@test "update_check returns 0 when the installed version is the latest" {
  wabox_bot_version() { printf '0.5.0'; }
  update_latest_published_version() { printf '0.5.0'; }
  run update_check
  [ "$status" -eq 0 ]
}

@test "update_check returns 1 when the latest cannot be determined" {
  wabox_bot_version() { printf '0.4.0'; }
  update_latest_published_version() { return 1; }
  run update_check
  [ "$status" -eq 1 ]
}

@test "/update reports up to date" {
  update_check() { return 0; }
  wabox_bot_version() { printf '0.4.0'; }
  handle_slash_command "/update" "$SLUG" "$JID" "$JID" "MSG" "u1"
  [[ "$(jq -r '.text' "$WABOX_OUTBOX/u1.json")" == *"up to date"* ]]
}

@test "/update advertises a newer version and how to apply it" {
  update_check() { printf '0.9.0'; return 10; }
  wabox_bot_version() { printf '0.4.0'; }
  handle_slash_command "/update" "$SLUG" "$JID" "$JID" "MSG" "u2"
  text="$(jq -r '.text' "$WABOX_OUTBOX/u2.json")"
  [[ "$text" == *"v0.9.0"* ]]
  [[ "$text" == *"/update now"* ]]
}

@test "/update now applies and tells the user to restart" {
  update_check() { printf '0.9.0'; return 10; }
  update_apply() { return 0; }
  wabox_bot_version() { printf '0.9.0'; }
  handle_slash_command "/update now" "$SLUG" "$JID" "$JID" "MSG" "u3"
  text="$(jq -r '.text' "$WABOX_OUTBOX/u3.json")"
  [[ "$text" == *"Updated to v0.9.0"* ]]
  [[ "$text" == *"Restart"* ]]
}

@test "/update now surfaces a failure from update_apply" {
  update_check() { printf '0.9.0'; return 10; }
  update_apply() { printf 'not a git checkout: /x\n'; return 1; }
  wabox_bot_version() { printf '0.4.0'; }
  handle_slash_command "/update now" "$SLUG" "$JID" "$JID" "MSG" "u4"
  text="$(jq -r '.text' "$WABOX_OUTBOX/u4.json")"
  [[ "$text" == *"Update failed"* ]]
  [[ "$text" == *"not a git checkout"* ]]
}

@test "/update is refused when WABOX_BOT_ALLOW_REMOTE_UPDATE=0" {
  WABOX_BOT_ALLOW_REMOTE_UPDATE=0
  # update_apply must NOT run when disabled.
  update_apply() { printf 'SHOULD NOT RUN\n'; touch "$TMPDIR_TEST/applied"; }
  handle_slash_command "/update now" "$SLUG" "$JID" "$JID" "MSG" "u5"
  text="$(jq -r '.text' "$WABOX_OUTBOX/u5.json")"
  [[ "$text" == *"disabled"* ]]
  [ ! -e "$TMPDIR_TEST/applied" ]
}

@test "/help lists /update" {
  handle_slash_command "/help" "$SLUG" "$JID" "$JID" "MSG" "uhelp"
  [[ "$(jq -r '.text' "$WABOX_OUTBOX/uhelp.json")" == *"/update"* ]]
}

@test "/status shows a cached update-available notice" {
  printf '0.9.0\n' >"$STATE_DIR/update-available"
  handle_slash_command "/status" "$SLUG" "$JID" "$JID" "MSG" "ustatus"
  [[ "$(jq -r '.text' "$WABOX_OUTBOX/ustatus.json")" == *"v0.9.0 available"* ]]
}
