# Image/Audio Message Processing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Process media-only (and captioned) WhatsApp messages — images are handed to the agent by file reference; audio is transcribed to text via a pluggable command.

**Architecture:** A new core module `lib/media.sh` parses the envelope's media object, stages the file into the conversation's working folder, and transcribes audio. `lib/inbox.sh` orchestrates: audio → transcript text (generic), image → reference passed to the backend via three new optional `backend_reply` args. The `claude-code` backend composes a prompt that points the agent at the image.

**Tech Stack:** Pure bash 4+, `jq`, `flock`, `timeout`; tests with `bats`; lint with `shellcheck -x`.

---

## File Structure

- **Create** `lib/media.sh` — `media_type_of`, `media_file_of`, `media_mime_of`, `media_stage`, `media_transcribe`. Depends on `jq`, `config.sh`, `workdir.sh`.
- **Modify** `lib/config.sh` — defaults for `WABOX_TRANSCRIBE_CMD`, `WABOX_TRANSCRIBE_TIMEOUT`.
- **Modify** `bin/wabox-bot` and `test/bats/test_helper.bash` — source `lib/media.sh` after `workdir.sh`.
- **Modify** `lib/backends/claude-code.sh` — `cc_compose_prompt` helper; `backend_reply` takes 3 optional media args and feeds the composed prompt to `claude`.
- **Modify** `lib/inbox.sh` — replace the empty-text no-op with media handling; pass media args to the backend; run slash commands only for pure-text messages.
- **Create** `test/bats/media.bats` — helper unit tests.
- **Create** `test/bats/claude_code_media.bats` — `cc_compose_prompt` tests.
- **Create** `test/bats/inbox_media.bats` — end-to-end tests through `handle_envelope` with the `echo` backend.

`lib/media.sh` is covered by `shellcheck -x bin/wabox-bot` (the entrypoint sources it).

---

## Task 1: `lib/media.sh` helpers + config

**Files:**
- Create: `lib/media.sh`
- Create: `test/bats/media.bats`
- Modify: `lib/config.sh` (add two env defaults)
- Modify: `bin/wabox-bot` (source line after `workdir.sh`)
- Modify: `test/bats/test_helper.bash` (`load_core`, source line after `workdir.sh`)

- [ ] **Step 1: Write the failing test**

Create `test/bats/media.bats`:

```bash
load test_helper

setup() {
  setup_lib
  load_core
  ENV_AUDIO='{"text":"","media":{"type":"audio","file":"a.ogg","mimetype":"audio/ogg; codecs=opus"}}'
  ENV_IMAGE='{"text":"oi","media":{"type":"image","file":"p.jpg","mimetype":"image/jpeg"}}'
  ENV_NONE='{"text":"hello","media":null}'
}

teardown() {
  teardown_lib
}

@test "media_type_of / media_file_of / media_mime_of parse the media object" {
  [ "$(media_type_of "$ENV_AUDIO")" = "audio" ]
  [ "$(media_file_of "$ENV_AUDIO")" = "a.ogg" ]
  [ "$(media_mime_of "$ENV_AUDIO")" = "audio/ogg; codecs=opus" ]
}

@test "media_type_of is empty when there is no media" {
  [ -z "$(media_type_of "$ENV_NONE")" ]
}

@test "media_stage copies into <workdir>/wabox-media and prints the relative path" {
  src="$TMPDIR_TEST/src.jpg"
  printf 'bytes' >"$src"
  wd="$TMPDIR_TEST/wd"
  mkdir -p "$wd"
  run media_stage "$src" "$wd"
  [ "$status" -eq 0 ]
  [ "$output" = "wabox-media/src.jpg" ]
  [ -f "$wd/wabox-media/src.jpg" ]
  [ -f "$src" ]   # original untouched (copy, not move)
}

@test "media_stage fails when the source file is missing" {
  run media_stage "$TMPDIR_TEST/gone.jpg" "$TMPDIR_TEST/wd"
  [ "$status" -ne 0 ]
}

@test "media_transcribe runs WABOX_TRANSCRIBE_CMD with the audio path and returns stdout" {
  cat >"$TMPDIR_TEST/fake_stt.sh" <<'SH'
#!/usr/bin/env bash
# echo the basename of the audio path it received, to prove the path is passed
printf 'transcript of %s' "$(basename "$1")"
SH
  chmod +x "$TMPDIR_TEST/fake_stt.sh"
  WABOX_TRANSCRIBE_CMD="$TMPDIR_TEST/fake_stt.sh"
  run media_transcribe "/some/audio.ogg"
  [ "$status" -eq 0 ]
  [ "$output" = "transcript of audio.ogg" ]
}

@test "media_transcribe propagates a non-zero exit from the command" {
  WABOX_TRANSCRIBE_CMD="false"
  run media_transcribe "/some/audio.ogg"
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats test/bats/media.bats`
Expected: FAIL — `load_core` does not source `media.sh`, so `media_type_of` etc. are undefined ("command not found").

