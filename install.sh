#!/usr/bin/env bash
# wabox-bot installer.
#
# Clones the repo into ~/.local/share/wabox-bot and symlinks bin/wabox-bot
# into ~/.local/bin/. Pins the checkout to the latest published vX.Y.Z tag —
# the same deliberately-cut release `wabox-bot --update` converges to — so a
# fresh install and an in-place update never disagree. Falls back to
# WABOX_BOT_BRANCH when no tag is published yet. Safe to re-run.
#
# Uninstall:
#   rm -rf ~/.local/share/wabox-bot ~/.local/bin/wabox-bot

set -euo pipefail

INSTALL_PREFIX="${WABOX_BOT_PREFIX:-$HOME/.local/share/wabox-bot}"
BIN_DIR="${WABOX_BOT_BIN_DIR:-$HOME/.local/bin}"
REPO_URL="${WABOX_BOT_REPO:-https://github.com/wabox-app/wabox-bot.git}"
BRANCH="${WABOX_BOT_BRANCH:-main}"

# Highest vX.Y.Z tag on the remote (bare semver), or empty. Mirrors
# update_latest_published_version in lib/update.sh, but standalone — the
# curl|bash one-liner runs this before lib/ exists to be sourced.
latest_tag_version() {
  git ls-remote --tags --refs "$REPO_URL" 'v*' 2>/dev/null \
    | sed -n 's#.*refs/tags/v##p' \
    | sort -V \
    | tail -n1
}

mkdir -p "$BIN_DIR"

# Resolve the ref to install: the latest tag, else the branch tip.
LATEST="$(latest_tag_version || true)"
if [[ -n "$LATEST" ]]; then
  REF="refs/tags/v$LATEST"
  DESC="v$LATEST"
else
  REF="$BRANCH"
  DESC="$BRANCH (no tagged release yet)"
fi

if [[ ! -d "$INSTALL_PREFIX/.git" ]]; then
  echo "wabox-bot: cloning into $INSTALL_PREFIX"
  git clone --depth=1 --branch "$BRANCH" "$REPO_URL" "$INSTALL_PREFIX"
fi

# Fetch just the target ref and reset to it (FETCH_HEAD covers a tag or a
# branch without a local ref having to exist), leaving the checkout on $BRANCH
# pointed at that commit — exactly what `wabox-bot --update` does.
echo "wabox-bot: checking out $DESC"
git -C "$INSTALL_PREFIX" fetch --depth=1 origin "$REF"
git -C "$INSTALL_PREFIX" reset --hard FETCH_HEAD

ln -sf "$INSTALL_PREFIX/bin/wabox-bot" "$BIN_DIR/wabox-bot"

case ":$PATH:" in
  *:"$BIN_DIR":*) ;;
  *)
    echo "wabox-bot: NOTE — $BIN_DIR is not on \$PATH;" >&2
    echo "          add 'export PATH=\"$BIN_DIR:\$PATH\"' to your shell rc to run wabox-bot directly." >&2
    ;;
esac

echo "wabox-bot: installed → $BIN_DIR/wabox-bot"
echo "wabox-bot: run 'wabox-bot --help' to verify"
