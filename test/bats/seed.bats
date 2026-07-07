load test_helper

# Workdir seeding: the conversation_workdir hook dispatch (core) and the
# per-backend backend_seed_workdir implementations.

teardown() {
  teardown_lib
}

# ---- Task 1: hook dispatch in conversation_workdir (core) ------------------

@test "conversation_workdir calls backend_seed_workdir for a default dir" {
  setup_lib
  WABOX_BOT_BACKEND=claude-code load_core
  # Shadow the real hook with a spy that records its arguments.
  backend_seed_workdir() { printf '%s\n%s\n' "$1" "$2" >"$TMPDIR_TEST/seeded"; }
  run conversation_workdir abc123
  [ "$status" -eq 0 ]
  [ "$output" = "$STATE_DIR/work/abc123" ]
  [ -f "$TMPDIR_TEST/seeded" ]
  [ "$(sed -n 1p "$TMPDIR_TEST/seeded")" = "abc123" ]
  [ "$(sed -n 2p "$TMPDIR_TEST/seeded")" = "$STATE_DIR/work/abc123" ]
}

@test "conversation_workdir does NOT seed a /cwd-overridden dir" {
  setup_lib
  WABOX_BOT_BACKEND=claude-code load_core
  mkdir -p "$SESSIONS_DIR/abc123" "$TMPDIR_TEST/custom"
  printf '%s\n' "$TMPDIR_TEST/custom" >"$SESSIONS_DIR/abc123/workdir"
  backend_seed_workdir() { : >"$TMPDIR_TEST/seeded"; }
  run conversation_workdir abc123
  [ "$status" -eq 0 ]
  [ "$output" = "$TMPDIR_TEST/custom" ]
  [ ! -e "$TMPDIR_TEST/seeded" ]
}

@test "conversation_workdir is a no-op when no seed hook is defined" {
  setup_lib
  WABOX_BOT_BACKEND=claude-code load_core
  unset -f backend_seed_workdir
  run conversation_workdir abc123
  [ "$status" -eq 0 ]
  [ "$output" = "$STATE_DIR/work/abc123" ]
  [ -d "$STATE_DIR/work/abc123" ]
}

@test "a failing seed hook warns but does not break resolution" {
  setup_lib
  WABOX_BOT_BACKEND=claude-code load_core
  backend_seed_workdir() { return 1; }
  run conversation_workdir abc123
  [ "$status" -eq 0 ]
  # `run` merges the log_warn stderr line into $output, so the path is a
  # trailing substring rather than the whole output.
  [[ "$output" == *"$STATE_DIR/work/abc123" ]]
  grep -q "backend_seed_workdir failed" "$LOG_FILE"
}

# ---- Task 3: claude-code seed hook -----------------------------------------

@test "claude-code seeds CLAUDE.md and the skills symlink into a fresh workdir" {
  setup_lib
  printf 'be terse\n' >"$TMPDIR_TEST/tmpl.md"
  mkdir -p "$TMPDIR_TEST/shared-skills"
  export WABOX_WORKDIR_TEMPLATE="$TMPDIR_TEST/tmpl.md"
  export CC_SHARED_SKILLS_DIR="$TMPDIR_TEST/shared-skills"
  WABOX_BOT_BACKEND=claude-code load_core
  wd="$STATE_DIR/work/abc123"
  mkdir -p "$wd"
  backend_seed_workdir abc123 "$wd"
  [ "$(cat "$wd/CLAUDE.md")" = "be terse" ]
  [ -L "$wd/.claude/skills" ]
  [ "$(readlink "$wd/.claude/skills")" = "$TMPDIR_TEST/shared-skills" ]
}

@test "claude-code seed leaves an existing CLAUDE.md untouched" {
  setup_lib
  printf 'shipped template\n' >"$TMPDIR_TEST/tmpl.md"
  export WABOX_WORKDIR_TEMPLATE="$TMPDIR_TEST/tmpl.md"
  WABOX_BOT_BACKEND=claude-code load_core
  wd="$STATE_DIR/work/abc123"
  mkdir -p "$wd"
  printf 'user edited\n' >"$wd/CLAUDE.md"
  backend_seed_workdir abc123 "$wd"
  [ "$(cat "$wd/CLAUDE.md")" = "user edited" ]
}

