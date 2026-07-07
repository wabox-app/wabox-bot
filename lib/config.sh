# Path defaults, environment variable resolution, dependency checks.
#
# Sourced before lib/log.sh, so this file cannot use the log_* helpers
# directly. need() references log_error, but that's only invoked from
# check_dependencies(), which the entrypoint calls *after* lib/log.sh has
# been sourced.

# Load the user's config file first, so its values seed the resolution below
# and are exported to subprocesses (the agent CLI, the transcription plugins).
# Path precedence: --config flag (sets WABOX_BOT_CONFIG in the entrypoint) >
# WABOX_BOT_CONFIG env > XDG default. The template uses the ${VAR:-default}
# form, so a variable already set in the environment wins over the file.
WABOX_BOT_CONFIG="${WABOX_BOT_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/wabox-bot/config}"
if [[ -f "$WABOX_BOT_CONFIG" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$WABOX_BOT_CONFIG"
  set +a
fi

# Try to pick up the user's actual wabox paths from `wabox status --json`
# (falls back to platform defaults if wabox isn't on PATH).
default_paths_from_wabox() {
  if command -v wabox >/dev/null 2>&1; then
    local out
    if out="$(wabox status --json 2>/dev/null)"; then
      WABOX_INBOX_DEFAULT="$(jq -r '.inbox // empty' <<<"$out" 2>/dev/null || true)"
      WABOX_OUTBOX_DEFAULT="$(jq -r '.outbox // empty' <<<"$out" 2>/dev/null || true)"
    fi
  fi
  : "${WABOX_INBOX_DEFAULT:=${XDG_DATA_HOME:-$HOME/.local/share}/wabox/inbox}"
  : "${WABOX_OUTBOX_DEFAULT:=${XDG_DATA_HOME:-$HOME/.local/share}/wabox/outbox}"
}
default_paths_from_wabox

WABOX_INBOX="${WABOX_INBOX:-$WABOX_INBOX_DEFAULT}"
WABOX_OUTBOX="${WABOX_OUTBOX:-$WABOX_OUTBOX_DEFAULT}"
STATE_DIR="${STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/wabox-bot}"

# Auto-migrate the default state directory from the in-tree
# wabox-claude-code.sh era. We only touch the path if it's the *default*
# AND the new location doesn't exist yet; users who set STATE_DIR
# explicitly are responsible for their own move. Runs before mkdir so the
# new STATE_DIR is freshly populated by the move, not created empty.
_old_default_state="${XDG_STATE_HOME:-$HOME/.local/state}/wabox-claude"
if [[ "$STATE_DIR" == "${XDG_STATE_HOME:-$HOME/.local/state}/wabox-bot" \
      && -d "$_old_default_state" && ! -e "$STATE_DIR" ]]; then
  mv "$_old_default_state" "$STATE_DIR"
fi
unset _old_default_state

SESSIONS_DIR="$STATE_DIR/sessions"
LOCKS_DIR="$STATE_DIR/locks"
# Default to a `processed/` sibling inside the inbox so the audit trail lives
# right next to the inbound files. inotifywait is non-recursive, so dropping
# files into this subdir won't retrigger the watcher.
PROCESSED_DIR="${PROCESSED_DIR:-$WABOX_INBOX/processed}"
LOG_FILE="${LOG_FILE:-$STATE_DIR/agent.log}"
PID_LOCK="$STATE_DIR/wabox-bot.lock"

GROUP_PER_PARTICIPANT="${GROUP_PER_PARTICIPANT:-0}"
IGNORE_FROM_ME="${IGNORE_FROM_ME:-1}"
KEEP_PROCESSED="${KEEP_PROCESSED:-1}"
# Pluggable speech-to-text for inbound audio. WABOX_TRANSCRIBE_CMD is
# word-split and the audio file path is appended as its final argument; the
# transcript is read from stdout. Empty ⇒ audio messages are ignored.
WABOX_TRANSCRIBE_CMD="${WABOX_TRANSCRIBE_CMD:-}"
WABOX_TRANSCRIBE_TIMEOUT="${WABOX_TRANSCRIBE_TIMEOUT:-120}"
# Generic shutdown drain timeout — how long to give in-flight handlers to
# finish on SIGTERM/SIGINT before escalating. Should be at least as long as
# the longest backend reply timeout.
SHUTDOWN_DRAIN_TIMEOUT="${SHUTDOWN_DRAIN_TIMEOUT:-180}"

# ---- Rich replies (see docs/superpowers/specs/2026-07-06-rich-replies) ------
# Ack reaction on agent-turn start. An emoji reacted to the inbound message the
# moment we hand off to the backend (so it means "an agent turn is running", not
# just "received"). Empty ⇒ disabled, the default, keeping outbox traffic
# byte-identical to prior releases.
WABOX_ACK_REACT="${WABOX_ACK_REACT:-}"
# Outgoing files: the folder (relative to each conversation's `.wabox/` plumbing
# dir) an agent drops files into for them to be attached to its reply, and how
# long archived `.sent/` copies are kept before opportunistic pruning.
WABOX_SEND_DIR="${WABOX_SEND_DIR:-send}"
WABOX_SEND_KEEP_DAYS="${WABOX_SEND_KEEP_DAYS:-7}"
# Quote-reply policy: auto|always|never. `auto` quotes in groups or when a newer
# envelope for the same conversation is still queued (so a reply can't land
# unthreaded after a later question). Junk falls back to auto.
WABOX_QUOTE_REPLY="${WABOX_QUOTE_REPLY:-auto}"
case "$WABOX_QUOTE_REPLY" in
  auto | always | never) ;;
  *) WABOX_QUOTE_REPLY="auto" ;;
