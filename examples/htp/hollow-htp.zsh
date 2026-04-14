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
  python3 - "$timeout" <<'PY'
import os
import select
import sys
import termios
import tty

timeout = float(sys.argv[1])
fd = os.open('/dev/tty', os.O_RDWR | os.O_NOCTTY)
old = termios.tcgetattr(fd)
data = bytearray()

try:
    tty.setraw(fd)
    while True:
        r, _, _ = select.select([fd], [], [], timeout)
        if not r:
            break
        chunk = os.read(fd, 1)
        if not chunk:
            break
        data += chunk
        if data.endswith(b'\x1b\\'):
            break
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
    os.close(fd)

prefix = b'\x1b]1337;Hollow;'
start = data.find(prefix)
if start >= 0 and data.endswith(b'\x1b\\'):
    payload = data[start + len(prefix):-2]
    sys.stdout.write(payload.decode('utf-8', 'replace'))
    sys.stdout.write('\n')
    sys.exit(0)

sys.stderr.write('hollow_htp_read_frame: timed out waiting for HTP reply\n')
sys.exit(1)
PY
}

hollow_htp_query_once() {
  emulate -L zsh
  local name=${1:?query name required}
  local params_json=${2:-\{\}}
  local timeout=${3:-1.5}
  python3 "$HOLLOW_HTP_DIR/hollow-query.py" "$name" "$params_json" "$timeout" --id-prefix zsh
}

# Examples:
#   source ./examples/htp/hollow-htp.zsh
#   hollow_htp_emit_cwd
#   hollow_htp_query_once current_workspace
