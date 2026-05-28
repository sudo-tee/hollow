#!/usr/bin/env zsh
# Hollow Shell Integration for Zsh
# Only activate if running inside Hollow
if [[ -z "$HOLLOW_PANE_ID" ]]; then
  return 0 2>/dev/null || exit 0
fi

if [[ -n "${_HOLLOW_ZSH_INTEGRATION_LOADED-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset -g _HOLLOW_ZSH_INTEGRATION_LOADED=1

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

__hollow_tty_print() {
  emulate -L zsh
  print -rn -- "$1" >/dev/tty
}

__hollow_osc7() {
  emulate -L zsh
  local hostname
  hostname=$(hostname)
  __hollow_tty_print $'\e]7;file://'"$hostname$PWD"$'\e\\'
}

typeset -g _hollow_cmd_started=0
typeset -g _hollow_saved_ps1=
typeset -g _hollow_saved_ps2=
typeset -g _hollow_marked_ps1=
typeset -g _hollow_marked_ps2=

__hollow_restore_prompt() {
  emulate -L zsh

  if [[ $PS1 == $_hollow_marked_ps1 ]]; then
    PS1=$_hollow_saved_ps1
    PS2=$_hollow_saved_ps2
  fi
}

__hollow_mark_prompt() {
  emulate -L zsh

  local prompt_start=$'%{\e]133;A;cl=line\a%}'
  local prompt_cont=$'%{\e]133;P;k=s\a%}'
  local input_start=$'%{\e]133;B\a%}'

  if ! [[ -o prompt_percent ]]; then
    __hollow_tty_print $'\e]133;A;cl=line\a'
    return
  fi

  __hollow_restore_prompt

  _hollow_saved_ps1=$PS1
  _hollow_saved_ps2=$PS2

  # A trailing bare % would merge with the %{...%} wrapper we add below.
  [[ $PS1 == *[^%]% || $PS1 == % ]] && PS1=$PS1%
  PS1=${prompt_start}${PS1}${input_start}

  if [[ $PS1 == *$'\n'* ]]; then
    PS1=${PS1//$'\n'/$'\n'${prompt_cont}}
  fi

  [[ $PS2 == *[^%]% || $PS2 == % ]] && PS2=$PS2%
  PS2=${prompt_cont}${PS2}${input_start}

  _hollow_marked_ps1=$PS1
  _hollow_marked_ps2=$PS2
}

# Report CWD on directory change (e.g. after cd)
__hollow_chpwd() {
  emulate -L zsh
  __hollow_osc7
}

_hollow_preexec() {
  emulate -L zsh
  _hollow_cmd_started=1
  __hollow_restore_prompt
  __hollow_tty_print $'\e]133;C\a'
  hollow_htp_emit "command_started" "{\"command\":\"$(hollow_htp_json_escape "$1")\"}"
}

_hollow_precmd() {
  emulate -L zsh
  local exit_code=$?

  if (( _hollow_cmd_started )); then
    _hollow_cmd_started=0
    __hollow_tty_print $'\e]133;D;'"$exit_code"$'\a'
    hollow_htp_emit "command_ended" "{\"exit_code\":$exit_code}"
  fi

  __hollow_mark_prompt
  __hollow_osc7
}

add-zsh-hook chpwd __hollow_chpwd
add-zsh-hook preexec _hollow_preexec
add-zsh-hook precmd _hollow_precmd

# Initial CWD report
__hollow_osc7