esac

# ---- Memory & skills (see docs/superpowers/specs/2026-07-06-memory-and-skills) --
# A new *default* workdir (never a /cwd redirect) is seeded with this
# instructions file teaching the agent WhatsApp etiquette (markup, chat-sized
# replies), the send folder, and a memory practice. The claude-code backend
# writes it as CLAUDE.md; agy/bob as AGENTS.md — same content, backend-picks-the-
# name. Empty ⇒ seeding disabled. ROOT is set by the entrypoint; the fallback
# derives the repo root from this file's location so the default resolves under
# the test harness (which sources config.sh without ROOT) too.
# Note the ${VAR-default} form (no colon): an *explicitly empty* value disables
# seeding, so only a genuinely unset var falls back to the shipped template.
WABOX_WORKDIR_TEMPLATE="${WABOX_WORKDIR_TEMPLATE-${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/templates/workdir-instructions.md}"
# Consumed by the claude-code seed hook: a folder of shared agent skills
# symlinked into every new workdir as .claude/skills (a symlink, not a copy —
# update the one folder, every conversation follows). Curate it like code you
# run: every conversation gets those skills. Empty ⇒ no symlink.
CC_SHARED_SKILLS_DIR="${CC_SHARED_SKILLS_DIR:-}"

# ---- Workdir lifecycle (see docs/superpowers/specs/2026-07-06-workdir-lifecycle) --
# Inbound media is staged under each conversation's `.wabox/<WABOX_MEDIA_DIR>/`.
WABOX_MEDIA_DIR="${WABOX_MEDIA_DIR:-media}"
# `wabox-bot gc` prunes by mtime. Each `*_KEEP_DAYS` is a day count; `0` keeps
# that category forever. Staged inbound media and (audit) processed envelopes
# default to generous windows; the send archive reuses WABOX_SEND_KEEP_DAYS.
WABOX_MEDIA_KEEP_DAYS="${WABOX_MEDIA_KEEP_DAYS:-30}"
# processed/ is the audit trail. 90 days is the first non-keep-forever default
# in the project's history — set to 0 to restore the old keep-everything behavior.
WABOX_PROCESSED_KEEP_DAYS="${WABOX_PROCESSED_KEEP_DAYS:-90}"

mkdir -p "$STATE_DIR" "$SESSIONS_DIR" "$LOCKS_DIR" "$PROCESSED_DIR" \
  "$(dirname "$LOG_FILE")" "$WABOX_OUTBOX"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    log_error "missing required command: $1"
    exit 1
  }
}

check_dependencies() {
  need inotifywait
  need jq
  need flock
  need timeout
}

# Print effective configuration for diagnostics (--print-config). Lists the
# resolved core variables plus every WABOX_*/CLAUDE_* var and SYSTEM_PROMPT_FILE
# currently set (covers backend and plugin vars), minus internal/injected ones.
# Secret-looking values are masked, and a var set to empty is distinguished from
# one that is unset.
_print_config_one() {
  local name="$1" val
  if [[ -z "${!name+x}" ]]; then
    printf '%s=(unset)\n' "$name"
    return
  fi
  val="${!name}"
  case "$name" in
    *KEY* | *TOKEN* | *SECRET*)
      [[ -n "$val" ]] && val="(set)" || val="(empty)"
      ;;
    *)
      [[ -n "$val" ]] || val="(empty)"
      ;;
  esac
  printf '%s=%s\n' "$name" "$val"
}

print_config() {
  local name
  {
    for name in WABOX_BOT_CONFIG WABOX_BOT_BACKEND WABOX_INBOX WABOX_OUTBOX \
                STATE_DIR PROCESSED_DIR LOG_FILE KEEP_PROCESSED IGNORE_FROM_ME \
                GROUP_PER_PARTICIPANT SHUTDOWN_DRAIN_TIMEOUT DEBUG \
                "${!WABOX_@}" "${!CLAUDE_@}" SYSTEM_PROMPT_FILE; do
      # Skip internal computed vars and env injected by the claude CLI itself.
      case "$name" in
        *_DEFAULT | WABOX_BOT_BACKEND_DIR | CLAUDE_CODE_*) continue ;;
      esac
      _print_config_one "$name"
    done
  } | sort -u
}
