#!/usr/bin/env bash

hollow_htp_json_escape() {
	local value=${1-}
	value=${value//\\/\\\\}
	value=${value//"/\\"/}
	value=${value//$'\n'/\\n}
	value=${value//$'\r'/\\r}
	value=${value//$'\t'/\\t}
	printf '%s' "$value"
}

hollow_htp_next_id() {
	printf 'bash-%s-%s' "$$" "$(date +%s)"
}

hollow_htp_send_raw() {
	local json=${1:?json required}
	printf '\033]1337;Hollow;%s\033\\' "$json" >/dev/tty
}

hollow_htp_emit() {
	local name=${1:?event name required}
	local payload_json=${2:-\{\}}
	local id
	id=$(hollow_htp_next_id)
	hollow_htp_send_raw "{\"kind\":\"event\",\"id\":\"$id\",\"name\":\"$(hollow_htp_json_escape "$name")\",\"payload\":$payload_json}"
}

hollow_htp_emit_cwd() {
	local cwd=${1:-$PWD}
	hollow_htp_emit "cwd_changed" "{\"cwd\":\"$(hollow_htp_json_escape "$cwd")\"}"
}

hollow_htp_transport() {
	if [[ -n "${HOLLOW_REQUEST_DIR:-}" && "${HOLLOW_TRANSPORT:-auto}" != "osc" ]]; then
		printf 'ipc\n'
	else
		printf 'osc\n'
	fi
}

hollow_htp_debug_env() {
	printf 'HOLLOW_TRANSPORT=%s\n' "${HOLLOW_TRANSPORT:-}"
	printf 'HOLLOW_REQUEST_DIR=%s\n' "${HOLLOW_REQUEST_DIR:-}"
	printf 'HOLLOW_PANE_ID=%s\n' "${HOLLOW_PANE_ID:-}"
}

hollow_htp_read_frame() {
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
	local name=${1:?query name required}
	local params_json=${2:-\{\}}
	python3 "$(dirname "${BASH_SOURCE[0]}")/hollow-query.py" "$name" "$params_json" "${3:-1.5}" --id-prefix bash
}

# Examples:
#   source ./examples/htp/hollow-htp.bash
#   hollow_htp_emit_cwd
#   hollow_htp_emit "build_started" '{"target":"debug"}'
#   hollow_htp_query_once "current_pane"
