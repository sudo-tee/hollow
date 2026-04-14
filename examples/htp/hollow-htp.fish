set -g HOLLOW_HTP_DIR (status dirname)

function hollow_htp_json_escape
    set -l value $argv[1]
    string replace -a '\\' '\\\\' -- $value |
        string replace -a '"' '\\"' |
        string replace -a '\n' '\\n' |
        string replace -a '\r' '\\r' |
        string replace -a '\t' '\\t'
end

function hollow_htp_next_id
    printf 'fish-%s-%s' $fish_pid (date +%s)
end

function hollow_htp_send_raw
    set -l json $argv[1]
    printf '\e]1337;Hollow;%s\e\\' $json > /dev/tty
end

function hollow_htp_emit
    set -l name $argv[1]
    set -l payload_json '{}'
    if test (count $argv) -ge 2
        set payload_json $argv[2]
    end
    set -l id (hollow_htp_next_id)
    hollow_htp_send_raw "{\"kind\":\"event\",\"id\":\"$id\",\"name\":\"$(hollow_htp_json_escape $name)\",\"payload\":$payload_json}"
end

function hollow_htp_emit_cwd
    set -l cwd $PWD
    if test (count $argv) -ge 1
        set cwd $argv[1]
    end
    hollow_htp_emit cwd_changed "{\"cwd\":\"$(hollow_htp_json_escape $cwd)\"}"
end

function hollow_htp_transport
    if test -n "$HOLLOW_REQUEST_DIR"; and test "$HOLLOW_TRANSPORT" != "osc"
        printf 'ipc\n'
    else
        printf 'osc\n'
    end
end

function hollow_htp_read_frame
    set -l timeout 1.5
    if test (count $argv) -ge 1
        set timeout $argv[1]
    end

    python3 - "$timeout" <<'PY'
import sys
import os
import select
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
        b = os.read(fd, 1)
        if not b:
            break
        data += b
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
end

function hollow_htp_query_once
    set -l name $argv[1]
    set -l params_json '{}'
    if test (count $argv) -ge 2
        set params_json $argv[2]
    end
    set -l timeout 1.5
    if test (count $argv) -ge 3
        set timeout $argv[3]
    end
    python3 "$HOLLOW_HTP_DIR/hollow-query.py" "$name" "$params_json" "$timeout" --id-prefix fish
end

# Examples:
#   source ./examples/htp/hollow-htp.fish
#   hollow_htp_emit_cwd
#   hollow_htp_query_once current_tab
