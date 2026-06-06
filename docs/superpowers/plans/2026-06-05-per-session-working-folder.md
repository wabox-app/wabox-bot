# Per-Session Working Folder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every WhatsApp conversation its own working directory that the agent `cd`s into per turn — an auto per-slug folder by default, redirectable with a `/cwd <path>` command.

**Architecture:** A new core module `lib/workdir.sh` owns working-folder path resolution (keyed by the conversation `slug`). The `/cwd` command and `/status`/`/help` wiring live in `lib/commands.sh` (core). The `claude-code` backend `cd`s into the resolved path inside `backend_reply`. The override path persists in `$SESSIONS_DIR/<slug>/workdir`.

**Tech Stack:** Pure bash 4+, `jq`, `flock`; tests with `bats`; lint with `shellcheck -x`.

---

## File Structure

- **Create** `lib/workdir.sh` — path resolution: `conversation_dir`, `conversation_workdir`, `expand_tilde`, `workdir_display`. Depends only on `STATE_DIR`/`SESSIONS_DIR` from `config.sh`.
- **Modify** `bin/wabox-bot` — source `lib/workdir.sh` after `outbox`, before `backend`.
- **Modify** `test/bats/test_helper.bash` — `load_core` sources `lib/workdir.sh` (same order).
- **Modify** `lib/commands.sh` — add the `/cwd` case; add `/cwd` to `/help`; add a `workdir:` line to `/status`.
- **Modify** `lib/backends/claude-code.sh` — `cd` into `conversation_workdir` at the top of `backend_reply`.
- **Create** `test/bats/workdir.bats` — unit tests for the resolver helpers.
- **Modify** `test/bats/commands.bats` — `/cwd` show / set / default / reject cases.

`lib/workdir.sh` is covered by `shellcheck -x bin/wabox-bot` (the entrypoint sources it), so no CI change is needed.

---

## Task 1: `lib/workdir.sh` resolver module

**Files:**
- Create: `lib/workdir.sh`
- Create: `test/bats/workdir.bats`
- Modify: `bin/wabox-bot` (source line, after line 82)
- Modify: `test/bats/test_helper.bash` (`load_core`, after the `outbox.sh` source line)

- [ ] **Step 1: Write the failing test**

Create `test/bats/workdir.bats`:

```bash
load test_helper

setup() {
  setup_lib
  load_core
}

teardown() {
  teardown_lib
}

@test "conversation_dir is the per-conversation root under SESSIONS_DIR" {
  run conversation_dir abc123
  [ "$status" -eq 0 ]
  [ "$output" = "$STATE_DIR/sessions/abc123" ]
}

@test "conversation_workdir defaults to per-slug folder and creates it" {
  run conversation_workdir abc123
  [ "$status" -eq 0 ]
  [ "$output" = "$STATE_DIR/work/abc123" ]
  [ -d "$STATE_DIR/work/abc123" ]
}

@test "conversation_workdir honors an override file" {
  mkdir -p "$SESSIONS_DIR/abc123" "$TMPDIR_TEST/custom"
  printf '%s\n' "$TMPDIR_TEST/custom" >"$SESSIONS_DIR/abc123/workdir"
  run conversation_workdir abc123
  [ "$status" -eq 0 ]
  [ "$output" = "$TMPDIR_TEST/custom" ]
}

@test "expand_tilde expands a leading ~/ to HOME" {
  run expand_tilde "~/Valter"
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/Valter" ]
}

@test "expand_tilde expands a bare ~ to HOME" {
  run expand_tilde "~"
  [ "$output" = "$HOME" ]
}

@test "expand_tilde leaves an absolute path unchanged" {
  run expand_tilde "/srv/data"
  [ "$output" = "/srv/data" ]
}

@test "workdir_display labels the default and does not create the dir" {
  run workdir_display abc123
  [ "$output" = "$STATE_DIR/work/abc123 (default)" ]
  [ ! -d "$STATE_DIR/work/abc123" ]
}

@test "workdir_display labels an override" {
  mkdir -p "$SESSIONS_DIR/abc123"
  printf '%s\n' "/srv/data" >"$SESSIONS_DIR/abc123/workdir"
  run workdir_display abc123
  [ "$output" = "/srv/data (override)" ]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats test/bats/workdir.bats`
