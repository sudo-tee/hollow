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

function hollow_htp_emit_checked
    set -l name $argv[1]
    set -l payload_json '{}'
    if test (count $argv) -ge 2
        set payload_json $argv[2]
    end
    set -l timeout 1.5
    if test (count $argv) -ge 3
        set timeout $argv[3]
    end
    set -l id (hollow_htp_next_id)
    hollow_htp_send_raw "{\"kind\":\"event\",\"id\":\"$id\",\"name\":\"$(hollow_htp_json_escape $name)\",\"payload\":$payload_json}"
    hollow_htp_read_frame $timeout
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
    # Delegate to hollow-query's OSC reader via a throwaway query that reads a raw frame.
    # For a standalone frame reader, use sh + stty directly.
    set -l tmp (mktemp)
    set -l tty_dev /dev/tty
    set -l saved_tty (stty -g <$tty_dev 2>/dev/null)
    stty raw -echo <$tty_dev 2>/dev/null
    set -l max_iter (math "$timeout * 200 + 200" | string replace -r '\..*' '')
    set -l iter 0
    set -l found 0
    while test $iter -lt $max_iter
        dd bs=1 count=1 <$tty_dev >>$tmp 2>/dev/null
        set -l tail (tail -c 2 $tmp | od -An -tx1 | tr -d ' \n')
        if test "$tail" = "1b5c"
            set found 1
            break
        end
        set iter (math $iter + 1)
    end
    if test -n "$saved_tty"
        stty $saved_tty <$tty_dev 2>/dev/null; or stty sane <$tty_dev 2>/dev/null
    else
        stty sane <$tty_dev 2>/dev/null
    end
    if test $found -eq 1
        set -l hex (od -An -tx1 $tmp | tr -d ' \n')
        set -l prefix_hex "1b5d313333373b486f6c6c6f773b"
        set -l after (string replace --regex ".*$prefix_hex" '' -- $hex)
        set -l payload_hex (string replace --regex "1b5c\$" '' -- $after)
        rm -f $tmp
        if command -q xxd
            printf '%s\n' (printf '%s' $payload_hex | xxd -r -p)
        else
            printf '%s' $payload_hex | python3 -c \
                "import sys,binascii; sys.stdout.buffer.write(binascii.unhexlify(sys.stdin.read().strip()))"
            printf '\n'
        end
        return 0
    end
    rm -f $tmp
    printf 'hollow_htp_read_frame: timed out\n' >&2
    return 1
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
    sh "$HOLLOW_HTP_DIR/hollow-query" "$name" "$params_json" "$timeout" --id-prefix fish
end

# Examples:
#   source ./examples/htp/hollow-htp.fish
#   hollow_htp_emit_checked split_pane '{"floating":true}'
#   hollow_htp_query_once current_tab
