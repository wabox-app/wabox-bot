# Installed version resolution.
#
# The VERSION file at the repo root is the single source of truth, bumped at
# release time alongside the CHANGELOG entry and the matching git tag (see
# CONTRIBUTING.md → Releasing). This file only reads it — the git short commit
# for dev builds is composed by the entrypoint's --version handler, keeping
# this (and the value exposed via `state --json`) a clean semver string.
#
# Sourced before lib/log.sh (the entrypoint prints --version with no other
# setup), so it must not use log_* at source time.

# Resolve the repo root from THIS file's location (lib/version.sh → ..), not
# from the entrypoint's $ROOT, so the function works wherever it's sourced.
_WABOX_BOT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Echo the installed version string (contents of the VERSION file, trimmed of a
# trailing newline by `read`). Falls back to "unknown" if the file is missing.
wabox_bot_version() {
  local v=""
  [[ -r "$_WABOX_BOT_ROOT/VERSION" ]] && read -r v <"$_WABOX_BOT_ROOT/VERSION"
  printf '%s' "${v:-unknown}"
}