Expected: FAIL — `load_core` does not yet source `workdir.sh`, so `conversation_dir`/`conversation_workdir`/`expand_tilde`/`workdir_display` are undefined ("command not found").

- [ ] **Step 3: Create `lib/workdir.sh`**

```bash
# Per-conversation working folder resolution.
#
# Each conversation gets a working directory the active backend cd's into
# before running an agent turn, so the agent's file operations stay isolated
# per conversation. Unset conversations default to an auto per-slug folder
# under $STATE_DIR/work; the /cwd command (lib/commands.sh) can redirect a
# conversation to a chosen path, persisted verbatim (already absolute) in
# $SESSIONS_DIR/<slug>/workdir.

# The per-conversation root — a sibling of the per-backend state subdirs
# (<slug>/<backend>/). The /cwd override file lives directly under here.
conversation_dir() {
  printf '%s' "$SESSIONS_DIR/$1"
}

# Resolve the *effective* working directory for a conversation: the /cwd
# override if set, else the auto default. Creates the directory and prints
# its path. The default materializes here on a conversation's first agent
# turn rather than eagerly for every conversation.
conversation_workdir() {
  local slug="$1" override_file dir
  override_file="$(conversation_dir "$slug")/workdir"
  if [[ -s "$override_file" ]]; then
    dir="$(cat -- "$override_file")"
  else
    dir="$STATE_DIR/work/$slug"
  fi
  mkdir -p "$dir"
  printf '%s' "$dir"
}

# Expand a leading ~ / ~/ in a user-supplied path to $HOME. Bash does not
# expand ~ inside a variable, so /cwd does it explicitly. Any path without a
# leading tilde is returned unchanged.
expand_tilde() {
  local p="$1"
  case "$p" in
    '~') printf '%s' "$HOME" ;;
    '~/'*) printf '%s' "$HOME/${p#'~/'}" ;;
    *) printf '%s' "$p" ;;
  esac
}

# Human-readable "path (default|override)" for /status and /cwd show. Unlike
# conversation_workdir, this does NOT create the directory.
workdir_display() {
  local slug="$1" file
  file="$(conversation_dir "$slug")/workdir"
  if [[ -s "$file" ]]; then
    printf '%s (override)' "$(cat -- "$file")"
  else
    printf '%s (default)' "$STATE_DIR/work/$slug"
  fi
}
```

- [ ] **Step 4: Source `lib/workdir.sh` in `bin/wabox-bot`**

In `bin/wabox-bot`, the `outbox.sh` source block is at lines 81-82:

```bash
# shellcheck source=lib/outbox.sh
source "$LIB_DIR/outbox.sh"
```

Insert immediately after it (before the `backend.sh` block at line 83):

```bash
# shellcheck source=lib/workdir.sh
source "$LIB_DIR/workdir.sh"
```

- [ ] **Step 5: Source `lib/workdir.sh` in `load_core`**

In `test/bats/test_helper.bash`, `load_core` has:

```bash
  # shellcheck source=lib/outbox.sh
  source "$LIB_DIR/outbox.sh"
```

Insert immediately after it:

```bash
  # shellcheck source=lib/workdir.sh
  source "$LIB_DIR/workdir.sh"
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `bats test/bats/workdir.bats`
Expected: PASS (8 tests).

- [ ] **Step 7: Lint**

Run: `shellcheck -x bin/wabox-bot`
Expected: no output (exit 0).

- [ ] **Step 8: Commit**

```bash
git add lib/workdir.sh bin/wabox-bot test/bats/test_helper.bash test/bats/workdir.bats
git commit -m "feat: per-conversation working folder resolver"
```

---

## Task 2: `/cwd` command + `/help` and `/status` wiring

**Files:**
- Modify: `lib/commands.sh` (add `/cwd` case before the `*)` fallthrough; edit `/help` and `/status` cases)
- Modify: `test/bats/commands.bats` (new `/cwd` tests)

- [ ] **Step 1: Write the failing tests**

Append to `test/bats/commands.bats`:

```bash
@test "/cwd with no override reports the auto default folder" {
  handle_slash_command "/cwd" "$SLUG" "$JID" "$JID" "MSG" "cwd1"
  text="$(jq -r '.text' "$WABOX_OUTBOX/cwd1.json")"
  [[ "$text" == *"work/$SLUG (default)"* ]]
}

