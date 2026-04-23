# HTP Shell Integration

These examples let a shell or script talk directly to Hollow over the shipped
HTP transport without depending on a separate host-side `hollow` CLI.

On the Lua side, the matching API is `hollow.htp`; see
`hollow-lua-api.md` for the handler reference.

## At A Glance

- Audience: users wiring shells or scripts into Hollow
- Main purpose: query or control the host from the active shell session
- Companion reference: [hollow-lua-api.md](hollow-lua-api.md)

## Use This Page To

- understand the shipped HTP helpers and transport model
- send queries and emits from Bash, zsh, fish, or PowerShell
- connect shell-side helpers to `hollow.htp` handlers in Lua

## What Ships Today

The runtime already includes built-in HTP query channels for:

- `pane`
- `current_pane`
- `current_tab`
- `tabs`
- `workspaces`
- `current_workspace`
- `echo`

The runtime already includes built-in HTP emit channels for:

- `split_pane`
- `toggle_pane_maximized`
- `set_pane_floating`
- `set_floating_pane_bounds`
- `move_pane`

You can also register your own channels from Lua with `hollow.htp.on_query(...)`
and `hollow.htp.on_emit(...)`.

## Transport Behavior

Transport selection is swappable:

- local shells prefer file transport via `HOLLOW_REQUEST_DIR`
- shells can force OSC with `HOLLOW_TRANSPORT=osc`
- emits still use OSC directly

## Helper Files

- `examples/htp/hollow-htp.bash`
- `examples/htp/hollow-htp.zsh`
- `examples/htp/hollow-htp.fish`
- `examples/htp/Hollow.Htp.ps1`
- `examples/htp/hollow-query.py`

What the helpers provide:

- send raw JSON envelopes with `...;Hollow;<json>ST`
- emit HTP channels handled by `hollow.htp.on_emit(...)`
- optionally wait for the host `event_ack` or error reply
- issue one-shot queries through `examples/htp/hollow-query.py`

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

The Bash, zsh, and fish helpers call `examples/htp/hollow-query.py`, a
tty-owning query helper in the style of kitty's query-terminal flow.

## Notes

- Bash, zsh, and fish use the bundled Python query helper.
- The helper prefers local file transport when `HOLLOW_REQUEST_DIR` is present, otherwise it falls back to OSC.
- `hollow_htp_emit(...)` is fire-and-forget; use `hollow_htp_emit_checked(...)` if you want to see the host reply.
- HTP emit channels are separate from built-in Lua events like `term:cwd_changed`; they only do something when Hollow has a matching `hollow.htp.on_emit("channel", handler)`.
- In `auto` mode, if file transport fails, the helper falls back to OSC queries.
- If you force `HOLLOW_TRANSPORT=file`, file transport failures are surfaced directly instead of falling back.
- For WSL environment propagation, Hollow injects `WSLENV` so `HOLLOW_TRANSPORT` and `HOLLOW_PANE_ID` cross with `/u`, while `HOLLOW_REQUEST_DIR` crosses as a translated path with `/p`.
- If those vars are still absent in WSL, the Python helper also tries to discover the shared request directory under `/mnt/c/Users/*/AppData/Local/hollow/htp-requests`.
- `*_query_once` reads the next host reply frame and prints the raw JSON.
- Small replies usually arrive as a single `result` message.
- Large replies may arrive as one or more `chunk` envelopes; the Python helper reassembles them before printing the final JSON response.
- The intended transport is direct OSC query/reply over the active tty. While the helper runs, it briefly owns terminal I/O to wait for the matching response.
- In WSL, the helper translates the reply path to a Windows path with `wslpath -w` so the Windows-hosted Hollow process can write it.
- These helpers are intended as portable examples for WSL, SSH, and native shells where no host-side executable is available.
- PowerShell event sending works, but reply capture is still marked TODO in `examples/htp/Hollow.Htp.ps1`.
