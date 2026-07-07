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

@test "media_stage copies into <workdir>/.wabox/media and prints the relative path" {
  src="$TMPDIR_TEST/src.jpg"
  printf 'bytes' >"$src"
  wd="$TMPDIR_TEST/wd"
  mkdir -p "$wd"
  run media_stage "$src" "$wd"
  [ "$status" -eq 0 ]
  [ "$output" = ".wabox/media/src.jpg" ]
  [ -f "$wd/.wabox/media/src.jpg" ]
  [ -f "$src" ]   # original untouched (copy, not move)
}

@test "media_stage fails when the source file is missing" {
  run media_stage "$TMPDIR_TEST/gone.jpg" "$TMPDIR_TEST/wd"
  [ "$status" -ne 0 ]
}

@test "media_size_mb rounds up: a 1-byte file is 1 MB" {
  printf 'x' >"$TMPDIR_TEST/tiny"
  run media_size_mb "$TMPDIR_TEST/tiny"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "media_size_mb: exactly 1 MiB is 1, one byte over is 2" {
  head -c 1048576 /dev/zero >"$TMPDIR_TEST/onemb"
  run media_size_mb "$TMPDIR_TEST/onemb"
  [ "$output" = "1" ]
  head -c 1048577 /dev/zero >"$TMPDIR_TEST/overmb"
  run media_size_mb "$TMPDIR_TEST/overmb"
  [ "$output" = "2" ]
}

@test "media_size_mb fails when the file is missing" {
  run media_size_mb "$TMPDIR_TEST/nope"
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

@test "media_transcribe returns non-zero when WABOX_TRANSCRIBE_CMD is empty" {
  WABOX_TRANSCRIBE_CMD=""
  run media_transcribe "/some/audio.ogg"
  [ "$status" -ne 0 ]
}
