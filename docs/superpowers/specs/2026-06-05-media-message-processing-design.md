# Processing image and audio messages

**Date:** 2026-06-05
**Status:** Approved (design)

## Problem

When a WhatsApp message arrives with no text (`text == ""`), `lib/inbox.sh`
treats it as a no-op and never replies — even when it carries an image or a
voice note. The user wants media-only messages (and media with a caption) to be
processed by the agent.

## Data model (confirmed against real envelopes)

Media always arrives paired with its JSON envelope of the same *stem*
(`…_B7B3F3F4.json` + `…_B7B3F3F4.ogg`). The envelope is the source of truth:

```json
{
  "text": "",                      // caption; may be empty
  "media": {
    "type": "audio",               // "audio" | "image" | (others, out of scope)
    "file": "…_B7B3F3F4.ogg",      // filename, lands in $WABOX_INBOX
    "mimetype": "audio/ogg; codecs=opus"
  }
}
```

There is no media without an envelope. Media files left *loose* in the inbox are
stragglers whose envelope was already processed in a prior run; the catch-up
loop iterates only `*.json`, so they are never re-processed (see Edge cases).

`lib/inbox.sh` already reads `.media.file` and moves it from `$WABOX_INBOX` to
`$PROCESSED_DIR` during the read-receipt step. This change hangs media
processing off that existing flow.

## Goal

- An **image** message (with or without caption) is handed to the agent, which
  reads the image and replies.
- An **audio** message is **transcribed** to text via a pluggable command and
  then handled as a normal text turn.
- A **caption** that accompanies media is included alongside the media.

## Non-goals

- Media types other than `image` and `audio` (video, document, sticker) — these
  remain a logged no-op for now.
- Outbound media (sending files/images back) — unchanged; out of scope.
- Bundled STT engine. Transcription is delegated to a user-supplied command; no
  transcription dependency ships with wabox-bot.
- Per-sender authorization (unchanged trust surface; same as today).

## Architecture

A new single-purpose module **`lib/media.sh`** owns media helpers; `lib/inbox.sh`
orchestrates. This keeps `inbox.sh` readable and follows the project's
"one named seam per file" convention.

Source order in `bin/wabox-bot` and `load_core`: `media.sh` after `workdir.sh`
(it uses `conversation_workdir`) and before `commands.sh`/`inbox.sh`. It depends
on `log.sh`, `config.sh`, and `workdir.sh`.

### `lib/media.sh` — helpers

- `media_type_of <envelope>` / `media_file_of <envelope>` / `media_mime_of <envelope>`
  — parse the `.media.*` fields (empty string when absent).
- `media_stage <src_path> <workdir>` — copy the media file into
  `<workdir>/wabox-media/` (created on demand) and print the path **relative to
  `<workdir>`** (e.g. `wabox-media/…_B7B3F3F4.ogg`). The source is the copy
  already moved to `$PROCESSED_DIR`. Copy (not move) so the `processed/` audit
  trail is preserved and `KEEP_PROCESSED` still governs it.
- `media_transcribe <audio_path>` — run the transcription command with a
  timeout; print the transcript on stdout. Returns non-zero on failure.

### Transcription command contract

`WABOX_TRANSCRIBE_CMD` is word-split (like `CLAUDE_ARGS`) and the **audio file
path is appended as the final argument**; the command writes the transcript to
stdout. Example: `WABOX_TRANSCRIBE_CMD="whisper-stt --lang pt"` runs
`whisper-stt --lang pt <path>`. Empty/unset ⇒ audio is ignored (logged no-op).
The call is wrapped in `timeout $WABOX_TRANSCRIBE_TIMEOUT`.

### Backend contract extension

`backend_reply` gains **three optional trailing arguments**:
`backend_reply <slug> <conv_key> <stem> [media_path] [media_type] [media_mime]`.

- `media_path` is relative to the working folder (the backend `cd`s there).
- Backends that don't care (`echo`, `aider`) ignore the extra args — unchanged.
- The required contract is still only `backend_name` + `backend_reply`; the
  validation in `lib/backend.sh` is unaffected.

