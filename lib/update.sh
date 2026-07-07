# Self-update: detect a newer published release and apply it.
#
# "Published" = the highest vX.Y.Z tag on the upstream repo, read with
# `git ls-remote` — no curl/wget, no local fetch, no GitHub API. The daemon is
# installed as a shallow git clone (see install.sh), and applying an update is a
# `fetch` + `reset --hard` onto that tag — never a mid-flight branch HEAD, so an
# update only ever lands on a deliberately-cut release (which, with releases cut
# after CI is green, is the CI-vetted commit). Detection and application key off
# the same tag. Falls back to WABOX_BOT_BRANCH only when no tag is published yet.
#
# Sourced by the entrypoint right after lib/version.sh — before config/log — so
# the --update / --check-update flags work with no other setup. Two consequences:
#   - Repo/branch/timeout knobs are resolved INSIDE the functions (not at source
#     time), so a value set in the config file — sourced later, for the daemon
#     and slash-command paths — still wins. On the bare CLI paths only the
#     environment is read, exactly like install.sh.
#   - Functions on the CLI path (update_cli_*) must not use log_* (log.sh isn't
#     sourced yet); they print to stdout/stderr. The daemon/slash paths run after
#     log.sh and may log.

# Repo root from THIS file (lib/update.sh → ..), independent of the entrypoint's
# $ROOT, so it resolves wherever the file is sourced. Matches lib/version.sh.
_WABOX_BOT_UPDATE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Echo the latest published version (bare semver, no leading "v"), or nothing.
# Best-effort: needs git + network, and is bounded by `timeout` (a hard dep) so
# a stalled reach can't hang startup. Silent on any failure — the caller decides.
update_latest_published_version() {
  command -v git >/dev/null 2>&1 || return 1
  local repo="${WABOX_BOT_REPO:-https://github.com/wabox-app/wabox-bot.git}"
  local net_timeout="${WABOX_BOT_UPDATE_NET_TIMEOUT:-8}"
  local latest
  # --refs drops the peeled "^{}" duplicates; the 'v*' pattern matches the ref
  # tail (refs/tags/v0.4.0), and `sort -V` orders the semver tags correctly.
  latest="$(timeout "$net_timeout" \
      git ls-remote --tags --refs "$repo" 'v*' 2>/dev/null \
    | sed -n 's#.*refs/tags/v##p' \
    | sort -V \
    | tail -n1)" || return 1
  [[ -n "$latest" ]] || return 1
  printf '%s' "$latest"
}

# Is $1 a strictly newer semver than $2? Equal ⇒ not newer (return 1).
version_gt() {
  [[ "$1" != "$2" ]] || return 1
  local top
  top="$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)"
  [[ "$top" == "$1" ]]
}

# Compare the installed version against the latest published one. Echoes the
# latest version (empty if it couldn't be read). Return code is the contract:
#   0   up to date
#   10  a newer version is available (echoed on stdout)
#   1   undetermined (offline, git missing, or local version "unknown")
update_check() {
  local local_v latest
  local_v="$(wabox_bot_version)"
  latest="$(update_latest_published_version)" || return 1
  printf '%s' "$latest"
  [[ "$local_v" != "unknown" ]] || return 1
  version_gt "$latest" "$local_v" && return 10
  return 0
}

