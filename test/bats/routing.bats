load test_helper

setup() {
  setup_lib
  # shellcheck source=lib/config.sh
  source "$LIB_DIR/config.sh"
  # shellcheck source=lib/log.sh
  source "$LIB_DIR/log.sh"
  # shellcheck source=lib/routing.sh
  source "$LIB_DIR/routing.sh"
}

teardown() {
  teardown_lib
}

@test "conversation_key for a DM is the from JID" {
  envelope='{"from":"5511999@s.whatsapp.net","text":"hi"}'
  [ "$(conversation_key "$envelope")" = "5511999@s.whatsapp.net" ]
}

@test "conversation_key for a LID-routed DM is the LID JID" {
  envelope='{"from":"123456789@lid","text":"hi"}'
  [ "$(conversation_key "$envelope")" = "123456789@lid" ]
}

@test "conversation_key for a group defaults to the group JID" {
  envelope='{"from":"123-456@g.us","participant":"5511999@s.whatsapp.net","text":"hi"}'
  GROUP_PER_PARTICIPANT=0
  [ "$(conversation_key "$envelope")" = "123-456@g.us" ]
}

@test "conversation_key with GROUP_PER_PARTICIPANT=1 returns from|participant" {
  envelope='{"from":"123-456@g.us","participant":"5511999@s.whatsapp.net","text":"hi"}'
  GROUP_PER_PARTICIPANT=1
  [ "$(conversation_key "$envelope")" = "123-456@g.us|5511999@s.whatsapp.net" ]
}

@test "key_slug is stable and 40 chars (SHA-1 hex)" {
  s1="$(key_slug "abc")"
  s2="$(key_slug "abc")"
  [ "$s1" = "$s2" ]
  [ "${#s1}" -eq 40 ]
}

@test "key_slug for distinct inputs differs" {
  [ "$(key_slug "abc")" != "$(key_slug "xyz")" ]
}