@test "/cwd <existing dir> persists the expanded absolute path" {
  mkdir -p "$TMPDIR_TEST/proj"
  handle_slash_command "/cwd $TMPDIR_TEST/proj" "$SLUG" "$JID" "$JID" "MSG" "cwd2"
  [ "$(cat "$(conversation_dir "$SLUG")/workdir")" = "$TMPDIR_TEST/proj" ]
  text="$(jq -r '.text' "$WABOX_OUTBOX/cwd2.json")"
  [[ "$text" == *"set to: $TMPDIR_TEST/proj"* ]]
}

@test "/cwd expands a leading tilde before persisting" {
  mkdir -p "$HOME/wabox-bot-test-dir"
  handle_slash_command "/cwd ~/wabox-bot-test-dir" "$SLUG" "$JID" "$JID" "MSG" "cwd3"
  [ "$(cat "$(conversation_dir "$SLUG")/workdir")" = "$HOME/wabox-bot-test-dir" ]
  rmdir "$HOME/wabox-bot-test-dir"
}

@test "/cwd default removes the override" {
  mkdir -p "$(conversation_dir "$SLUG")"
  printf '%s\n' "/srv/data" >"$(conversation_dir "$SLUG")/workdir"
  handle_slash_command "/cwd default" "$SLUG" "$JID" "$JID" "MSG" "cwd4"
  [ ! -e "$(conversation_dir "$SLUG")/workdir" ]
}

@test "/cwd rejects a relative path and persists nothing" {
  handle_slash_command "/cwd some/rel/path" "$SLUG" "$JID" "$JID" "MSG" "cwd5"
  text="$(jq -r '.text' "$WABOX_OUTBOX/cwd5.json")"
  [[ "$text" == *"absolute path or start with ~"* ]]
  [ ! -e "$(conversation_dir "$SLUG")/workdir" ]
}

@test "/cwd rejects a nonexistent directory" {
  handle_slash_command "/cwd $TMPDIR_TEST/nope" "$SLUG" "$JID" "$JID" "MSG" "cwd6"
  text="$(jq -r '.text' "$WABOX_OUTBOX/cwd6.json")"
  [[ "$text" == *"No such directory: $TMPDIR_TEST/nope"* ]]
  [ ! -e "$(conversation_dir "$SLUG")/workdir" ]
}

@test "/cwd rejects a path that is a file, not a directory" {
  : >"$TMPDIR_TEST/afile"
  handle_slash_command "/cwd $TMPDIR_TEST/afile" "$SLUG" "$JID" "$JID" "MSG" "cwd7"
  text="$(jq -r '.text' "$WABOX_OUTBOX/cwd7.json")"
  [[ "$text" == *"Not a directory: $TMPDIR_TEST/afile"* ]]
  [ ! -e "$(conversation_dir "$SLUG")/workdir" ]
}

@test "/help lists /cwd" {
  handle_slash_command "/help" "$SLUG" "$JID" "$JID" "MSG" "cwdhelp"
  [[ "$(jq -r '.text' "$WABOX_OUTBOX/cwdhelp.json")" == *"/cwd"* ]]
}

@test "/status reports the working folder" {
  handle_slash_command "/status" "$SLUG" "$JID" "$JID" "MSG" "cwdstatus"
  [[ "$(jq -r '.text' "$WABOX_OUTBOX/cwdstatus.json")" == *"workdir: "* ]]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats test/bats/commands.bats`
Expected: the new `/cwd*` tests FAIL (`/cwd` falls through to "Unknown command: /cwd."); `/status` and `/help` tests FAIL (no `workdir:` / `/cwd` text yet). Pre-existing tests still PASS.

- [ ] **Step 3: Add the `/cwd` case to `handle_slash_command`**

In `lib/commands.sh`, the `*)` fallthrough case begins at line 78 (`    *)`). Insert this new case immediately **before** that `*)` line:

```bash
    /cwd)
      if [[ -z "$cmd_args" ]]; then
        reply_path="$(write_outbox "$to" \
          "Working folder: $(workdir_display "$slug")
