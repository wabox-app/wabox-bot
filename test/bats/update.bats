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

# ---- update_apply targets the tag, not branch HEAD -------------------------
# These build real local git repos (offline) and let update_apply run for real
# against a test clone by pointing _WABOX_BOT_UPDATE_ROOT at it.

_git() { git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }

# Upstream with two tags (v0.1.0, v0.2.0) and an extra *untagged* commit on main
# past the latest tag — so "branch HEAD" and "latest tag" are different commits.
_mk_upstream() {
  local up="$1"
  git init -q -b main "$up"
  printf '0.1.0\n' >"$up/VERSION"; _git "$up" add -A; _git "$up" commit -qm r1; _git "$up" tag v0.1.0
  printf '0.2.0\n' >"$up/VERSION"; _git "$up" add -A; _git "$up" commit -qm r2; _git "$up" tag v0.2.0
  printf 'x\n'     >"$up/UNRELEASED"; _git "$up" add -A; _git "$up" commit -qm past-tag
}

@test "update_apply installs the latest tag, not the untagged branch HEAD" {
  up="$TMPDIR_TEST/up"; clone="$TMPDIR_TEST/clone"
  _mk_upstream "$up"
  git clone -q "$up" "$clone"
  [ -f "$clone/UNRELEASED" ]                       # starts at branch HEAD

  _WABOX_BOT_UPDATE_ROOT="$clone"
  run update_apply "0.2.0"
  [ "$status" -eq 0 ]
  # Landed on the v0.2.0 tag commit: VERSION is 0.2.0 and the post-tag file is gone.
  [ "$(cat "$clone/VERSION")" = "0.2.0" ]
  [ ! -e "$clone/UNRELEASED" ]
  [ "$(_git "$clone" rev-parse HEAD)" = "$(_git "$up" rev-parse v0.2.0^{commit})" ]
}

@test "update_apply with no version arg resolves the latest tag itself" {
  up="$TMPDIR_TEST/up2"; clone="$TMPDIR_TEST/clone2"
  _mk_upstream "$up"
  git clone -q "$up" "$clone"
  _WABOX_BOT_UPDATE_ROOT="$clone"
  update_latest_published_version() { printf '0.2.0'; }   # stub the network read
  run update_apply
  [ "$status" -eq 0 ]
  [ "$(cat "$clone/VERSION")" = "0.2.0" ]
  [ ! -e "$clone/UNRELEASED" ]
}

@test "update_apply falls back to the branch when no tag is published" {
  up="$TMPDIR_TEST/up3"; clone="$TMPDIR_TEST/clone3"
  git init -q -b main "$up"
  printf '0.0.0\n' >"$up/VERSION"; _git "$up" add -A; _git "$up" commit -qm c1
  printf 'head\n'  >"$up/MARKER";  _git "$up" add -A; _git "$up" commit -qm c2
  git clone -q "$up" "$clone"
  _git "$clone" reset --hard -q HEAD~1              # move the clone behind main

  _WABOX_BOT_UPDATE_ROOT="$clone"
  update_latest_published_version() { return 1; }   # no tags upstream
  run update_apply ""
  [ "$status" -eq 0 ]
  [ -f "$clone/MARKER" ]                            # advanced to branch HEAD
}

@test "update_apply refuses a dirty checkout without FORCE" {
  up="$TMPDIR_TEST/up4"; clone="$TMPDIR_TEST/clone4"
  _mk_upstream "$up"
  git clone -q "$up" "$clone"
  printf 'local edit\n' >>"$clone/VERSION"          # dirty the tree
  _WABOX_BOT_UPDATE_ROOT="$clone"
  run update_apply "0.2.0"
  [ "$status" -ne 0 ]
  [[ "$output" == *"local changes"* ]]
  [ -f "$clone/UNRELEASED" ]                        # untouched — no reset happened
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
