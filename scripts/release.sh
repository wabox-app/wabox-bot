#!/usr/bin/env bash
# Cut a release, keeping VERSION, the CHANGELOG, and the git tag in lockstep.
#
# The manual 3-step in CONTRIBUTING.md is easy to half-do — the compare-link
# footer and the tag are the bits that get forgotten. This script does the whole
# cut atomically so it can't drift:
#
#   1. bump the VERSION file to X.Y.Z
#   2. promote CHANGELOG [Unreleased] → [X.Y.Z] - <today>, leaving a fresh empty
#      [Unreleased], and rewrite the compare-link footer
#   3. commit (chore(release): vX.Y.Z) and create the annotated tag vX.Y.Z
#
# It runs shellcheck + bats first (SKIP_CHECKS=1 to bypass) and refuses to cut
# an empty release. It never pushes — that stays an explicit step; the exact
# command is printed at the end.
#
# Usage: scripts/release.sh <X.Y.Z>
set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
cd "$ROOT"

die() { printf 'release: %s\n' "$1" >&2; exit 1; }

NEW="${1:-}"
[[ -n "$NEW" ]] || die "usage: scripts/release.sh <X.Y.Z>"
[[ "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must be X.Y.Z (got: $NEW)"

# A clean tree keeps the release commit to exactly VERSION + CHANGELOG — no
# unrelated work rides along, and a failed cut leaves nothing half-applied.
if ! git diff --quiet || ! git diff --cached --quiet; then
  die "working tree not clean — commit or stash your changes first"
fi

PREV="$(cat VERSION)"
[[ "$NEW" != "$PREV" ]] || die "VERSION is already $NEW"
if git rev-parse -q --verify "refs/tags/v$NEW" >/dev/null; then
  die "tag v$NEW already exists"
fi
! grep -q "^## \[$NEW\]" CHANGELOG.md || die "CHANGELOG already has a [$NEW] section"
grep -q '^## \[Unreleased\]' CHANGELOG.md || die "no [Unreleased] section in CHANGELOG.md"
grep -q '^\[Unreleased\]:' CHANGELOG.md || die "no [Unreleased] compare-link in the CHANGELOG footer"

# Refuse to cut an empty release: there must be at least one non-blank line
# between [Unreleased] and the next version header.
unreleased="$(awk '/^## \[Unreleased\]/{f=1;next} f&&/^## \[/{exit} f{print}' CHANGELOG.md \
  | grep -v '^[[:space:]]*$' || true)"
[[ -n "$unreleased" ]] || die "[Unreleased] is empty — nothing to release"

if [[ "${SKIP_CHECKS:-0}" != 1 ]]; then
  printf 'release: running shellcheck…\n' >&2
  shellcheck -x bin/wabox-bot
  shellcheck lib/backends/*.sh install.sh examples/aider.sh scripts/release.sh
  printf 'release: running bats…\n' >&2
  bats test/bats/
fi

DATE="$(date +%F)"

printf '%s\n' "$NEW" >VERSION

# One awk pass: insert the new version header just under [Unreleased] (so the
# entries move beneath it and [Unreleased] is left empty), and rewrite the two
# footer links — reusing the repo URL already in the [Unreleased] line, so no
# host is hard-coded here.
tmp="$(mktemp)"
awk -v NEW="$NEW" -v PREV="$PREV" -v DATE="$DATE" '
  /^## \[Unreleased\]/ && !hd { print; print ""; print "## [" NEW "] - " DATE; hd=1; next }
  /^\[Unreleased\]:/ {
    base = substr($0, 1, index($0, "/compare/") - 1)
    url  = substr(base, index(base, ": ") + 2)
    print "[Unreleased]: " url "/compare/v" NEW "...HEAD"
    print "[" NEW "]: " url "/compare/v" PREV "...v" NEW
    next
  }
  { print }
' CHANGELOG.md >"$tmp"
mv "$tmp" CHANGELOG.md

git add VERSION CHANGELOG.md
git commit -m "chore(release): v$NEW" >/dev/null
git tag -a "v$NEW" -m "wabox-bot v$NEW"

branch="$(git rev-parse --abbrev-ref HEAD)"
cat >&2 <<EOF

release: cut v$NEW at $(git rev-parse --short HEAD).
Push it with:
    git push origin $branch && git push origin v$NEW
EOF
