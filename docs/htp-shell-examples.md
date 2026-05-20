# HTP Shell Integration

The primary shipped HTP frontend is `hollow-cli`, with `hollow cli` as
the native command path.

These lower-level examples still ship for shell integration and transport
debugging when you want to work with raw HTP frames directly.

On the Lua side, the matching API is `hollow.htp`; see
`hollow-lua-api.md` for the handler reference.

## What Ships Today

The runtime includes built-in HTP query channels such as:

- `pane`
- `current_pane`
- `tab`
- `current_tab`
- `tabs`
- `panes`
- `workspace`
- `workspaces`
- `current_workspace`
- `current_domain`
- `echo`

The runtime includes built-in HTP emit channels such as:

- `close_pane`
- `focus_pane`
- `resize_pane`
- `send_text`
- `split_pane`
- `new_tab`
- `close_tab`
- `focus_tab`
- `next_tab`
- `prev_tab`
- `set_tab_title`
- `new_workspace`
- `close_workspace`
- `next_workspace`
- `prev_workspace`
- `switch_workspace`
- `set_workspace_name`
- `toggle_pane_maximized`
- `set_pane_floating`
- `set_floating_pane_bounds`
- `move_pane`
- `reload_config`
- `set_theme`
- `scroll`

You can also register your own channels from Lua with `hollow.htp.on_query(...)`
and `hollow.htp.on_emit(...)`.

## Transport Behavior

These shell helpers use OSC over the active tty.

- shells can force OSC with `HOLLOW_TRANSPORT=osc`
- `hollow-cli` and `hollow cli` are separate host-side command clients and do not use this OSC helper path

## `hollow-cli`

Typical usage:

```bash
hollow-cli get current-pane
hollow-cli get workspaces
hollow-cli workspace new --cwd /repo --name repo
hollow-cli tab rename editor --index 1
hollow-cli pane split vertical --cmd "npm run dev"
hollow-cli send-keys "{Up}{Enter}"
hollow-cli focus left
hollow-cli scroll page-down
hollow-cli config reload
hollow-cli get htp echo '{"value":42}'
hollow-cli emit notify '{"text":"done"}'
```

Output defaults:

- `get ...` prints JSON payloads
- mutating commands are silent on success
- `--quiet` suppresses success output
- `--pretty` pretty-prints JSON
- `--envelope` prints the full HTP reply envelope

## Helper Files

- `examples/htp/hollow-htp.bash`
- `examples/htp/hollow-htp.zsh`
- `examples/htp/hollow-htp.fish`
- `examples/htp/Hollow.Htp.ps1`
- `examples/htp/hollow-query`

What the helpers provide:

- send raw JSON envelopes with `...;Hollow;<json>ST`
- emit HTP channels handled by `hollow.htp.on_emit(...)`
- optionally wait for the host reply or error reply
- issue one-shot queries through `examples/htp/hollow-query`

## Shell Examples

Bash:

```bash
source ./examples/htp/hollow-htp.bash
hollow_htp_emit_checked "split_pane" '{"floating":true}'
hollow_htp_transport
hollow_htp_query_once "current_pane"
```

Zsh:

```zsh
source ./examples/htp/hollow-htp.zsh
hollow_htp_emit_checked split_pane '{"floating":true}'
hollow_htp_transport
hollow_htp_query_once current_workspace
```

Fish:

```fish
source ./examples/htp/hollow-htp.fish
hollow_htp_emit_checked split_pane '{"floating":true}'
hollow_htp_transport
hollow_htp_query_once current_tab
```

PowerShell:

```powershell
. ./examples/htp/Hollow.Htp.ps1
Send-HollowHtpCwdChanged
Invoke-HollowHtpQueryOnce -Name current_pane
```

The Bash, zsh, and fish helpers call `examples/htp/hollow-query`, a
tty-owning query helper in the style of kitty's query-terminal flow.

## Notes

- `hollow-cli` is the preferred user-facing interface.
- Bash, zsh, and fish examples use the bundled shell query helper for raw OSC transport flows.
- `hollow_htp_emit(...)` is fire-and-forget; use `hollow_htp_emit_checked(...)` if you want to see the host reply.
- HTP emit channels are separate from built-in Lua events like `term:cwd_changed`; they only do something when Hollow has a matching `hollow.htp.on_emit("channel", handler)`.
- Shell OSC helpers are tty-only and do not use host-side request directories.
- For WSL environment propagation, Hollow injects `WSLENV` so `HOLLOW_TRANSPORT` and `HOLLOW_PANE_ID` cross with `/u`.
- `*_query_once` reads the next host reply frame and prints the raw JSON.
- Small replies usually arrive as a single `result` message.
- Large replies may arrive as one or more `chunk` envelopes; the helper reassembles them before printing the final JSON response.
- The intended transport is direct OSC query/reply over the active tty. While the helper runs, it briefly owns terminal I/O to wait for the matching response.
- These helpers are intended as portable examples for WSL, SSH, and native shells where no host-side executable is available.
- PowerShell event sending works, but reply capture is still marked TODO in `examples/htp/Hollow.Htp.ps1`.
