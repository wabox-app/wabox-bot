# `wabox-bot config <list|get|set|unset>` — structured, registry-guarded access
# to the config file, so tooling (the wabox-tui Config screen) never has to
# rewrite sourced bash heuristically.
#
#   config list --json     all known vars: {var,value,secret,set_in_file}, masked
#   config get <VAR>        effective value, raw (secrets included — see below)
#   config set <VAR> <val>  write a plain `VAR=<printf %q>` assignment
#   config unset <VAR>      remove the file override → back to the default
#
# `list` masks secrets (bulk/display surface); `get` prints raw because it's the
# operator's own machine and the value is one grep away regardless. The daemon
# reads config only at startup, so set/unset print a "restart to apply" notice.
# No lock: config writes are whole-file atomic (tmp + mv). Exit 0 ok, 1 usage /
# unknown var.
#
# Requires lib/config.sh (CONFIG_VARS, config_is_secret, config_mask) sourced
# first. WABOX_BOT_CONFIG names the file operated on (honors --config <path>).

# The shipped template, for materializing a missing config file on first `set`.
# Derived from this file's location so it resolves under the test harness too.
_configverb_template() {
  printf '%s' "${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/config.example"
}

config_var_known() {
  local v="$1" x
  for x in "${CONFIG_VARS[@]}"; do
    [[ "$x" == "$v" ]] && return 0
  done
  return 1
}

_configverb_unknown() {
  printf 'wabox-bot config: unknown var: %s (run `wabox-bot config list --json` to see them)\n' \
    "$1" >&2
}

# Does the config file carry a *non-comment* assignment for VAR? A `# VAR=` line
# (commented default in the template) doesn't count — only a live override does.
_config_set_in_file() {
  local var="$1"
  [[ -f "$WABOX_BOT_CONFIG" ]] || return 1
  grep -qE "^[[:space:]]*${var}=" -- "$WABOX_BOT_CONFIG"
}

