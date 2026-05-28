# Hollow Shell Integration for Fish
# Only activate if running inside Hollow
if test -z "$HOLLOW_PANE_ID"
    exit 0
end

if set -q _HOLLOW_FISH_INTEGRATION_LOADED
    exit 0
end

set -g _HOLLOW_FISH_INTEGRATION_LOADED 1

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
    printf '\033]1337;Hollow;%s\033\\' "$argv[1]" >/dev/tty
end

function hollow_htp_emit
    set -l name $argv[1]
    set -l payload_json $argv[2]
    test -z "$payload_json" && set payload_json "{}"

    set -l id "fish-"(echo %self)"-"(date +%s%N)
    set -l escaped_name (hollow_htp_json_escape $name)
    hollow_htp_send_raw "{\"kind\":\"event\",\"id\":\"$id\",\"name\":\"$escaped_name\",\"payload\":$payload_json}"
end

function __hollow_tty_print
    printf '%s' "$argv[1]" >/dev/tty
end

function __hollow_osc7
    printf '\e]7;file://%s%s\e\\' (hostname) $PWD >/dev/tty
end

set -g __hollow_prompt_open 0
set -g __hollow_has_right_prompt 0

function __hollow_prompt_begin
    if test "$__hollow_prompt_open" != 1
        set -g __hollow_prompt_open 1
        __hollow_tty_print "\e]133;A;cl=line\a"
    end
end

function __hollow_prompt_end
    if test "$__hollow_prompt_open" = 1
        set -g __hollow_prompt_open 0
        __hollow_tty_print "\e]133;B\a"
    end
end

function __hollow_wrap_prompts
    if functions -q fish_right_prompt; and not functions -q __hollow_orig_fish_right_prompt
        functions -c fish_right_prompt __hollow_orig_fish_right_prompt
        set -g __hollow_has_right_prompt 1

        function fish_right_prompt
            __hollow_prompt_begin
            __hollow_orig_fish_right_prompt
            __hollow_prompt_end
        end
    else if functions -q __hollow_orig_fish_right_prompt
        set -g __hollow_has_right_prompt 1
    else
        set -g __hollow_has_right_prompt 0
    end

    if functions -q fish_mode_prompt; and not functions -q __hollow_orig_fish_mode_prompt
        functions -c fish_mode_prompt __hollow_orig_fish_mode_prompt

        function fish_mode_prompt
            __hollow_prompt_begin
            __hollow_orig_fish_mode_prompt
        end
    end

    if functions -q fish_prompt; and not functions -q __hollow_orig_fish_prompt
        functions -c fish_prompt __hollow_orig_fish_prompt

        function fish_prompt
            __hollow_prompt_begin
            __hollow_orig_fish_prompt
            if test "$__hollow_has_right_prompt" != 1
                __hollow_prompt_end
            end
        end
    end
end

function __hollow_setup_prompt_wrappers --on-event fish_prompt
    functions -e __hollow_setup_prompt_wrappers
    __hollow_wrap_prompts
end

__hollow_wrap_prompts

# Report CWD on directory change
function __hollow_report_cwd --on-variable PWD
    __hollow_osc7
end

function __hollow_preexec --on-event fish_preexec
    set -g __hollow_prompt_open 0
    __hollow_tty_print "\e]133;C\a"
    set -l escaped_cmd (hollow_htp_json_escape $argv[1])
    hollow_htp_emit "command_started" "{\"command\":\"$escaped_cmd\"}"
end

function __hollow_postexec --on-event fish_postexec
    __hollow_tty_print (string join '' "\e]133;D;" $status "\a")
    hollow_htp_emit "command_ended" "{\"exit_code\":$status}"
    __hollow_osc7
end

# Initial CWD report
__hollow_osc7
