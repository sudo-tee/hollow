#!/usr/bin/env bash

# Hollow Shell Integration for Bash

# Only activate if running inside Hollow
if [ -z "$HOLLOW_PANE_ID" ]; then
  return 0 2>/dev/null || exit 0
fi

if [[ -n "${_HOLLOW_BASH_INTEGRATION_LOADED-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_HOLLOW_BASH_INTEGRATION_LOADED=1

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

_hollow_tty_printf() {
  printf '%s' "$1" >/dev/tty
}

_hollow_report_cwd() {
  printf '\e]7;file://%s%s\a' "$HOSTNAME" "$PWD" >/dev/tty
}

_hollow_cmd_started=0
_hollow_saved_ps1=
_hollow_saved_ps2=
_hollow_marked_ps1=
_hollow_marked_ps2=

_hollow_restore_prompt() {
  if [[ $PS1 == "$_hollow_marked_ps1" ]]; then
    PS1=$_hollow_saved_ps1
    PS2=$_hollow_saved_ps2
  fi
}

_hollow_mark_prompt() {
  _hollow_restore_prompt

  _hollow_saved_ps1=$PS1
  _hollow_saved_ps2=$PS2

  PS1='\[\e]133;A;cl=line\a\]'$PS1'\[\e]133;B\a\]'
  PS2='\[\e]133;P;k=s\a\]'$PS2'\[\e]133;B\a\]'

  if [[ "$PS1" == *"\\n"* ]]; then
    PS1="${PS1//\\n/\\n$'\\[\\e]133;P;k=s\\a\\]'}"
  fi

  _hollow_marked_ps1=$PS1
  _hollow_marked_ps2=$PS2
}

_hollow_preexec() {
  [[ $_hollow_cmd_started == 1 ]] && return
  _hollow_cmd_started=1

  _hollow_restore_prompt
  _hollow_tty_printf $'\e]133;C\a'

  local escaped_cmd=$(hollow_htp_json_escape "$BASH_COMMAND")
  hollow_htp_emit "command_started" "{\"command\":\"$escaped_cmd\"}"
}

_hollow_precmd() {
  local exit_code=$?
  if [[ $_hollow_cmd_started == 1 ]]; then
    _hollow_cmd_started=0
    _hollow_tty_printf $'\e]133;D;'"$exit_code"$'\a'
    hollow_htp_emit "command_ended" "{\"exit_code\":$exit_code}"
  fi

  _hollow_mark_prompt
  _hollow_report_cwd
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
