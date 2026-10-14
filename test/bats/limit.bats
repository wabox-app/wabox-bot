load test_helper

# Usage limits: a subscription out of quota fails every turn until a known
# reset. The scheduler must wait for it (not retry into it, not give a reminder
# up), and the user must be told when.

setup() {
  setup_lib
  load_core
  # 2026-10-08 12:00 UTC = 09:00 in São Paulo.
  NOW=1791460800
}

teardown() {
  teardown_lib
}

@test "limit_text_matches knows the limit messages and nothing else" {
  limit_text_matches "You've hit your session limit · resets 11am (America/Sao_Paulo)"
  limit_text_matches "You've hit your weekly limit · resets Oct 9, 5pm (America/Sao_Paulo)"
  limit_text_matches "Claude AI usage limit reached|1791472800"
  ! limit_text_matches "API Error: 500 Internal Server Error"
  ! limit_text_matches "There is no limit to what we can do"
}

@test "limit_parse_reset reads a bare time in the named zone, today" {
  run limit_parse_reset "You've hit your session limit · resets 11am (America/Sao_Paulo)" "$NOW"
  [ "$output" = "$((NOW + 2 * 3600))" ]
  run limit_parse_reset "You've hit your session limit · resets 9:30am (America/Sao_Paulo)" "$NOW"
  [ "$output" = "$((NOW + 1800))" ]
}

@test "limit_parse_reset moves a time already past today to tomorrow" {
  run limit_parse_reset "You've hit your session limit · resets 7:30am (America/Sao_Paulo)" "$NOW"
  [ "$output" = "$((NOW - 5400 + 86400))" ]
}

@test "limit_parse_reset reads a dated reset and a trailing epoch" {
  run limit_parse_reset "You've hit your weekly limit · resets Oct 9, 5pm (America/Sao_Paulo)" "$NOW"
  [ "$output" = "$((NOW + 32 * 3600))" ]
  run limit_parse_reset "Claude AI usage limit reached|1791472800" "$NOW"
  [ "$output" = "1791472800" ]
}

@test "limit_hit falls back to WABOX_LIMIT_RETRY when no reset can be read" {
  WABOX_LIMIT_RETRY=600
  now="$(date +%s)"
  until="$(limit_hit "You've hit your session limit" 2>/dev/null)"
  ((until >= now + 600 && until <= now + 605))
  limit_active
  [ "$(limit_until)" = "$until" ]
}

@test "limit_active is false once the reset has passed, but the record stays" {
  jq -cn '{until: 1000, at: 900, text: "x"}' >"$LIMIT_FILE"
  ! limit_active
  [ "$(limit_until)" = "1000" ]
}

@test "limit_when_label shows the user's clock, with a date when not today" {
  until=$(($(date +%s) + 60))
  jq -cn --argjson u "$until" '{until: $u}' >"$LIMIT_FILE"
  [ "$(limit_when_label America/Sao_Paulo)" = "$(TZ=America/Sao_Paulo date -d "@$until" +%H:%M)" ]
  until=$(($(date +%s) + 3 * 86400))
  jq -cn --argjson u "$until" '{until: $u}' >"$LIMIT_FILE"
  [ "$(limit_when_label America/Sao_Paulo)" = "$(TZ=America/Sao_Paulo date -d "@$until" '+%a %d/%m %H:%M')" ]
}