# Warn when the caller's environment (snapshotted before config.sh applied
# defaults, in bin/wabox-bot) exports VAR — env beats the file, so a set/unset
# may not reach the daemon if it's launched from the same shell. Advisory only.
_config_env_exported() {
  case " ${WABOX_CONFIG_PRE_ENV:-} " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

_config_restart_notice() {
  printf 'Wrote %s. Restart the daemon for the change to take effect.\n' \
    "$WABOX_BOT_CONFIG" >&2
}

# Create the config file from the template if it doesn't exist yet, so `set` on
# a fresh install has a file to edit (mirrors --init-config).
_config_ensure_file() {
  [[ -f "$WABOX_BOT_CONFIG" ]] && return 0
  local tmpl
  tmpl="$(_configverb_template)"
  mkdir -p "$(dirname "$WABOX_BOT_CONFIG")" || return 1
  if [[ -f "$tmpl" ]]; then
    cp -- "$tmpl" "$WABOX_BOT_CONFIG" || return 1
  else
    : >"$WABOX_BOT_CONFIG" || return 1
  fi
}

configverb_list_json() {
  local var val secret setf
  local -a objs=()
  for var in "${CONFIG_VARS[@]}"; do
    if config_is_secret "$var"; then secret=true; else secret=false; fi
    if _config_set_in_file "$var"; then setf=true; else setf=false; fi
    val="$(config_mask "$var" "${!var-}")"
    objs+=("$(jq -n \
      --arg var "$var" \
      --arg value "$val" \
      --argjson secret "$secret" \
      --argjson set_in_file "$setf" \
      '{var: $var, value: $value, secret: $secret, set_in_file: $set_in_file}')")
  done
  printf '%s\n' "${objs[@]}" | jq -s .
}

configverb_get() {
  local var="$1"
  config_var_known "$var" || { _configverb_unknown "$var"; return 1; }
  printf '%s\n' "${!var-}"
  # Empty output is ambiguous (set-but-empty vs. unset); clarify on a TTY only,
  # via stderr, so piped consumers still read a clean value on stdout.
  if [[ -z "${!var-}" && -t 2 ]]; then
    if [[ -n "${!var+x}" ]]; then
      printf 'note: %s is set but empty\n' "$var" >&2
    else
      printf 'note: %s is unset (using its built-in default)\n' "$var" >&2
    fi
  fi
}

configverb_set() {
  local var="$1" value="$2"
  config_var_known "$var" || { _configverb_unknown "$var"; return 1; }
  _config_ensure_file || { printf 'wabox-bot config: cannot write %s\n' "$WABOX_BOT_CONFIG" >&2; return 1; }

  if _config_env_exported "$var" && [[ "${!var-}" != "$value" ]]; then
    printf 'warning: %s is set in the environment (%s) and overrides the file — the daemon may not see this change.\n' \
      "$var" "$(config_mask "$var" "${!var-}")" >&2
  fi

  local quoted
  printf -v quoted '%q' "$value"

  # Replace the first non-comment assignment for VAR in place (preserving its
  # position and every unrelated line/comment), dropping any duplicates; append
  # under a managed marker when the var isn't assigned yet. ENVIRON (not -v)
  # carries the replacement so awk doesn't reinterpret backslashes in %q output.
  local tmp
  tmp="$(mktemp)" || return 1
  if ! _CFG_VAR="$var" _CFG_LINE="$var=$quoted" awk '
      BEGIN { var = ENVIRON["_CFG_VAR"]; line = ENVIRON["_CFG_LINE"]; done = 0 }
      $0 ~ "^[[:space:]]*" var "=" {
        if (!done) { print line; done = 1 }
        next
      }
      { print }
      END { if (!done) { print "# managed by wabox-bot config"; print line } }
    ' "$WABOX_BOT_CONFIG" >"$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  mv -- "$tmp" "$WABOX_BOT_CONFIG"
  _config_restart_notice
}

configverb_unset() {
  local var="$1"
  config_var_known "$var" || { _configverb_unknown "$var"; return 1; }

  if _config_env_exported "$var"; then
    printf 'warning: %s is set in the environment and overrides the file — unsetting the file entry may not reach the daemon.\n' \
      "$var" >&2
  fi

  # Idempotent: nothing in the file ⇒ nothing to do (quiet success).
  [[ -f "$WABOX_BOT_CONFIG" ]] || return 0
  _config_set_in_file "$var" || return 0

  local tmp
  tmp="$(mktemp)" || return 1
  if ! _CFG_VAR="$var" awk '
      BEGIN { var = ENVIRON["_CFG_VAR"] }
      $0 ~ "^[[:space:]]*" var "=" { next }
      { print }
    ' "$WABOX_BOT_CONFIG" >"$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  mv -- "$tmp" "$WABOX_BOT_CONFIG"
  _config_restart_notice
}

_configverb_usage() {
  cat <<'EOF'
Usage: wabox-bot config list --json
       wabox-bot config get <VAR>
       wabox-bot config set <VAR> <value>
       wabox-bot config unset <VAR>
EOF
}

configverb_main() {
  local action="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$action" in
    list)
      if [[ "${1:-}" != "--json" ]]; then
        printf 'wabox-bot config list: --json is required (only JSON output is supported)\n' >&2
        return 1
      fi
      configverb_list_json
      ;;
    get)
      [[ -n "${1:-}" ]] || { printf 'Usage: wabox-bot config get <VAR>\n' >&2; return 1; }
      configverb_get "$1"
      ;;
    set)
      [[ $# -eq 2 ]] || { printf 'Usage: wabox-bot config set <VAR> <value>\n' >&2; return 1; }
      configverb_set "$1" "$2"
      ;;
    unset)
      [[ -n "${1:-}" ]] || { printf 'Usage: wabox-bot config unset <VAR>\n' >&2; return 1; }
      configverb_unset "$1"
      ;;
    -h | --help | help)
      _configverb_usage
      ;;
    *)
      printf 'wabox-bot config: unknown action: %s\n' "${action:-(none)}" >&2
      _configverb_usage >&2
      return 1
      ;;
  esac
}