- [ ] **Step 3: Create `lib/media.sh`**

```bash
# Inbound media handling.
#
# Parse the envelope's media object, stage the file into the conversation's
# working folder so the agent can read it, and transcribe audio via a
# pluggable command. Audio is turned into text here (backend-agnostic);
# images are handed to the backend by reference. See lib/inbox.sh for how
# these are wired into the per-envelope flow.

media_type_of() { jq -r '.media.type     // empty' <<<"$1"; }
media_file_of() { jq -r '.media.file     // empty' <<<"$1"; }
media_mime_of() { jq -r '.media.mimetype // empty' <<<"$1"; }

# Copy the media file into <workdir>/wabox-media/ and print the path relative
# to <workdir> — the backend cd's there, so a relative path is what it needs.
# The source is the copy already parked in $PROCESSED_DIR; we copy (not move)
# so the processed/ audit trail is preserved. Returns non-zero if the source
# is missing.
media_stage() {
  local src="$1" workdir="$2" name dest_dir
  [[ -f "$src" ]] || return 1
  name="$(basename -- "$src")"
  dest_dir="$workdir/wabox-media"
  mkdir -p "$dest_dir"
  cp -f -- "$src" "$dest_dir/$name"
  printf 'wabox-media/%s' "$name"
}

# Transcribe an audio file via $WABOX_TRANSCRIBE_CMD. The command is
# word-split (like CLAUDE_ARGS) and the audio path is appended as the final
# argument; the transcript is read from stdout. Returns the command's exit
# status; the caller also treats empty output as a failure.
media_transcribe() {
  local audio="$1"
  local -a cmd
  # shellcheck disable=SC2206 # intentional word-splitting of the user command
  cmd=($WABOX_TRANSCRIBE_CMD)
  timeout --kill-after=5 "$WABOX_TRANSCRIBE_TIMEOUT" "${cmd[@]}" "$audio"
}
```

- [ ] **Step 4: Add the env defaults to `lib/config.sh`**

In `lib/config.sh`, find the block of `*="${*:-...}"` defaults (the lines defining `GROUP_PER_PARTICIPANT`, `IGNORE_FROM_ME`, `KEEP_PROCESSED`). Immediately after the `KEEP_PROCESSED` line, add:

```bash
# Pluggable speech-to-text for inbound audio. WABOX_TRANSCRIBE_CMD is
# word-split and the audio file path is appended as its final argument; the
# transcript is read from stdout. Empty ⇒ audio messages are ignored.
WABOX_TRANSCRIBE_CMD="${WABOX_TRANSCRIBE_CMD:-}"
WABOX_TRANSCRIBE_TIMEOUT="${WABOX_TRANSCRIBE_TIMEOUT:-120}"
```

- [ ] **Step 5: Source `lib/media.sh` in `bin/wabox-bot`**

In `bin/wabox-bot`, find:

```bash
# shellcheck source=lib/workdir.sh
source "$LIB_DIR/workdir.sh"
```

Insert immediately after it:

```bash
# shellcheck source=lib/media.sh
source "$LIB_DIR/media.sh"
```

- [ ] **Step 6: Source `lib/media.sh` in `load_core`**

In `test/bats/test_helper.bash`, find:

```bash
  # shellcheck source=lib/workdir.sh
  source "$LIB_DIR/workdir.sh"
```

