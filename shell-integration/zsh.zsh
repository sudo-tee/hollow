#!/usr/bin/env zsh
# Hollow Shell Integration for Zsh
# Only activate if running inside Hollow
if [[ -z "$HOLLOW_PANE_ID" ]]; then
  return 0 2>/dev/null || exit 0
fi

autoload -Uz add-zsh-hook

hollow_htp_json_escape() {
  emulate -L zsh
  local value=${1-}
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  print -rn -- "$value"
}

hollow_htp_send_raw() {
  emulate -L zsh
  local json=${1:?json required}
  print -rn -- $'\033]1337;Hollow;'"$json"$'\033\\' >/dev/tty
}

hollow_htp_emit() {
  emulate -L zsh
  local name=${1:?event name required}
  local payload_json=${2:-\{\}}
  local id="zsh-$$-$(date +%s%N)"
  hollow_htp_send_raw "{\"kind\":\"event\",\"id\":\"$id\",\"name\":\"$(hollow_htp_json_escape "$name")\",\"payload\":$payload_json}"
}

__hollow_osc7() {
  local hostname
  hostname=$(hostname)
  print -rn -- $'\e]7;file://'"$hostname$PWD"$'\e\\' >/dev/tty
}

# Report CWD on directory change (e.g. after cd)
chpwd() {
  __hollow_osc7
}

_hollow_preexec() {
  hollow_htp_emit "command_started" "{\"command\":\"$(hollow_htp_json_escape "$1")\"}"
}

_hollow_precmd() {
  local exit_code=$?
  hollow_htp_emit "command_ended" "{\"exit_code\":$exit_code}"
  __hollow_osc7
}

add-zsh-hook preexec _hollow_preexec
add-zsh-hook precmd _hollow_precmd

# Initial CWD report
__hollow_osc7
