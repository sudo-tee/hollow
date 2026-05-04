# Hollow Shell Integration for Fish
# Only activate if running inside Hollow
if test -z "$HOLLOW_PANE_ID"
    exit 0
end

function hollow_htp_json_escape
    set -l value $argv[1]
    set value (string replace -a '\\' '\\\\' $value)
    set value (string replace -a '"' '\\"' $value)
    set value (string replace -a \n '\\n' $value)
    set value (string replace -a \r '\\r' $value)
    set value (string replace -a \t '\\t' $value)
    echo -n $value
end

function hollow_htp_send_raw
    printf '\033]1337;Hollow;%s\033\\' $argv[1] >/dev/tty
end

function hollow_htp_emit
    set -l name $argv[1]
    set -l payload_json $argv[2]
    test -z "$payload_json" && set payload_json "{}"

    set -l id "fish-"(echo %self)"-"(date +%s%N)
    set -l escaped_name (hollow_htp_json_escape $name)
    hollow_htp_send_raw "{\"kind\":\"event\",\"id\":\"$id\",\"name\":\"$escaped_name\",\"payload\":$payload_json}"
end

function __hollow_osc7
    printf '\e]7;file://%s%s\e\\' (hostname) $PWD >/dev/tty
end

# Report CWD on directory change
function __hollow_report_cwd --on-variable PWD
    __hollow_osc7
end

function __hollow_preexec --on-event fish_preexec
    set -l escaped_cmd (hollow_htp_json_escape $argv[1])
    hollow_htp_emit "command_started" "{\"command\":\"$escaped_cmd\"}"
end

function __hollow_postexec --on-event fish_postexec
    # fish_postexec receives exit code as $argv[2]
    hollow_htp_emit "command_ended" "{\"exit_code\":$argv[2]}"
    __hollow_osc7
end

# Initial CWD report
__hollow_osc7