# Apply the update: fetch the latest published *tag* and hard-reset the install
# to it, so an update always lands on a deliberately-cut release rather than a
# mid-flight branch HEAD. When no tag is published (a fresh upstream, or a fork
# tracking a branch) it falls back to WABOX_BOT_BRANCH — the installer's
# fetch + reset behaviour. The target version may be passed in ($1); callers on
# the /update path have usually just resolved it via update_check, so passing it
# avoids a second ls-remote. Omitted, it's resolved here.
#
# Guards: must be a git checkout, and refuses when the tree has uncommitted
# changes (a dev checkout) unless WABOX_BOT_UPDATE_FORCE=1. Serialized by a
# private flock so a CLI --update and a WhatsApp /update can't reset at once.
# Human-readable messages go to stdout (captured into the /update reply); git's
# own progress goes to stderr (the daemon log / the CLI terminal). Return 0 on
# success, non-zero otherwise.
update_apply() {
  local latest="${1:-}"
  local root="$_WABOX_BOT_UPDATE_ROOT"
  local branch="${WABOX_BOT_BRANCH:-main}"
  local net_timeout="${WABOX_BOT_UPDATE_NET_TIMEOUT:-8}"

  command -v git >/dev/null 2>&1 || { printf 'git is not installed.\n'; return 1; }
  if [[ ! -d "$root/.git" ]]; then
    printf 'not a git checkout: %s\n' "$root"
    printf 'Reinstall with install.sh instead.\n'
    return 1
  fi
  if [[ "${WABOX_BOT_UPDATE_FORCE:-0}" != 1 && -n "$(git -C "$root" status --porcelain 2>/dev/null)" ]]; then
    printf 'refusing to update: %s has local changes.\n' "$root"
    printf 'Commit or stash them, or set WABOX_BOT_UPDATE_FORCE=1 to discard them.\n'
    return 1
  fi

  # Resolve the ref to install: the latest published tag, else the branch.
  [[ -n "$latest" ]] || latest="$(update_latest_published_version || true)"
  local fetch_ref
  if [[ -n "$latest" ]]; then
    fetch_ref="refs/tags/v$latest"
  else
    fetch_ref="$branch"
  fi

  local rc=0
  (
    # fd 7 is free (single-instance holds 9, per-conversation holds 8). The lock
    # lives in .git so it never needs STATE_DIR (absent on the bare CLI path) and
    # is never mistaken for a tracked file.
    exec 7>"$root/.git/.wabox-update.lock"
    flock -x 7
    # Fetch just the target ref (tag or branch) and reset to what came back;
    # FETCH_HEAD covers both without a local tag ref having to exist.
    timeout "$net_timeout" git -C "$root" fetch --depth=1 origin "$fetch_ref" >&2 \
      && git -C "$root" reset --hard FETCH_HEAD >&2
  ) || rc=$?
  if ((rc != 0)); then
    printf 'git update failed (rc=%d). See stderr / the log for details.\n' "$rc"
  fi
  return "$rc"
}

# `wabox-bot --check-update`: report status and exit. No side effects.
# Exit: 0 up to date · 10 newer available · 1 undetermined.
update_cli_check() {
  local latest rc=0 local_v
  latest="$(update_check)" || rc=$?
  local_v="$(wabox_bot_version)"
  case "$rc" in
    0)  printf 'wabox-bot %s is up to date.\n' "$local_v" ;;
    10) printf 'wabox-bot %s is installed; %s is available.\n' "$local_v" "$latest"
        printf "Run 'wabox-bot --update' to upgrade.\n" ;;
    *)  printf 'wabox-bot: could not determine the latest version (offline, or git unavailable).\n' >&2 ;;
  esac
  return "$rc"
}

# `wabox-bot --update`: check, confirm on a TTY, then apply. Skips the prompt
# when stdin isn't a terminal or WABOX_BOT_ASSUME_YES=1. Exit 0 on success/no-op.
update_cli_apply() {
  local latest rc=0 local_v
  latest="$(update_check)" || rc=$?
  local_v="$(wabox_bot_version)"
  local branch="${WABOX_BOT_BRANCH:-main}"
  case "$rc" in
    0)  printf 'wabox-bot %s is already up to date.\n' "$local_v"
        [[ "${WABOX_BOT_UPDATE_FORCE:-0}" == 1 ]] || return 0 ;;
    10) printf 'wabox-bot %s is installed; updating to %s.\n' "$local_v" "$latest" ;;
    *)  printf 'wabox-bot: could not reach the upstream repo; attempting to update anyway.\n' >&2 ;;
  esac

  if [[ -t 0 && "${WABOX_BOT_ASSUME_YES:-0}" != 1 ]]; then
    local ans
    read -r -p "Proceed (git reset --hard origin/$branch)? [y/N] " ans
    case "$ans" in
      y | Y | yes | YES) ;;
      *) printf 'Aborted.\n'; return 0 ;;
    esac
  fi

  local out apply_rc=0
  out="$(update_apply "$latest")" || apply_rc=$?
  [[ -n "$out" ]] && printf '%s\n' "$out"
  if ((apply_rc == 0)); then
    printf 'wabox-bot: updated to %s. Restart the daemon for it to take effect.\n' \
      "$(wabox_bot_version)"
    return 0
  fi
  return "$apply_rc"
}

# Best-effort startup check for the daemon: log a one-line notice and cache the
# result for /status. Backgrounded so a slow network never delays startup, and
# bounded by the ls-remote timeout. Disable with WABOX_BOT_UPDATE_CHECK=0.
update_startup_notice() {
  [[ "${WABOX_BOT_UPDATE_CHECK:-1}" == 1 ]] || return 0
  (
    local latest rc=0
    latest="$(update_check)" || rc=$?
    if ((rc == 10)); then
      log_warn "a newer version is available: $latest (installed $(wabox_bot_version)) — run 'wabox-bot --update' or send /update"
      printf '%s\n' "$latest" >"$STATE_DIR/update-available"
    elif ((rc == 0)); then
      rm -f -- "$STATE_DIR/update-available"
    fi
  ) &
}
