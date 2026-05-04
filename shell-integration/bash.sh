#!/usr/bin/env bash

# Hollow Shell Integration for Bash

# Only activate if running inside Hollow
if [ -z "$HOLLOW_PANE_ID" ]; then
  return 0 2>/dev/null || exit 0
fi

hollow_htp_json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

hollow_htp_send_raw() {
  local json="$1"
  printf '\033]1337;Hollow;%s\033\\' "$json" >/dev/tty
}

hollow_htp_emit() {
  local name="$1"
  local payload_json="${2:-{}}"
  local id="bash-$$-$(date +%s%N)"
  local escaped_name=$(hollow_htp_json_escape "$name")
  hollow_htp_send_raw "{\"kind\":\"event\",\"id\":\"$id\",\"name\":\"$escaped_name\",\"payload\":$payload_json}"
}

_hollow_report_cwd() {
  printf '\e]7;file://%s\a' "$PWD" >/dev/tty
}

_hollow_cmd_started=0

_hollow_preexec() {
  [[ $_hollow_cmd_started == 1 ]] && return
  _hollow_cmd_started=1

  local escaped_cmd=$(hollow_htp_json_escape "$BASH_COMMAND")
  hollow_htp_emit "command_started" "{\"command\":\"$escaped_cmd\"}"
}

_hollow_precmd() {
  local exit_code=$?
  if [[ $_hollow_cmd_started == 1 ]]; then
    _hollow_cmd_started=0
    hollow_htp_emit "command_ended" "{\"exit_code\":$exit_code}"
  fi
}

trap '_hollow_preexec' DEBUG

# Prepend _hollow_precmd to existing PROMPT_COMMAND
if [[ -n "$PROMPT_COMMAND" ]]; then
  PROMPT_COMMAND="_hollow_precmd; $PROMPT_COMMAND"
else
  PROMPT_COMMAND="_hollow_precmd"
fi

# Initial report
_hollow_report_cwd
