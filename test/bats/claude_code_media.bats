load test_helper

setup() {
  setup_lib
  WABOX_BOT_BACKEND=claude-code load_core
}

teardown() {
  teardown_lib
}

# Build a media manifest (JSON array) from path/type[/mime] triples: pass one
# argument per media item as "path|type|mime".
mk_manifest() {
  local item path type mime
  printf '%s\n' "$@" | jq -R 'split("|") | {path: .[0], type: .[1], mime: (.[2] // "")}' | jq -sc .
}

@test "cc_compose_prompt passes plain text through unchanged when there is no media" {
  run cc_compose_prompt "hello there" "[]"
  [ "$status" -eq 0 ]
  [ "$output" = "hello there" ]
}

@test "cc_compose_prompt passes plain text through unchanged when the manifest arg is absent" {
  run cc_compose_prompt "hello there"
  [ "$status" -eq 0 ]
  [ "$output" = "hello there" ]
}

@test "cc_compose_prompt prepends an image instruction and keeps the caption" {
  run cc_compose_prompt "what is this?" "$(mk_manifest '.wabox/media/p.jpg|image')"
  [ "$status" -eq 0 ]
  [[ "$output" == *".wabox/media/p.jpg"* ]]
  [[ "$output" == *"what is this?"* ]]
}

@test "cc_compose_prompt with an image and no caption is instruction-only" {
  run cc_compose_prompt "" "$(mk_manifest '.wabox/media/p.jpg|image')"
  [ "$status" -eq 0 ]
  [[ "$output" == *".wabox/media/p.jpg"* ]]
}

@test "cc_compose_prompt lists every item of a multi-image burst, then the caption" {
  run cc_compose_prompt "look at these" \
    "$(mk_manifest '.wabox/media/a.jpg|image' '.wabox/media/b.jpg|image')"
  [ "$status" -eq 0 ]
  [[ "$output" == *".wabox/media/a.jpg"* ]]
  [[ "$output" == *".wabox/media/b.jpg"* ]]
  [[ "$output" == *"look at these"* ]]
  # Two instruction lines (one per image).
  [ "$(grep -c 'view it and respond' <<<"$output")" -eq 2 ]
}

@test "cc_compose_prompt mixes an image and a document in one manifest" {
  run cc_compose_prompt "" \
    "$(mk_manifest '.wabox/media/p.jpg|image' '.wabox/media/c.pdf|document|application/pdf')"
  [ "$status" -eq 0 ]
  [[ "$output" == *"view it and respond"* ]]
  [[ "$output" == *"read it and respond"* ]]
  [[ "$output" == *".wabox/media/c.pdf (application/pdf)"* ]]
}

@test "cc_compose_prompt ignores a non-image/document media type" {
  run cc_compose_prompt "transcript text" "$(mk_manifest '.wabox/media/a.ogg|audio')"
  [ "$output" = "transcript text" ]
}

@test "cc_compose_prompt prepends a document instruction with the MIME and keeps the caption" {
  run cc_compose_prompt "resume isso" "$(mk_manifest '.wabox/media/c.pdf|document|application/pdf')"
  [ "$status" -eq 0 ]
  [[ "$output" == *"read it and respond"* ]]
  [[ "$output" == *".wabox/media/c.pdf"* ]]
  [[ "$output" == *"application/pdf"* ]]
  [[ "$output" == *"resume isso"* ]]
}

@test "cc_compose_prompt with a document and no caption is instruction-only" {
  run cc_compose_prompt "" "$(mk_manifest '.wabox/media/c.pdf|document|application/pdf')"
  [ "$status" -eq 0 ]
  [[ "$output" == *".wabox/media/c.pdf (application/pdf)"* ]]
}

@test "cc_compose_prompt is safe when path or caption contains a percent sign" {
  run cc_compose_prompt "50% off?" "$(mk_manifest '.wabox/media/50%off.jpg|image')"
  [ "$status" -eq 0 ]
  [[ "$output" == *"50%off.jpg"* ]]
  [[ "$output" == *"50% off?"* ]]
}