Insert immediately after it:

```bash
  # shellcheck source=lib/media.sh
  source "$LIB_DIR/media.sh"
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `bats test/bats/media.bats`
Expected: PASS (7 tests).

- [ ] **Step 8: Lint**

Run: `shellcheck -x bin/wabox-bot`
Expected: no output (exit 0).

- [ ] **Step 9: Commit**

```bash
git add lib/media.sh lib/config.sh bin/wabox-bot test/bats/test_helper.bash test/bats/media.bats
git commit -m "feat: media helpers (parse, stage, transcribe)"
```

---

## Task 2: `claude-code` prompt composition + media args

**Files:**
- Modify: `lib/backends/claude-code.sh` (`cc_compose_prompt` helper; `backend_reply` signature + prompt)
- Create: `test/bats/claude_code_media.bats`

- [ ] **Step 1: Write the failing test**

Create `test/bats/claude_code_media.bats`:

```bash
load test_helper

setup() {
  setup_lib
  WABOX_BOT_BACKEND=claude-code load_core
}

teardown() {
  teardown_lib
}

@test "cc_compose_prompt passes plain text through unchanged when there is no media" {
  run cc_compose_prompt "hello there" "" ""
  [ "$status" -eq 0 ]
  [ "$output" = "hello there" ]
}

@test "cc_compose_prompt prepends an image instruction and keeps the caption" {
  run cc_compose_prompt "what is this?" "wabox-media/p.jpg" "image"
  [[ "$output" == *"wabox-media/p.jpg"* ]]
  [[ "$output" == *"what is this?"* ]]
}

@test "cc_compose_prompt with an image and no caption is instruction-only" {
  run cc_compose_prompt "" "wabox-media/p.jpg" "image"
  [[ "$output" == *"wabox-media/p.jpg"* ]]
}

