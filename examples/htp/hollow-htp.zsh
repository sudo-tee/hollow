#!/usr/bin/env zsh

typeset -g HOLLOW_HTP_DIR=${0:A:h}
typeset -g HOLLOW_HTP_PREFIX=$'\033]1337;Hollow;'
typeset -g HOLLOW_HTP_ST=$'\033\\'

hollow_htp_json_escape() {
  emulate -L zsh
  local value=${1-}
  value=${value//\\/\\\\}
  value=${value//"/\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  print -rn -- "$value"
}

hollow_htp_next_id() {
  emulate -L zsh
  print -rn -- "zsh-$$-$(date +%s)"
}

hollow_htp_send_raw() {
  emulate -L zsh
  local json=${1:?json required}
  print -rn -- $'\033]1337;Hollow;'"$json"$'\033\\' > /dev/tty
}

hollow_htp_emit() {
  emulate -L zsh
  local name=${1:?event name required}
  local payload_json=${2:-\{\}}
  local id=$(hollow_htp_next_id)
  hollow_htp_send_raw "{\"kind\":\"event\",\"id\":\"$id\",\"name\":\"$(hollow_htp_json_escape "$name")\",\"payload\":$payload_json}"
}

hollow_htp_emit_checked() {
  emulate -L zsh
  local name=${1:?event name required}
  local payload_json=${2:-\{\}}
  local timeout=${3:-1.5}
  local id=$(hollow_htp_next_id)
  hollow_htp_send_raw "{\"kind\":\"event\",\"id\":\"$id\",\"name\":\"$(hollow_htp_json_escape "$name")\",\"payload\":$payload_json}"
  hollow_htp_read_frame "$timeout"
}

hollow_htp_emit_cwd() {
  emulate -L zsh
  local cwd=${1:-$PWD}
  hollow_htp_emit "cwd_changed" "{\"cwd\":\"$(hollow_htp_json_escape "$cwd")\"}"
}

hollow_htp_transport() {
  emulate -L zsh
  if [[ -n "${HOLLOW_REQUEST_DIR:-}" && "${HOLLOW_TRANSPORT:-auto}" != "osc" ]]; then
    print -r -- "ipc"
  else
    print -r -- "osc"
  fi
}

hollow_htp_debug_env() {
  emulate -L zsh
  print -r -- "HOLLOW_TRANSPORT=${HOLLOW_TRANSPORT:-}"
  print -r -- "HOLLOW_REQUEST_DIR=${HOLLOW_REQUEST_DIR:-}"
  print -r -- "HOLLOW_PANE_ID=${HOLLOW_PANE_ID:-}"
}

hollow_htp_read_frame() {
  emulate -L zsh
  local timeout=${1:-1.5}
  # Pure-shell OSC frame reader — no Python required.
  # Puts tty in raw mode, reads until ESC \ is seen, extracts HTP payload.
  local tty_dev=/dev/tty
  local tmp=$(mktemp)
  local saved_tty
  saved_tty=$(stty -g <"$tty_dev" 2>/dev/null) || saved_tty=""
  {
    stty raw -echo <"$tty_dev" 2>/dev/null || true
    local max_iter=$(( ${timeout%.*} * 200 + 200 ))
    local iter=0 found=0
    while (( iter < max_iter )); do
      dd bs=1 count=1 <"$tty_dev" >>"$tmp" 2>/dev/null
      local tail
      tail=$(tail -c 2 "$tmp" | od -An -tx1 | tr -d ' \n')
      [[ "$tail" == "1b5c" ]] && { found=1; break; }
      (( iter++ ))
    done
    if [[ -n "$saved_tty" ]]; then
      stty "$saved_tty" <"$tty_dev" 2>/dev/null || stty sane <"$tty_dev" 2>/dev/null || true
    else
      stty sane <"$tty_dev" 2>/dev/null || true
    fi
    if (( found )); then
      local hex prefix_hex="1b5d313333373b486f6c6c6f773b"
      hex=$(od -An -tx1 "$tmp" | tr -d ' \n')
      local after="${hex##*$prefix_hex}"
      local payload_hex="${after%1b5c}"
      if command -v xxd &>/dev/null; then
        printf '%s\n' "$(printf '%s' "$payload_hex" | xxd -r -p)"
      else
        printf '%s' "$payload_hex" | python3 -c \
          "import sys,binascii; sys.stdout.buffer.write(binascii.unhexlify(sys.stdin.read().strip()))"
        printf '\n'
      fi
      rm -f "$tmp"
      return 0
    fi
    rm -f "$tmp"
    print -r -- "hollow_htp_read_frame: timed out" >&2
    return 1
  }
}

hollow_htp_query_once() {
  emulate -L zsh
  local name=${1:?query name required}
  local params_json=${2:-\{\}}
  local timeout=${3:-1.5}
  sh "$HOLLOW_HTP_DIR/hollow-query" "$name" "$params_json" "$timeout" --id-prefix zsh
}

# Examples:
#   source ./examples/htp/hollow-htp.zsh
#   hollow_htp_emit_checked split_pane '{"floating":true}'
#   hollow_htp_query_once current_workspace
