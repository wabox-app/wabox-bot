# Configuration File Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Load all wabox-bot environment variables from one sourced config file (`~/.config/wabox-bot/config`), shipped as a commented `config.example`, with `--config`/`--init-config`/`--print-config` flags.

**Architecture:** `lib/config.sh` sources the config file at the top under `set -a` (auto-export, so subprocesses inherit) before resolving defaults; the template's `${VAR:-default}` form makes the environment win. The entrypoint resolves the config path (flag > env > XDG default) and adds two early-exit modes (`--init-config`, `--print-config`). A `print_config` function dumps effective values with secrets masked.

**Tech Stack:** Pure bash 4+; bats; `shellcheck -x`.

---

## File Structure

- **Modify** `lib/config.sh` — load the config file at the top; add `print_config`.
- **Create** `config.example` (repo root) — the template `--init-config` installs.
- **Modify** `bin/wabox-bot` — `--config`/`--init-config`/`--print-config` parsing + early modes; updated `usage()`.
- **Modify** `.github/workflows/ci.yml` — shellcheck `config.example`.
- **Create** `test/bats/config.bats` — loading/precedence/export + template + flags.
- **Modify** `README.md`, `docs/backends.md`, `CONTRIBUTING.md`, `CHANGELOG.md` — docs.

Order: Task 1 (loading) → Task 2 (template + CI) → Task 3 (`--config`/`--init-config`) → Task 4 (`--print-config`) → Task 5 (docs). Task 3 depends on Task 2 (it installs `config.example`).

---

## Task 1: Config file loading in `lib/config.sh`

**Files:**
- Modify: `lib/config.sh` (insert loader at the top)
- Create: `test/bats/config.bats`

- [ ] **Step 1: Write the failing tests** — create `test/bats/config.bats`:

```bash
load test_helper

setup() { setup_lib; }
teardown() { teardown_lib; }

@test "config file values are applied when WABOX_BOT_CONFIG points at it" {
  cat >"$TMPDIR_TEST/cfg" <<'EOF'
KEEP_PROCESSED="${KEEP_PROCESSED:-0}"
CLAUDE_TIMEOUT="${CLAUDE_TIMEOUT:-42}"
EOF
  export WABOX_BOT_CONFIG="$TMPDIR_TEST/cfg"
  load_core
  [ "$KEEP_PROCESSED" = "0" ]
  [ "$CLAUDE_TIMEOUT" = "42" ]
}

@test "environment overrides the config file (template :- form)" {
  cat >"$TMPDIR_TEST/cfg" <<'EOF'
KEEP_PROCESSED="${KEEP_PROCESSED:-0}"
EOF
  export WABOX_BOT_CONFIG="$TMPDIR_TEST/cfg"
  export KEEP_PROCESSED=9
  load_core
  [ "$KEEP_PROCESSED" = "9" ]
}

@test "config file values are exported to child processes" {
  cat >"$TMPDIR_TEST/cfg" <<'EOF'
WABOX_FW_MODEL="${WABOX_FW_MODEL:-small}"
EOF
  export WABOX_BOT_CONFIG="$TMPDIR_TEST/cfg"
  load_core
  run bash -c 'printf %s "${WABOX_FW_MODEL:-MISSING}"'
  [ "$output" = "small" ]
}

@test "a missing config path is silently ignored (defaults apply)" {
  export WABOX_BOT_CONFIG="$TMPDIR_TEST/nope"
  load_core
  [ "$KEEP_PROCESSED" = "1" ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats test/bats/config.bats`
Expected: the first three FAIL — `config.sh` doesn't yet source the file, so `KEEP_PROCESSED`/`CLAUDE_TIMEOUT`/`WABOX_FW_MODEL` aren't set from it. (The "missing path" test may already pass.)

- [ ] **Step 3: Add the loader to `lib/config.sh`**

In `lib/config.sh`, the file currently begins with a comment block, then (line 10) `default_paths_from_wabox() {`. Insert this block immediately AFTER the header comment and BEFORE `default_paths_from_wabox` (so loaded values are present before any resolution):

```bash
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats test/bats/config.bats`
Expected: PASS (4 tests).

- [ ] **Step 5: Lint and run the full suite**