Usage:
  /cwd <path>     set this conversation's working folder (absolute or ~)
  /cwd default    revert to the auto per-conversation folder" \
          "$id" "$stem")"
        log_info "[$stem] /cwd (show) → $reply_path"
        return 0
      fi
      if [[ "$cmd_args" == "default" || "$cmd_args" == "clear" ]]; then
        (
          exec 8>"$LOCKS_DIR/$slug.lock"
          flock -x 8
          rm -f -- "$(conversation_dir "$slug")/workdir"
        )
        reply_path="$(write_outbox "$to" \
          "Working folder reset to the auto per-conversation folder." \
          "$id" "$stem")"
        log_info "[$stem] /cwd default → $reply_path"
        return 0
      fi
      local cwd_path
      cwd_path="$(expand_tilde "$cmd_args")"
      if [[ "$cwd_path" != /* ]]; then
        reply_path="$(write_outbox "$to" \
          "Working folder must be an absolute path or start with ~ (got: $cmd_args)." \
          "$id" "$stem")"
        log_warn "[$stem] /cwd rejected non-absolute path=$cmd_args → $reply_path"
        return 0
      fi
      if [[ ! -e "$cwd_path" ]]; then
        reply_path="$(write_outbox "$to" \
          "No such directory: $cwd_path" \
          "$id" "$stem")"
        log_warn "[$stem] /cwd rejected missing dir=$cwd_path → $reply_path"
        return 0
      fi
      if [[ ! -d "$cwd_path" ]]; then
        reply_path="$(write_outbox "$to" \
          "Not a directory: $cwd_path" \
          "$id" "$stem")"
        log_warn "[$stem] /cwd rejected non-dir=$cwd_path → $reply_path"
        return 0
      fi
      (
        exec 8>"$LOCKS_DIR/$slug.lock"
        flock -x 8
        mkdir -p "$(conversation_dir "$slug")"
        printf '%s\n' "$cwd_path" >"$(conversation_dir "$slug")/workdir"
      )
      reply_path="$(write_outbox "$to" \
        "Working folder for this conversation set to: $cwd_path" \
        "$id" "$stem")"
      log_info "[$stem] /cwd → $cwd_path → $reply_path"
      return 0
      ;;
```

- [ ] **Step 4: Add `/cwd` to the `/help` text**

In `lib/commands.sh`, the `/help` case builds `help_text` (lines 66-69):

```bash
      local help_text="Available commands:
/clear           forget this conversation and start fresh
/status          show session id, model, mode, system prompt
/ping            quick liveness check"
```

Replace that assignment with one that adds the `/cwd` line:

```bash
      local help_text="Available commands:
/clear           forget this conversation and start fresh
/status          show session id, model, mode, system prompt
/cwd <path>      set this conversation's working folder (/cwd default to reset)
/ping            quick liveness check"
```

- [ ] **Step 5: Add the `workdir:` line to `/status`**

In `lib/commands.sh`, the `/status` case sets `status_text` (lines 53-55):

```bash
      local status_text
      status_text="Status:
conv:    $conv_key
backend: $(backend_name)"
```

Replace that with:

```bash
      local status_text
      status_text="Status:
conv:    $conv_key
backend: $(backend_name)
workdir: $(workdir_display "$slug")"
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bats test/bats/commands.bats`
Expected: PASS (all pre-existing plus the 9 new tests).

- [ ] **Step 7: Lint**

Run: `shellcheck -x bin/wabox-bot`
Expected: no output (exit 0).

- [ ] **Step 8: Commit**

```bash
git add lib/commands.sh test/bats/commands.bats
git commit -m "feat: /cwd command to set a conversation's working folder"
```

---

## Task 3: `claude-code` backend `cd`s into the working folder

**Files:**
- Modify: `lib/backends/claude-code.sh` (`backend_reply`, after the `text="$(cat)"` line at line 95)

- [ ] **Step 1: Add the `cd` to `backend_reply`**

In `lib/backends/claude-code.sh`, `backend_reply` starts at line 92:

```bash
backend_reply() {
  local slug="$1" conv_key="$2" stem="$3"
  local text
  text="$(cat)"
```

Insert immediately after the `text="$(cat)"` line (before `local sid_existing sid`):

```bash

  # Run this turn in the conversation's working folder so the agent's file
  # operations stay isolated per conversation. We're already inside the
  # command-substitution subshell that captures backend_reply's output (see
  # lib/inbox.sh), so this cd is scoped to this one turn — no global CWD
  # change, no races between concurrent conversations.
  local workdir
  workdir="$(conversation_workdir "$slug")"
  if ! cd "$workdir"; then
    log_error "[$stem] cannot cd to working folder $workdir"
    return 1
  fi
```

- [ ] **Step 2: Lint**

Run: `shellcheck -x bin/wabox-bot`
Expected: no output (exit 0).

- [ ] **Step 3: Verify the backend contract tests still pass**

`conversation_workdir` is defined in `lib/workdir.sh`, which `load_core` sources before `backend.sh` — so the backend function is resolvable in the test shell.

Run: `bats test/bats/backend_contract.bats`
Expected: PASS (unchanged — the contract tests assert function definitions, not turn execution).

- [ ] **Step 4: Run the full suite**

Run: `bats test/bats/`
Expected: PASS (all files).

- [ ] **Step 5: Commit**

```bash
git add lib/backends/claude-code.sh
git commit -m "feat: claude-code runs each turn in the conversation's working folder"
```

---

## Task 4: Documentation

**Files:**
- Modify: `README.md` (Configuration / commands section)
- Modify: `docs/backends.md` (note `conversation_workdir` available to backends)
- Modify: `CHANGELOG.md` (`[Unreleased]`)

- [ ] **Step 1: Document `/cwd` and the working folder in `README.md`**

In `README.md`, find the paragraph listing slash commands (the bullet near the top:
"**Slash commands** (`/clear`, `/status`, `/ping`, `/help`, plus backend-owned ...)").
Update that bullet to mention `/cwd`:

```markdown
- **Slash commands** (`/clear`, `/status`, `/ping`, `/help`, `/cwd`, plus
  backend-owned ones like `/model`, `/mode`, `/system` for the Claude Code
  backend).
```

Then add a row to the Configuration table (the `| Env var | Default | Meaning |` table) describing the working-folder default:

```markdown
| `STATE_DIR/work/<slug>` | (auto) | Default working folder per conversation; override per-conversation with `/cwd <path>`. |
```

- [ ] **Step 2: Note the helper in `docs/backends.md`**

In `docs/backends.md`, add a short paragraph (under the section describing helpers backends may call, alongside `backend_state_dir`) stating:

```markdown
Backends that run an agent in a working directory should `cd` into
`conversation_workdir "$slug"` before invoking it. This returns (and creates)
the conversation's working folder — the auto default `$STATE_DIR/work/<slug>`,
or the path the user set with `/cwd`. Do this inside a subshell so the `cd`
does not leak across turns; `backend_reply` already runs inside one.
```

- [ ] **Step 3: Add a CHANGELOG entry**

In `CHANGELOG.md`, under the `[Unreleased]` section's `### Added` list (create the `### Added` subheading if absent), add:

```markdown
- Per-conversation working folder: each conversation runs its agent in its own
  directory (auto `$STATE_DIR/work/<slug>` by default). New `/cwd <path>`
  command redirects a conversation to a chosen folder (e.g. `~/Valter`);
  `/cwd default` reverts. Shown in `/status`.
```

- [ ] **Step 4: Commit**

```bash
git add README.md docs/backends.md CHANGELOG.md
git commit -m "docs: per-session working folder and /cwd command"
```

---

## Final Verification

- [ ] Run the full test suite: `bats test/bats/` — expected: all PASS.
- [ ] Lint the core: `shellcheck -x bin/wabox-bot` — expected: no output.
- [ ] Lint backends/installer (as CI does): `shellcheck lib/backends/*.sh install.sh examples/aider.sh` — expected: no output.