The `claude-code` backend, when `media_type == image`, prepends a short
instruction to the prompt pointing the agent at `media_path` (which sits under
its cwd), then the caption. `claude` reads the image with its Read tool. Other
`media_type` values are ignored by the backend (audio never reaches it — see
data flow).

## Data flow (`lib/inbox.sh`)

The current empty-text no-op block is replaced. For an envelope whose
`fromMe`/routing checks have passed:

1. Read `media_type`, `media_file`, `media_mime` from the envelope. (The media
   file was already moved to `$PROCESSED_DIR` in the read-receipt step.)
2. If `media_type` is set:
   - `workdir = conversation_workdir(slug)`; `staged = media_stage(...)`. If
     staging fails (file vanished), log and no-op return.
   - **audio:** if `WABOX_TRANSCRIBE_CMD` is empty ⇒ log and no-op return.
     Otherwise `transcript = media_transcribe(staged)`. The message `text`
     becomes `transcript`, or `<caption>\n\n<transcript>` when a caption exists.
     The media is now "consumed" — no media args are passed to the backend; the
     normal text flow runs.
   - **image:** keep `text` as the caption (possibly empty); the staged path,
     `image`, and mime are passed to the backend as the media args.
   - **other types:** log "unsupported" and no-op return.
3. If, after the above, `text` is empty **and** there is no image to pass ⇒
   no-op return (unchanged behavior for truly empty messages).
4. **Slash commands run only for pure-text messages** (no media on the
   envelope). A caption like `/clear` on an image is treated as a caption, not a
   command. (Documented.)
5. Hand off to `backend_reply` under the per-conversation flock, passing the
   media args when present.

## Configuration (new)

| Env var | Default | Meaning |
| --- | --- | --- |
| `WABOX_TRANSCRIBE_CMD` | (empty) | STT command; the audio path is appended as the last argument, transcript read from stdout. Empty ⇒ audio messages are ignored. |
| `WABOX_TRANSCRIBE_TIMEOUT` | `120` | Max seconds for the transcription command before it is killed. |

## Error handling

- **Transcription fails** (non-zero exit, timeout, or empty output) ⇒ log the
  error and reply `(Não consegui transcrever o áudio.)`. No backend turn runs.
- **Media file missing** before staging ⇒ log and no-op (treat like a message
  that produced nothing).
- **Image backend not vision-capable** (e.g. `echo`) ⇒ it ignores the media
  args and replies to the caption only; acceptable degradation.
- **Orphan media** (loose media file in the inbox with no envelope) ⇒ not
  re-processed (catch-up iterates only `*.json`). Documented limitation; manual
  cleanup of `processed/`-style stragglers is the user's responsibility.

## Testing (bats)

- `test/bats/media.bats`:
  - `media_type_of` / `media_file_of` / `media_mime_of` parse a sample envelope.
  - `media_stage` copies into `<workdir>/wabox-media/` and prints the relative
    path; the original is untouched.
  - `media_transcribe` runs a fake `WABOX_TRANSCRIBE_CMD` (e.g. a script that
    prints fixed text) and returns its stdout; non-zero/empty paths are handled.
- `test/bats/commands.bats` or a new `inbox`-level test exercising the routing
  decisions is impractical without the full loop, so the media→text vs
  media→backend decisions are covered at the helper level plus:
- `test/bats/claude_code_session.bats` (or a new backend test): `backend_reply`
  with `media_type=image` injects the `media_path` instruction into the built
  command. Audio is verified to reach the backend as plain transcript text (no
  media args), consistent with how existing backend tests inspect the assembled
  `claude` invocation.

## Documentation

- `README.md`: new feature bullet (image + audio-via-transcription) and the two
  new env vars near the Configuration table.
- `docs/backends.md`: document the three optional `backend_reply` media args and
  that `media_path` is relative to the working folder.
- `CHANGELOG.md`: `[Unreleased]` → Added.