@test "cc_compose_prompt ignores a non-image media type" {
  run cc_compose_prompt "transcript text" "wabox-media/a.ogg" "audio"
  [ "$output" = "transcript text" ]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats test/bats/claude_code_media.bats`
Expected: FAIL — `cc_compose_prompt` is undefined ("command not found").

- [ ] **Step 3: Add `cc_compose_prompt` to `lib/backends/claude-code.sh`**

In `lib/backends/claude-code.sh`, immediately before the `# ---- The Claude turn` comment (the line above `backend_reply()`), insert:

```bash
# Compose the prompt fed to claude on stdin. With an image we prepend a short
# instruction pointing the agent at the staged file (relative to its cwd),
# then the caption. Any other media type (audio is already transcribed into
# text upstream) passes the text through unchanged.
cc_compose_prompt() {
  local text="$1" media_path="$2" media_type="$3"
  if [[ "$media_type" == "image" && -n "$media_path" ]]; then
    if [[ -n "$text" ]]; then
      printf 'The user sent an image at %s — view it and respond.\n\n%s' "$media_path" "$text"
    else
      printf 'The user sent an image at %s — view it and respond.' "$media_path"
    fi
  else
    printf '%s' "$text"
  fi
}
```

- [ ] **Step 4: Extend `backend_reply` to accept media args and use the composed prompt**

In `lib/backends/claude-code.sh`, change the start of `backend_reply` from:

```bash
backend_reply() {
  local slug="$1" conv_key="$2" stem="$3"
  local text
  text="$(cat)"
```

to:

```bash
backend_reply() {
  local slug="$1" conv_key="$2" stem="$3"
  local media_path="${4:-}" media_type="${5:-}"
  local text
  text="$(cat)"
```

Then change the line that pipes text into `claude` (inside `backend_reply`):

```bash
  local response_json rc=0
  response_json="$(printf '%s' "$text" |
    timeout --kill-after=5 "$CLAUDE_TIMEOUT" "${cmd[@]}" 2>>"$LOG_FILE")" || rc=$?
```

to:

```bash
  local prompt
  prompt="$(cc_compose_prompt "$text" "$media_path" "$media_type")"
  local response_json rc=0
  response_json="$(printf '%s' "$prompt" |
    timeout --kill-after=5 "$CLAUDE_TIMEOUT" "${cmd[@]}" 2>>"$LOG_FILE")" || rc=$?
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bats test/bats/claude_code_media.bats`
Expected: PASS (4 tests).

- [ ] **Step 6: Lint**

Run: `shellcheck -x bin/wabox-bot && shellcheck lib/backends/*.sh`
Expected: no output (exit 0).

- [ ] **Step 7: Commit**

```bash
git add lib/backends/claude-code.sh test/bats/claude_code_media.bats
git commit -m "feat: claude-code composes an image prompt from media args"
```

---

## Task 3: `lib/inbox.sh` media handling

**Files:**
- Modify: `lib/inbox.sh` (replace the empty-text no-op block; pass media args to the backend)
- Create: `test/bats/inbox_media.bats`

- [ ] **Step 1: Write the failing test**

Create `test/bats/inbox_media.bats`:

```bash
load test_helper

setup() {
  setup_lib
  export WABOX_BOT_BACKEND=echo
  load_core
  # shellcheck source=lib/inbox.sh
  source "$LIB_DIR/inbox.sh"
  JID="5511999999999@s.whatsapp.net"
  SLUG="$(printf '%s' "$JID" | sha1sum | awk '{print $1}')"
}

teardown() {
  teardown_lib
}

# Helper: write an envelope (+ optional media file) into the inbox.
mk_envelope() {
  local stem="$1" json="$2" media_name="$3"
  printf '%s' "$json" >"$WABOX_INBOX/$stem.json"
  [[ -n "$media_name" ]] && printf 'fake-bytes' >"$WABOX_INBOX/$media_name"
  return 0
}

@test "image-only message: file is staged and a reply is produced (no no-op)" {
  stem="20260101-000000_x_AAAA"
  mk_envelope "$stem" \
    "$(jq -nc --arg j "$JID" --arg f "$stem.jpg" \
       '{id:"M1",from:$j,text:"",media:{type:"image",file:$f,mimetype:"image/jpeg"}}')" \
    "$stem.jpg"
  handle_envelope "$WABOX_INBOX/$stem.json"
  [ -f "$WABOX_OUTBOX/$stem.json" ]
  [ -f "$STATE_DIR/work/$SLUG/wabox-media/$stem.jpg" ]
}

@test "audio message is transcribed via WABOX_TRANSCRIBE_CMD and sent as text" {
  cat >"$TMPDIR_TEST/fake_stt.sh" <<'SH'
#!/usr/bin/env bash
printf 'ola mundo'
SH
  chmod +x "$TMPDIR_TEST/fake_stt.sh"
  export WABOX_TRANSCRIBE_CMD="$TMPDIR_TEST/fake_stt.sh"
  stem="20260101-000001_x_BBBB"
  mk_envelope "$stem" \
    "$(jq -nc --arg j "$JID" --arg f "$stem.ogg" \
       '{id:"M2",from:$j,text:"",media:{type:"audio",file:$f,mimetype:"audio/ogg"}}')" \
    "$stem.ogg"
  handle_envelope "$WABOX_INBOX/$stem.json"
  [ "$(jq -r '.text' "$WABOX_OUTBOX/$stem.json")" = "echo: ola mundo" ]
}

@test "audio message with no transcriber configured is a silent no-op" {
  export WABOX_TRANSCRIBE_CMD=""
  stem="20260101-000002_x_CCCC"
  mk_envelope "$stem" \
    "$(jq -nc --arg j "$JID" --arg f "$stem.ogg" \
       '{id:"M3",from:$j,text:"",media:{type:"audio",file:$f,mimetype:"audio/ogg"}}')" \
    "$stem.ogg"
  handle_envelope "$WABOX_INBOX/$stem.json"
  [ ! -f "$WABOX_OUTBOX/$stem.json" ]
}

@test "plain /ping text still runs the slash command" {
  stem="20260101-000003_x_DDDD"
  mk_envelope "$stem" \
    "$(jq -nc --arg j "$JID" '{id:"M4",from:$j,text:"/ping",media:null}')" ""
  handle_envelope "$WABOX_INBOX/$stem.json"
  [ "$(jq -r '.text' "$WABOX_OUTBOX/$stem.json")" = "pong" ]
}

@test "a /clear caption on an image is treated as a caption, not a command" {
  stem="20260101-000004_x_EEEE"
  mk_envelope "$stem" \
    "$(jq -nc --arg j "$JID" --arg f "$stem.jpg" \
       '{id:"M5",from:$j,text:"/clear",media:{type:"image",file:$f,mimetype:"image/jpeg"}}')" \
    "$stem.jpg"
  handle_envelope "$WABOX_INBOX/$stem.json"
  [ "$(jq -r '.text' "$WABOX_OUTBOX/$stem.json")" = "echo: /clear" ]
}

@test "unsupported media type (video) is a silent no-op" {
  stem="20260101-000005_x_FFFF"
  mk_envelope "$stem" \
    "$(jq -nc --arg j "$JID" --arg f "$stem.mp4" \
       '{id:"M6",from:$j,text:"",media:{type:"video",file:$f,mimetype:"video/mp4"}}')" \
    "$stem.mp4"
  handle_envelope "$WABOX_INBOX/$stem.json"
  [ ! -f "$WABOX_OUTBOX/$stem.json" ]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats test/bats/inbox_media.bats`
Expected: the image and audio-transcribe tests FAIL (media-only is still a no-op, no outbox file / no staging). The no-op and `/ping` tests may already pass; the `/clear`-caption test FAILS (currently treated as a command).

- [ ] **Step 3: Replace the empty-text no-op block in `lib/inbox.sh`**

In `lib/inbox.sh`, replace this block:

```bash
  # Treat empty text as no-op (media-only messages). A real integration
  # would download the media and feed it to the backend here.
  if [[ -z "$text" ]]; then
    log_info "[$stem] empty text (likely media-only); not replying"
    return 0
  fi

  # ---- Step 5: agent-level slash commands -------------------------------
  if handle_slash_command "$text" "$slug" "$conv_key" "$to" "$id" "$stem"; then
    return 0
  fi
```

with:

```bash
  # ---- Step 4b: media handling ------------------------------------------
  # media_file was read in step 2 and the file moved to $PROCESSED_DIR in
  # step 3. Audio is transcribed here (generic → becomes text); an image is
  # staged and passed to the backend by reference. Other types are skipped.
  local media_type media_mime media_rel="" had_media=0
  media_type="$(media_type_of "$envelope")"
  media_mime="$(media_mime_of "$envelope")"
  if [[ -n "$media_type" ]]; then
    had_media=1
    local workdir
    workdir="$(conversation_workdir "$slug")"
    if ! media_rel="$(media_stage "$PROCESSED_DIR/$media_file" "$workdir")"; then
      log_warn "[$stem] media file gone before staging; nothing to process"
      return 0
    fi
    case "$media_type" in
      audio)
        if [[ -z "$WABOX_TRANSCRIBE_CMD" ]]; then
          log_info "[$stem] audio message but WABOX_TRANSCRIBE_CMD unset; skipping"
          return 0
        fi
        local transcript trc=0
        transcript="$(media_transcribe "$workdir/$media_rel")" || trc=$?
        if ((trc != 0)) || [[ -z "$transcript" ]]; then
          log_error "[$stem] transcription failed (rc=$trc)"
          write_outbox "$to" "(Não consegui transcrever o áudio.)" "$id" "$stem" >/dev/null
          return 0
        fi
        # Transcript becomes the message text (caption first, if any). The
        # media is now consumed — no media args go to the backend.
        if [[ -n "$text" ]]; then
          text="$text"$'\n\n'"$transcript"
        else
          text="$transcript"
        fi
        media_type="" media_mime="" media_rel=""
        ;;
      image)
        : # keep media_rel/media_type/media_mime; passed to the backend below
        ;;
      *)
        log_info "[$stem] unsupported media type '$media_type'; skipping"
        return 0
        ;;
    esac
  fi

  # Nothing actionable: no text and no image to forward.
  if [[ -z "$text" && -z "$media_rel" ]]; then
    log_info "[$stem] empty message (no text, no actionable media); not replying"
    return 0
  fi

  # ---- Step 5: agent-level slash commands (pure-text messages only) -----
  # A caption that happens to start with "/" is treated as a caption, not a
  # command, so media is never silently swallowed by the dispatcher.
  if ((!had_media)) && handle_slash_command "$text" "$slug" "$conv_key" "$to" "$id" "$stem"; then
    return 0
  fi
```

- [ ] **Step 4: Pass the media args to the backend in `lib/inbox.sh`**

In `lib/inbox.sh`, inside the per-conversation flock subshell, change:

```bash
    reply="$(printf '%s' "$text" | backend_reply "$slug" "$conv_key" "$stem")" || rc=$?
```

to:

```bash
    reply="$(printf '%s' "$text" |
      backend_reply "$slug" "$conv_key" "$stem" "$media_rel" "$media_type" "$media_mime")" || rc=$?
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bats test/bats/inbox_media.bats`
Expected: PASS (6 tests).

- [ ] **Step 6: Run the full suite + lint**

Run: `bats test/bats/ && shellcheck -x bin/wabox-bot && shellcheck lib/backends/*.sh install.sh examples/aider.sh`
Expected: all PASS; no shellcheck output.

- [ ] **Step 7: Commit**

```bash
git add lib/inbox.sh test/bats/inbox_media.bats
git commit -m "feat: process image and audio messages in the inbox handler"
```

---

## Task 4: Documentation

**Files:**
- Modify: `README.md` (feature bullet + two config rows)
- Modify: `docs/backends.md` (media args)
- Modify: `CHANGELOG.md` (`[Unreleased]`)

- [ ] **Step 1: README feature bullet**

In `README.md`, in the bulleted feature list near the top (after the
"Per-conversation working folder" bullet), add:

```markdown
- **Image & audio messages** — an image is handed to the agent to read; a voice
  note is transcribed to text first via a pluggable command (`WABOX_TRANSCRIBE_CMD`).
  Captions are included. Media is staged under `<working-folder>/wabox-media/`.
```

- [ ] **Step 2: README config rows**

In `README.md`, in the Configuration table (the `| Env var | Default | Meaning |`
table), add these rows after the `DEBUG` row:

```markdown
| `WABOX_TRANSCRIBE_CMD` | (empty) | Speech-to-text command for inbound audio; the audio path is appended as the last argument, transcript read from stdout. Empty ⇒ audio is ignored. |
| `WABOX_TRANSCRIBE_TIMEOUT` | `120` | Max seconds for the transcription command. |
```

- [ ] **Step 3: `docs/backends.md` media args**

In `docs/backends.md`, in the section documenting the `backend_reply` contract,
add a paragraph:

```markdown
`backend_reply` may receive three optional trailing arguments —
`backend_reply <slug> <conv_key> <stem> [media_path] [media_type] [media_mime]`.
When the inbound message carries an image, `media_path` is the file's location
**relative to the working folder** (the backend's cwd), `media_type` is
`image`, and `media_mime` is its MIME type. Audio is transcribed upstream and
arrives as plain text, so backends only ever see `image` here. Backends that
don't handle media simply ignore these arguments.
```

- [ ] **Step 4: CHANGELOG entry**

In `CHANGELOG.md`, under the `[Unreleased]` → `### Added` list, add:

```markdown
- Image and audio message processing. Image messages are handed to the agent to
  read; audio (voice notes) are transcribed to text via a pluggable command
  (`WABOX_TRANSCRIBE_CMD`, `WABOX_TRANSCRIBE_TIMEOUT`). Captions are included and
  media is staged under `<working-folder>/wabox-media/`. The `backend_reply`
  contract gains three optional media arguments.
```

- [ ] **Step 5: Commit**

```bash
git add README.md docs/backends.md CHANGELOG.md
git commit -m "docs: image/audio message processing and WABOX_TRANSCRIBE_CMD"
```

---

## Final Verification

- [ ] Full suite: `bats test/bats/` — expected: all PASS.
- [ ] Core lint: `shellcheck -x bin/wabox-bot` — expected: no output.
- [ ] CI lint set: `shellcheck lib/backends/*.sh install.sh examples/aider.sh` — expected: no output.