@test "claude-code seed writes nothing when the template var is empty" {
  setup_lib
  export WABOX_WORKDIR_TEMPLATE=""
  WABOX_BOT_BACKEND=claude-code load_core
  wd="$STATE_DIR/work/abc123"
  mkdir -p "$wd"
  backend_seed_workdir abc123 "$wd"
  [ ! -e "$wd/CLAUDE.md" ]
}

@test "claude-code seed leaves a local skills dir in place (no symlink)" {
  setup_lib
  printf 'x\n' >"$TMPDIR_TEST/tmpl.md"
  mkdir -p "$TMPDIR_TEST/shared-skills"
  export WABOX_WORKDIR_TEMPLATE="$TMPDIR_TEST/tmpl.md"
  export CC_SHARED_SKILLS_DIR="$TMPDIR_TEST/shared-skills"
  WABOX_BOT_BACKEND=claude-code load_core
  wd="$STATE_DIR/work/abc123"
  mkdir -p "$wd/.claude/skills"
  backend_seed_workdir abc123 "$wd"
  [ ! -L "$wd/.claude/skills" ]
  [ -d "$wd/.claude/skills" ]
}

@test "claude-code seed leaves a broken existing skills symlink alone" {
  setup_lib
  printf 'x\n' >"$TMPDIR_TEST/tmpl.md"
  mkdir -p "$TMPDIR_TEST/shared-skills"
  export WABOX_WORKDIR_TEMPLATE="$TMPDIR_TEST/tmpl.md"
  export CC_SHARED_SKILLS_DIR="$TMPDIR_TEST/shared-skills"
  WABOX_BOT_BACKEND=claude-code load_core
  wd="$STATE_DIR/work/abc123"
  mkdir -p "$wd/.claude"
  ln -s "$TMPDIR_TEST/does-not-exist" "$wd/.claude/skills"
  backend_seed_workdir abc123 "$wd"
  [ -L "$wd/.claude/skills" ]
  [ "$(readlink "$wd/.claude/skills")" = "$TMPDIR_TEST/does-not-exist" ]
}

@test "claude-code seed is skipped by conversation_workdir on an override dir" {
  setup_lib
  printf 'x\n' >"$TMPDIR_TEST/tmpl.md"
  export WABOX_WORKDIR_TEMPLATE="$TMPDIR_TEST/tmpl.md"
  WABOX_BOT_BACKEND=claude-code load_core
  mkdir -p "$SESSIONS_DIR/abc123" "$TMPDIR_TEST/custom"
  printf '%s\n' "$TMPDIR_TEST/custom" >"$SESSIONS_DIR/abc123/workdir"
  conversation_workdir abc123
  [ ! -e "$TMPDIR_TEST/custom/CLAUDE.md" ]
}

# ---- Task 4: agy + bob seed hooks (AGENTS.md, no skills) -------------------

@test "agy seeds AGENTS.md and never a skills symlink" {
  setup_lib
  printf 'agents template\n' >"$TMPDIR_TEST/tmpl.md"
  mkdir -p "$TMPDIR_TEST/shared-skills"
  export WABOX_WORKDIR_TEMPLATE="$TMPDIR_TEST/tmpl.md"
  export CC_SHARED_SKILLS_DIR="$TMPDIR_TEST/shared-skills"
  WABOX_BOT_BACKEND=agy load_core
  wd="$STATE_DIR/work/abc123"
  mkdir -p "$wd"
  backend_seed_workdir abc123 "$wd"
  [ "$(cat "$wd/AGENTS.md")" = "agents template" ]
  [ ! -e "$wd/.claude/skills" ]
}

@test "bob seeds AGENTS.md and is idempotent" {
  setup_lib
  printf 'agents template\n' >"$TMPDIR_TEST/tmpl.md"
  export WABOX_WORKDIR_TEMPLATE="$TMPDIR_TEST/tmpl.md"
  WABOX_BOT_BACKEND=bob load_core
  wd="$STATE_DIR/work/abc123"
  mkdir -p "$wd"
  backend_seed_workdir abc123 "$wd"
  printf 'user edited\n' >"$wd/AGENTS.md"
  backend_seed_workdir abc123 "$wd"
  [ "$(cat "$wd/AGENTS.md")" = "user edited" ]
}

@test "agy seed writes nothing when the template var is empty" {
  setup_lib
  export WABOX_WORKDIR_TEMPLATE=""
  WABOX_BOT_BACKEND=agy load_core
  wd="$STATE_DIR/work/abc123"
  mkdir -p "$wd"
  backend_seed_workdir abc123 "$wd"
  [ ! -e "$wd/AGENTS.md" ]
}
