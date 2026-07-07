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

# Copy the media file into <workdir>/.wabox/<WABOX_MEDIA_DIR>/ and print the
# path relative to <workdir> (e.g. .wabox/media/foo.jpg) — the backend cd's
# there, so a relative path is what it needs. The caller passes the path already
# moved to $PROCESSED_DIR; we copy (not move) so the audit trail is preserved.
# Returns non-zero if the source is missing.
media_stage() {
  local src="$1" workdir="$2" name dest_dir
  [[ -f "$src" ]] || return 1
  name="$(basename -- "$src")"
  dest_dir="$(workdir_botdir "$workdir")/${WABOX_MEDIA_DIR:-media}"
  mkdir -p "$dest_dir"
  cp -f -- "$src" "$dest_dir/$name"
  # Relative to the workdir root: strip the workdir prefix off the absolute
  # dest, so the printed path stays valid after the backend's cd.
  printf '%s/%s' "${dest_dir#"$workdir"/}" "$name"
}

# Integer size of a file in MB, rounded up (a 1-byte file is 1 MB), for the
# inbound-document oversize guard. stat -c %s is Linux — the daemon is
# Linux-only (README requirements), so no BSD fallback. Missing file ⇒ non-zero.
# 1 MB = 1048576 bytes, matching human_bytes' 1024 steps.
media_size_mb() {
  local path="$1" bytes
  [[ -f "$path" ]] || return 1
  bytes="$(stat -c %s -- "$path" 2>/dev/null)" || return 1
  printf '%d' $(( (bytes + 1048576 - 1) / 1048576 ))
}

# Transcribe an audio file via $WABOX_TRANSCRIBE_CMD. The command is
# word-split (like CLAUDE_ARGS) and the audio path is appended as the final
# argument; the transcript is read from stdout. Returns the command's exit
# status; the caller also treats empty output as a failure.
media_transcribe() {
  local audio="$1"
  [[ -n "$WABOX_TRANSCRIBE_CMD" ]] || return 1
  local -a cmd
  # shellcheck disable=SC2206 # intentional word-splitting of the user command
  cmd=($WABOX_TRANSCRIBE_CMD)
  timeout --kill-after=5 "$WABOX_TRANSCRIBE_TIMEOUT" "${cmd[@]}" "$audio"
}
