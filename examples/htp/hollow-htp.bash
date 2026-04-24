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

hollow_htp_emit_checked() {
	local name=${1:?event name required}
	local payload_json=${2:-\{\}}
	local timeout=${3:-1.5}
	local id
	id=$(hollow_htp_next_id)
	hollow_htp_send_raw "{\"kind\":\"event\",\"id\":\"$id\",\"name\":\"$(hollow_htp_json_escape "$name")\",\"payload\":$payload_json}"
	hollow_htp_read_frame "$timeout"
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
	local tty_dev=/dev/tty
	local tmp
	tmp=$(mktemp)
	local saved_tty
	saved_tty=$(stty -g <"$tty_dev" 2>/dev/null) || saved_tty=""
	stty raw -echo <"$tty_dev" 2>/dev/null || true
	local max_iter=$((${timeout%.*} * 200 + 200))
	local iter=0 found=0
	while ((iter < max_iter)); do
		dd bs=1 count=1 <"$tty_dev" >>"$tmp" 2>/dev/null
		local tail
		tail=$(tail -c 2 "$tmp" | od -An -tx1 | tr -d ' \n')
		[[ "$tail" == "1b5c" ]] && {
			found=1
			break
		}
		((iter++))
	done
	if [[ -n "$saved_tty" ]]; then
		stty "$saved_tty" <"$tty_dev" 2>/dev/null || stty sane <"$tty_dev" 2>/dev/null || true
	else
		stty sane <"$tty_dev" 2>/dev/null || true
	fi
	if ((found)); then
		local hex prefix_hex="1b5d313333373b486f6c6c6f773b"
		hex=$(od -An -tx1 "$tmp" | tr -d ' \n')
		local after="${hex##*$prefix_hex}"
		local payload_hex="${after%1b5c}"
		rm -f "$tmp"
		if command -v xxd &>/dev/null; then
			printf '%s\n' "$(printf '%s' "$payload_hex" | xxd -r -p)"
		else
			printf '%s' "$payload_hex" | python3 -c \
				"import sys,binascii; sys.stdout.buffer.write(binascii.unhexlify(sys.stdin.read().strip()))"
			printf '\n'
		fi
		return 0
	fi
	rm -f "$tmp"
	printf 'hollow_htp_read_frame: timed out\n' >&2
	return 1
}

hollow_htp_query_once() {
	local name=${1:?query name required}
	local params_json=${2:-\{\}}
	local timeout=${3:-1.5}
	sh "$(dirname "${BASH_SOURCE[0]}")/hollow-query" "$name" "$params_json" "$timeout" --id-prefix bash
}

# Examples:
#   source ./examples/htp/hollow-htp.bash
#   hollow_htp_emit_checked "split_pane" '{"floating":true}'
#   hollow_htp_emit "build_started" '{"target":"debug"}'
#   hollow_htp_query_once "current_pane"