Run: `shellcheck -x bin/wabox-bot` → no output.
Run: `bats test/bats/` → all PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/config.sh test/bats/config.bats
git commit -m "feat: load config from a sourced config file"
```

---

## Task 2: `config.example` template + CI lint

**Files:**
- Create: `config.example`
- Modify: `.github/workflows/ci.yml`
- Modify: `test/bats/config.bats` (append a template test)

- [ ] **Step 1: Append the failing test** — add to `test/bats/config.bats`:

```bash
@test "config.example sources cleanly and yields the documented defaults" {
  ( set -euo pipefail
    # shellcheck disable=SC1091
    source "$REPO_ROOT/config.example"
    [ "$WABOX_BOT_BACKEND" = "claude-code" ]
    [ "$CLAUDE_TIMEOUT" = "180" ]
    [ "$WABOX_TRANSCRIBE_TIMEOUT" = "120" ]
    [ "$KEEP_PROCESSED" = "1" ]
  )
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats test/bats/config.bats`
Expected: the new test FAILS (`config.example` does not exist yet).

- [ ] **Step 3: Create `config.example`**

```bash
# shellcheck shell=bash disable=SC2034
# wabox-bot configuration.
#
# Copy to ~/.config/wabox-bot/config (or run: wabox-bot --init-config), then
# edit. This file is sourced as bash at startup and every value is exported, so
# the claude CLI and the plugins/*/transcribe.sh scripts inherit them.
#
# Precedence: a variable already set in your environment wins over this file
# (the lines use the ${VAR:-default} form). Write a bare VAR=value if you want
# this file to force a value regardless of the environment.

# ── Core ─────────────────────────────────────────────────────────────────────
WABOX_BOT_BACKEND="${WABOX_BOT_BACKEND:-claude-code}"     # backend in lib/backends/
# Inbox/outbox default from `wabox status --json`; uncomment to pin them:
# WABOX_INBOX="${WABOX_INBOX:-$HOME/.local/share/wabox/inbox}"
# WABOX_OUTBOX="${WABOX_OUTBOX:-$HOME/.local/share/wabox/outbox}"
# STATE_DIR="${STATE_DIR:-$HOME/.local/state/wabox-bot}"  # sessions + locks
# PROCESSED_DIR="${PROCESSED_DIR:-$WABOX_INBOX/processed}"
# LOG_FILE="${LOG_FILE:-$STATE_DIR/agent.log}"
KEEP_PROCESSED="${KEEP_PROCESSED:-1}"                     # keep envelopes for audit
IGNORE_FROM_ME="${IGNORE_FROM_ME:-1}"                    # skip fromMe=true
GROUP_PER_PARTICIPANT="${GROUP_PER_PARTICIPANT:-0}"      # 1 = thread per person
SHUTDOWN_DRAIN_TIMEOUT="${SHUTDOWN_DRAIN_TIMEOUT:-180}"  # seconds to drain on stop
DEBUG="${DEBUG:-0}"                                      # 1 = verbose logging

# ── Backend: claude-code ──────────────────────────────────────────────────────
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
CLAUDE_ARGS="${CLAUDE_ARGS:---permission-mode auto}"
CLAUDE_TIMEOUT="${CLAUDE_TIMEOUT:-180}"                  # seconds per turn
# SYSTEM_PROMPT_FILE="${SYSTEM_PROMPT_FILE:-}"           # global system prompt file

# ── Transcription (core) ──────────────────────────────────────────────────────
# Point WABOX_TRANSCRIBE_CMD at a plugin to transcribe inbound audio; empty =
# audio is ignored. See plugins/README.md.
# WABOX_TRANSCRIBE_CMD="${WABOX_TRANSCRIBE_CMD:-$HOME/.local/share/wabox-bot/plugins/faster-whisper/transcribe.sh}"
WABOX_TRANSCRIBE_TIMEOUT="${WABOX_TRANSCRIBE_TIMEOUT:-120}"
WABOX_TRANSCRIBE_LANG="${WABOX_TRANSCRIBE_LANG:-}"       # e.g. pt; empty = auto-detect

# ── Transcription plugins (set only the ones for your chosen plugin) ──────────
# faster-whisper:
# WABOX_FW_MODEL="${WABOX_FW_MODEL:-base}"
# WABOX_FW_DEVICE="${WABOX_FW_DEVICE:-cpu}"
# WABOX_FW_COMPUTE="${WABOX_FW_COMPUTE:-int8}"
# whisper-cpp:
# WABOX_WHISPERCPP_MODEL="${WABOX_WHISPERCPP_MODEL:-$HOME/.local/share/whisper/ggml-base.bin}"
# WABOX_WHISPERCPP_BIN="${WABOX_WHISPERCPP_BIN:-whisper-cli}"
# openai-whisper:
# WABOX_OPENAI_WHISPER_MODEL="${WABOX_OPENAI_WHISPER_MODEL:-base}"
# vosk:
# WABOX_VOSK_MODEL="${WABOX_VOSK_MODEL:-$HOME/.local/share/vosk/model}"
# openai-compatible (OpenAI, Groq, …):
# WABOX_STT_API_KEY="${WABOX_STT_API_KEY:-}"
# WABOX_STT_API_URL="${WABOX_STT_API_URL:-https://api.openai.com/v1/audio/transcriptions}"
# WABOX_STT_API_MODEL="${WABOX_STT_API_MODEL:-whisper-1}"
```

- [ ] **Step 4: Add `config.example` to the CI shellcheck set**

In `.github/workflows/ci.yml`, the shellcheck step ends with:

```yaml
          shellcheck examples/aider.sh
          shellcheck plugins/*/transcribe.sh
```

Add one line after it:

```yaml
          shellcheck examples/aider.sh
          shellcheck plugins/*/transcribe.sh
          shellcheck config.example
```

- [ ] **Step 5: Verify the test passes and lint**

Run: `bats test/bats/config.bats` → PASS.
Run: `shellcheck config.example` → no output (the `# shellcheck shell=bash disable=SC2034` directive suppresses the no-shebang and unused-variable warnings).

- [ ] **Step 6: Commit**

```bash
git add config.example .github/workflows/ci.yml test/bats/config.bats
git commit -m "feat: ship config.example template; lint it in CI"
```

---

## Task 3: `--config` and `--init-config` flags

**Files:**
- Modify: `bin/wabox-bot` (`usage()` + arg parsing + early modes)
- Modify: `test/bats/config.bats` (append flag tests)

- [ ] **Step 1: Append the failing tests** — add to `test/bats/config.bats`:

```bash
@test "--init-config writes config.example to the target and refuses to overwrite" {
  target="$TMPDIR_TEST/conf/config"
  WABOX_BOT_CONFIG="$target" run "$REPO_ROOT/bin/wabox-bot" --init-config
  [ "$status" -eq 0 ]
  [ -f "$target" ]
  diff "$target" "$REPO_ROOT/config.example"
  # second run must refuse, leaving the file untouched
  WABOX_BOT_CONFIG="$target" run "$REPO_ROOT/bin/wabox-bot" --init-config
  [ "$status" -ne 0 ]
}

@test "--config naming a missing file is an error" {
  run "$REPO_ROOT/bin/wabox-bot" --config "$TMPDIR_TEST/absent"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats test/bats/config.bats`
Expected: the two new tests FAIL (`--init-config` / `--config` are unknown args today, so the entrypoint prints "unknown argument" — `--init-config`'s first run won't create the file; `--config` won't say "not found").

- [ ] **Step 3: Replace `usage()` in `bin/wabox-bot`**

Replace the existing `usage()` (lines 19-29) with:

```bash
usage() {
  cat <<EOF
Usage: $(basename "$0") [--backend <name>] [--config <path>]
       $(basename "$0") --init-config | --print-config

Options:
  --backend <name>    use this backend (overrides WABOX_BOT_BACKEND;
                      default: claude-code). Available backends are .sh
                      files in lib/backends/.
  --config <path>     load this config file (overrides WABOX_BOT_CONFIG;
                      default: \${XDG_CONFIG_HOME:-~/.config}/wabox-bot/config).
  --init-config       write the config template to that path and exit.
  --print-config      print effective config values (secrets masked) and exit.
  -h, --help          show this message and exit
EOF
}
```

- [ ] **Step 4: Replace the arg-parsing block in `bin/wabox-bot`**

Replace the block from `BACKEND_OVERRIDE=""` (line 33) through the closing `fi` of `if [[ -n "$BACKEND_OVERRIDE" ]]; then ... fi` (line 58) with:

```bash
# Argument parsing. Flags win over env vars; both win over built-in defaults.
BACKEND_OVERRIDE=""
CONFIG_OVERRIDE=""
MODE="run"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --backend)
      [[ $# -ge 2 ]] || { printf 'wabox-bot: --backend requires a value\n' >&2; exit 1; }
      BACKEND_OVERRIDE="$2"
      shift 2
      ;;
    --backend=*)
      BACKEND_OVERRIDE="${1#--backend=}"
      shift
      ;;
    --config)
      [[ $# -ge 2 ]] || { printf 'wabox-bot: --config requires a value\n' >&2; exit 1; }
      CONFIG_OVERRIDE="$2"
      shift 2
      ;;
    --config=*)
      CONFIG_OVERRIDE="${1#--config=}"
      shift
      ;;
    --init-config)
      MODE="init-config"
      shift
      ;;
    --print-config)
      MODE="print-config"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      printf 'wabox-bot: unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

# Resolve the config path (flag > env > XDG default) so every mode agrees.
if [[ -n "$CONFIG_OVERRIDE" ]]; then
  WABOX_BOT_CONFIG="$CONFIG_OVERRIDE"
fi
WABOX_BOT_CONFIG="${WABOX_BOT_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/wabox-bot/config}"
export WABOX_BOT_CONFIG

# --init-config: install the template and exit (needs no libs or dependencies).
if [[ "$MODE" == "init-config" ]]; then
  if [[ -e "$WABOX_BOT_CONFIG" ]]; then
    printf 'wabox-bot: config already exists: %s\n' "$WABOX_BOT_CONFIG" >&2
    printf 'Remove it, or pass --config <path> to write elsewhere.\n' >&2
    exit 1
  fi
  mkdir -p "$(dirname "$WABOX_BOT_CONFIG")"
  cp -- "$ROOT/config.example" "$WABOX_BOT_CONFIG"
  printf 'wrote %s\n' "$WABOX_BOT_CONFIG"
  exit 0
fi

# A config named explicitly with --config must exist (the default path is
# optional and silently ignored when absent).
if [[ -n "$CONFIG_OVERRIDE" && ! -f "$WABOX_BOT_CONFIG" ]]; then
  printf 'wabox-bot: config file not found: %s\n' "$WABOX_BOT_CONFIG" >&2
  exit 1
fi

if [[ -n "$BACKEND_OVERRIDE" ]]; then
  WABOX_BOT_BACKEND="$BACKEND_OVERRIDE"
fi
```

- [ ] **Step 5: Run the tests and lint**

Run: `bats test/bats/config.bats` → PASS (the `--print-config` test comes in Task 4).
Run: `shellcheck -x bin/wabox-bot` → no output.

- [ ] **Step 6: Commit**

```bash
git add bin/wabox-bot test/bats/config.bats
git commit -m "feat: --config and --init-config flags"
```

---

## Task 4: `--print-config`

**Files:**
- Modify: `lib/config.sh` (add `print_config`)
- Modify: `bin/wabox-bot` (handle the `print-config` mode after sourcing config + backend)
- Modify: `test/bats/config.bats` (append a test)

- [ ] **Step 1: Append the failing test** — add to `test/bats/config.bats`:

```bash
@test "--print-config prints effective values and masks secrets" {
  export WABOX_BOT_BACKEND=echo
  export WABOX_STT_API_KEY=supersecret
  run env WABOX_BOT_CONFIG="$TMPDIR_TEST/none" \
    "$REPO_ROOT/bin/wabox-bot" --print-config
  [ "$status" -eq 0 ]
  [[ "$output" == *"WABOX_BOT_BACKEND=echo"* ]]
  [[ "$output" == *"WABOX_STT_API_KEY=(set)"* ]]
  [[ "$output" != *"supersecret"* ]]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats test/bats/config.bats`
Expected: FAIL — `--print-config` mode isn't handled yet / `print_config` undefined.

- [ ] **Step 3: Add `print_config` to `lib/config.sh`**

Append to the END of `lib/config.sh`:

```bash
# Print effective configuration for diagnostics (--print-config). Lists the
# resolved core variables plus every WABOX_*/CLAUDE_* var and SYSTEM_PROMPT_FILE
# currently set (covers backend and plugin vars). Secret-looking values are
# masked so the output is safe to share.
_print_config_one() {
  local name="$1" val="${!1-}"
  case "$name" in
    *KEY* | *TOKEN* | *SECRET*)
      if [[ -n "$val" ]]; then val="(set)"; else val="(unset)"; fi
      ;;
    *)
      [[ -n "$val" ]] || val="(unset)"
      ;;
  esac
  printf '%s=%s\n' "$name" "$val"
}

print_config() {
  local name
  for name in WABOX_BOT_CONFIG WABOX_BOT_BACKEND WABOX_INBOX WABOX_OUTBOX \
              STATE_DIR PROCESSED_DIR LOG_FILE KEEP_PROCESSED IGNORE_FROM_ME \
              GROUP_PER_PARTICIPANT SHUTDOWN_DRAIN_TIMEOUT \
              "${!WABOX_@}" "${!CLAUDE_@}" SYSTEM_PROMPT_FILE; do
    _print_config_one "$name"
  done | sort -u
}
```

- [ ] **Step 4: Handle the `print-config` mode in `bin/wabox-bot`**

In `bin/wabox-bot`, the libs are sourced in order: `config.sh`, then `log.sh`, then `check_dependencies`. Find:

```bash
# shellcheck source=lib/log.sh
source "$LIB_DIR/log.sh"
check_dependencies
```

Insert the print-config handling BETWEEN the `log.sh` source and `check_dependencies`:

```bash
# shellcheck source=lib/log.sh
source "$LIB_DIR/log.sh"

# --print-config: source the backend (for its defaults) and dump effective
# values, then exit — before the dependency check, lock, and main loop, so it
# works without the runtime binaries installed.
if [[ "$MODE" == "print-config" ]]; then
  # shellcheck source=lib/backend.sh
  source "$LIB_DIR/backend.sh"
  print_config
  exit 0
fi

check_dependencies
```

- [ ] **Step 5: Run the test and lint**

Run: `bats test/bats/config.bats` → PASS (all).
Run: `shellcheck -x bin/wabox-bot` → no output.
Run: `bats test/bats/` → all PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/config.sh bin/wabox-bot test/bats/config.bats
git commit -m "feat: --print-config dumps effective values, masking secrets"
```

---

## Task 5: Documentation

**Files:**
- Modify: `README.md`
- Modify: `docs/backends.md`
- Modify: `CONTRIBUTING.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add a Configuration file section to `README.md`**

In `README.md`, immediately BEFORE the existing `## Configuration` heading (the line `## Configuration`), insert:

```markdown
## Configuration file

All settings are environment variables; rather than exporting them by hand, put
them in one file:

```bash
wabox-bot --init-config            # writes ~/.config/wabox-bot/config
$EDITOR ~/.config/wabox-bot/config # edit values; lines you don't need stay as defaults
wabox-bot                          # loads the file on startup
```

The file is sourced as bash and every value is exported, so the backend CLI and
the transcription plugins inherit it. A variable set in your environment still
wins over the file. Use `--config <path>` for an alternate file (or set
`WABOX_BOT_CONFIG`), and `--print-config` to see the effective values (secrets
masked). The variables themselves are listed below.

```

(Note: the triple-backtick fences above are part of the inserted Markdown.)

- [ ] **Step 2: Note the config file in `docs/backends.md`**

In `docs/backends.md`, in the "Variables" section that lists backend-tunable env
vars (e.g. `CLAUDE_BIN`, `CLAUDE_ARGS`), add this sentence:

```markdown
These backend variables can also be set in the wabox-bot config file
(`~/.config/wabox-bot/config`); it is sourced and exported before the backend
loads, so values there reach the backend and any subprocess it spawns.
```

- [ ] **Step 3: Mention the config file in `CONTRIBUTING.md`**

In `CONTRIBUTING.md`, the Project layout code block lists top-level entries. Add
a line for the template (right after the `bin/wabox-bot` line):

```
config.example          # template for ~/.config/wabox-bot/config (--init-config)
```

- [ ] **Step 4: Add a CHANGELOG entry**

In `CHANGELOG.md`, under `[Unreleased]` → `### Added`, add:

```markdown
- Configuration file: all environment variables can live in one sourced file
  (`~/.config/wabox-bot/config`, override with `--config`/`WABOX_BOT_CONFIG`),
  exported to subprocesses. New flags `--init-config` (install the bundled
  `config.example` template) and `--print-config` (show effective values, with
  secrets masked). The environment still overrides file values.
```

- [ ] **Step 5: Verify and commit**

Run: `bats test/bats/` → all PASS.
Run: `shellcheck -x bin/wabox-bot && shellcheck config.example` → no output.

```bash
git add README.md docs/backends.md CONTRIBUTING.md CHANGELOG.md
git commit -m "docs: configuration file and --config/--init-config/--print-config"
```

---

## Final Verification

- [ ] Full suite: `bats test/bats/` — expected: all PASS.
- [ ] CI lint set: `shellcheck -x bin/wabox-bot && shellcheck lib/backends/*.sh && shellcheck install.sh && shellcheck examples/aider.sh && shellcheck plugins/*/transcribe.sh && shellcheck config.example` — expected: no output.
- [ ] Manual smoke: `WABOX_BOT_CONFIG=/tmp/c bin/wabox-bot --init-config && bin/wabox-bot --config /tmp/c --print-config` prints values and exits 0.
