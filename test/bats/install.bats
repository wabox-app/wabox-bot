load test_helper

# install.sh pins the checkout to the latest published tag (like `--update`).
# These run the real installer offline against a local upstream repo, with the
# prefix/bin dirs redirected into the tempdir.

setup() { setup_lib; }
teardown() { teardown_lib; }

_git() { git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }

# Upstream tagged v0.1.0 then v0.2.0, with an extra untagged commit on main past
# the latest tag — so "branch HEAD" and "latest tag" are different commits.
_mk_upstream() {
  local up="$1"
  git init -q -b main "$up"
  mkdir -p "$up/bin"; : >"$up/bin/wabox-bot"
  printf '0.1.0\n' >"$up/VERSION"; _git "$up" add -A; _git "$up" commit -qm r1; _git "$up" tag v0.1.0
  printf '0.2.0\n' >"$up/VERSION"; _git "$up" add -A; _git "$up" commit -qm r2; _git "$up" tag v0.2.0
  printf 'x\n'     >"$up/UNRELEASED"; _git "$up" add -A; _git "$up" commit -qm past-tag
}

_run_install() {
  run env WABOX_BOT_REPO="$1" \
          WABOX_BOT_PREFIX="$PREFIX" \
          WABOX_BOT_BIN_DIR="$BIN" \
          bash "$REPO_ROOT/install.sh"
}

@test "fresh install checks out the latest tag, not the untagged branch HEAD" {
  up="$TMPDIR_TEST/up"; _mk_upstream "$up"
  PREFIX="$TMPDIR_TEST/prefix"; BIN="$TMPDIR_TEST/bin"
  _run_install "$up"
  [ "$status" -eq 0 ]
  [ "$(cat "$PREFIX/VERSION")" = "0.2.0" ]
  [ ! -e "$PREFIX/UNRELEASED" ]
  [ -L "$BIN/wabox-bot" ]
}

@test "re-running the installer advances an existing checkout to a new tag" {
  up="$TMPDIR_TEST/up"
  git init -q -b main "$up"
  printf '0.1.0\n' >"$up/VERSION"; _git "$up" add -A; _git "$up" commit -qm r1; _git "$up" tag v0.1.0
  PREFIX="$TMPDIR_TEST/prefix"; BIN="$TMPDIR_TEST/bin"
  _run_install "$up"
  [ "$(cat "$PREFIX/VERSION")" = "0.1.0" ]
  # Cut a newer release upstream, then re-run.
  printf '0.2.0\n' >"$up/VERSION"; _git "$up" add -A; _git "$up" commit -qm r2; _git "$up" tag v0.2.0
  _run_install "$up"
  [ "$status" -eq 0 ]
  [ "$(cat "$PREFIX/VERSION")" = "0.2.0" ]
}

@test "install falls back to the branch tip when the upstream has no tags" {
  up="$TMPDIR_TEST/up"
  git init -q -b main "$up"
  printf '0.0.0\n' >"$up/VERSION"; _git "$up" add -A; _git "$up" commit -qm c1
  printf 'head\n'  >"$up/MARKER";  _git "$up" add -A; _git "$up" commit -qm c2
  PREFIX="$TMPDIR_TEST/prefix"; BIN="$TMPDIR_TEST/bin"
  _run_install "$up"
  [ "$status" -eq 0 ]
  [ -f "$PREFIX/MARKER" ]   # branch HEAD, since there's no tag to pin to
}
