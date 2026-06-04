#!/usr/bin/env bash
# wabox-bot installer.
#
# Clones the repo into ~/.local/share/wabox-bot and symlinks bin/wabox-bot
# into ~/.local/bin/. Safe to re-run: pulls latest main when the clone
# already exists.
#
# Uninstall:
#   rm -rf ~/.local/share/wabox-bot ~/.local/bin/wabox-bot

set -euo pipefail

INSTALL_PREFIX="${WABOX_BOT_PREFIX:-$HOME/.local/share/wabox-bot}"
BIN_DIR="${WABOX_BOT_BIN_DIR:-$HOME/.local/bin}"
REPO_URL="${WABOX_BOT_REPO:-https://github.com/rodgco/wabox-bot.git}"
BRANCH="${WABOX_BOT_BRANCH:-main}"

mkdir -p "$BIN_DIR"

if [[ -d "$INSTALL_PREFIX/.git" ]]; then
  echo "wabox-bot: updating $INSTALL_PREFIX"
  git -C "$INSTALL_PREFIX" fetch --depth=1 origin "$BRANCH"
  git -C "$INSTALL_PREFIX" reset --hard "origin/$BRANCH"
else
  echo "wabox-bot: cloning into $INSTALL_PREFIX"
  git clone --depth=1 --branch "$BRANCH" "$REPO_URL" "$INSTALL_PREFIX"
fi

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
