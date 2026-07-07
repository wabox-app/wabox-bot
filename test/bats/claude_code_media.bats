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
  run cc_compose_prompt "what is this?" ".wabox/media/p.jpg" "image"
  [ "$status" -eq 0 ]
  [[ "$output" == *".wabox/media/p.jpg"* ]]
  [[ "$output" == *"what is this?"* ]]
}

@test "cc_compose_prompt with an image and no caption is instruction-only" {
  run cc_compose_prompt "" ".wabox/media/p.jpg" "image"
  [ "$status" -eq 0 ]
  [[ "$output" == *".wabox/media/p.jpg"* ]]
}

@test "cc_compose_prompt ignores a non-image/document media type" {
  run cc_compose_prompt "transcript text" ".wabox/media/a.ogg" "audio"
  [ "$output" = "transcript text" ]
}

@test "cc_compose_prompt prepends a document instruction with the MIME and keeps the caption" {
  run cc_compose_prompt "resume isso" ".wabox/media/c.pdf" "document" "application/pdf"
  [ "$status" -eq 0 ]
  [[ "$output" == *"read it and respond"* ]]
  [[ "$output" == *".wabox/media/c.pdf"* ]]
  [[ "$output" == *"application/pdf"* ]]
  [[ "$output" == *"resume isso"* ]]
}

@test "cc_compose_prompt with a document and no caption is instruction-only" {
  run cc_compose_prompt "" ".wabox/media/c.pdf" "document" "application/pdf"
  [ "$status" -eq 0 ]
  [[ "$output" == *".wabox/media/c.pdf (application/pdf)"* ]]
}

@test "cc_compose_prompt is safe when path or caption contains a percent sign" {
  run cc_compose_prompt "50% off?" ".wabox/media/50%off.jpg" "image"
  [ "$status" -eq 0 ]
  [[ "$output" == *"50%off.jpg"* ]]
  [[ "$output" == *"50% off?"* ]]
}
