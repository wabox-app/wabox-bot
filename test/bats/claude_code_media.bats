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
