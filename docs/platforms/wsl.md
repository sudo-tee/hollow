# WSL

WSL is Hollow's first-class shell domain.
Hollow itself is a Windows app; WSL panes run through the bundled
Linux `hollow-agent`, which skips ConPTY, with a native `wsl.exe`
ConPTY launch as fallback.

For the broader Windows setup see [Windows](windows.md).
For the agent PTY protocol see
[`src/agent/pty_protocol.zig`](../../src/agent/pty_protocol.zig).

## How WSL panes launch

When you create a pane in the `wsl` domain (or any `{distro}WSL` domain
populated by `populate_wsl_domains()`), the runtime picks one of two
backends:

1. **Agent PTY** — Hollow bootstraps `hollow-agent` into the distro and
   by default runs `wsl.exe --distribution <distro> --cd / --exec <agent> pty`
   for each pane. Opt-in mux mode runs `<agent> mux` over a shared connector.
   Each pane still has its own real Linux PTY. Both modes skip ConPTY entirely.
2. **ConPTY** — the fallback. Launches the domain's `wsl.exe` shell
   through ConPTY. Works on every Windows host that has WSL installed.

The agent is used implicitly for domains with `wsl_distro`, or whose
shell is `wsl.exe -d <distro>` / `--distribution <distro>`. If bootstrap
or initial connection setup fails before shell submission, Hollow falls back
to ConPTY — you only see
`agent pty: ...` warnings in `hollow.log`. Set `host = false` on a domain
to always use ConPTY. See [Agent PTY](#agent-pty).

## Configuring the WSL domain

The shipped base config populates WSL domains with
`hollow.config.populate_wsl_domains()`:

```lua
if hollow.platform.is_windows then
  hollow.config.populate_wsl_domains()
end
```

This enumerates `wsl.exe -l` and creates one domain per distro named
`{distro}WSL`, plus a `wsl` domain that follows the default distro.

Make WSL the default:

```lua
hollow.config.set({ default_domain = "UbuntuWSL" })
```

Customize the WSL domain:

```lua
hollow.config.set({
  domains = {
    wsl = {
      shell = "C:\\Windows\\System32\\wsl.exe",
      default_cwd = "/home/me",
    },
  },
})
```

Address a specific distro:

```lua
hollow.term.new_tab({ domain = "UbuntuWSL" })
```

## Agent PTY

The agent PTY runs each pane through the static Linux `hollow-agent`
shipped in the release `agents/` bundle (see
[Packaging → Linux agents](../packaging.md#linux-agents)).
Compared with ConPTY you get full escape-sequence passthrough (images,
Sixel, Python `hollow-cli` over the tty), shell integration, Windows →
WSL cwd/path conversion, and resize.

- Bootstrap is automatic (see [Pane PTYs](../reference/lua/host.md#pane-ptys)):
  the bundle is found beside the exe, streamed into the distro user's
  cache over `wsl.exe` stdin when missing, and verified against
  `SHA256SUMS`. No manual install step. Later panes reuse the verified
  install.
- Each pane runs its own `wsl.exe ... --exec <agent> pty` process by default.
  Experimental [shared terminal connections](#shared-terminal-connections)
  let matching panes share an agent connector instead.
- Implicit WSL panes keep local semantics (PID and cwd tracking).
- [`term:spawn`](../reference/lua/events.md) filters do not apply.

To make the agent explicit (no ConPTY fallback; failures show a red
`[hollow] <message>` banner and the pane exits), or to pick a user:

```lua
hollow.config.set({
  domains = {
    UbuntuWSL = { host = { type = "wsl", distro = "Ubuntu", user = "me" } },
  },
})
```

During development, `zig build` places the agent bundle in
`zig-out/agents/`; `launch.sh --install` copies it beside the exe.

### Requirements

- `/bin/sh`, `uname`, `mktemp`, `sha256sum` inside the distro (for automatic deployment)
- A writable executable cache in the distro user's HOME
- The bundled `agents/` folder next to `hollow-native.exe`

If any of these are missing, implicit WSL panes still work — they just use ConPTY.

## Shared terminal connections

To try mux on an existing WSL domain, add `pty` in your personal config:

```lua
hollow.config.set({
  domains = {
    UbuntuWSL = {
      wsl_distro = "Ubuntu", -- replace with your installed distro
      pty = { mode = "mux" },
    },
  },
})
```

Reload your config, then open new panes in that domain. Panes can share one
background helper instead of starting a helper for each pane. Each pane still
has its own shell, working folder, and running programs.

If the shared helper disconnects, several panes may close together. Open new
panes to reconnect; Hollow will not restart your commands automatically.

Mux is experimental. The current four-pane Windows/WSL comparison found similar
throughput and helper-inclusive Windows CPU with about 79% lower Linux-helper
RSS; it is not a universal speedup. See the [current performance report](../windows-mux-cpu.md)
for variation and exclusions. Sharing does not keep sessions alive after Hollow
closes or provide detach/reattach. To switch back, set
`pty = { mode = "dedicated" }`, reload, and open new panes. Already-open panes
are unchanged. For settings and measured results, see
[the configuration reference](../reference/lua/config.md#experimental-shared-terminal-connections).

## WSL workflow patterns

### Linux-first on a Windows host

Use `wsl` as the default domain. Most shell, toolchain, and SSH setup
lives in Linux; Hollow remains a Windows desktop app.

```lua
hollow.config.set({ default_domain = "UbuntuWSL" })
```

### WSL-backed SSH

```lua
hollow.config.set({
  domains = {
    devbox = {
      ssh = {
        alias = "devbox",
        backend = "wsl",
        reuse = "auto",
      },
    },
  },
})
```

`backend = "wsl"` routes the SSH client through `wsl.exe`, which is
useful when you want Linux-side SSH config, agent behaviour, and
multiplexing. `reuse = "auto"` enables OpenSSH multiplexing flags for
WSL/Linux-backed SSH domains; native Windows OpenSSH falls back
safely.

See [`hollow.config` → SSH domains](../reference/lua/config.md#ssh-domains).

### WSL workspace discovery

Use a persistent agent host and Linux-native project paths:

```lua
hollow.ui.workspace.configure({
  sources = {
    {
      name = "Ubuntu",
      host = { type = "wsl", distro = "Ubuntu" },
      domain = "UbuntuWSL",
      roots = {
        "/home/me/Projects",
      },
    },
  },
})
```

The bundled agent auto-deploys into the selected distro user's cache. Scans reuse
one connection; terminal panes still use `UbuntuWSL`. Legacy UNC configurations
are converted in memory with a warning; update them using the example above.

## Environment propagation

Hollow injects `HOLLOW_PANE_ID` and `HOLLOW_TRANSPORT` into every
guest session.
It also injects `HOLLOW_COMMAND_ADDR`.
With WSL mirrored networking, `hollow-cli` uses this address for fast bidirectional commands without owning terminal input.
Under NAT networking, `hollow-cli` falls back to OSC.
For WSL domains, Hollow also configures `WSLENV` so these variables
cross the Windows/WSL boundary with `/u` (UTF-8 propagation).

You can read them from inside WSL:

```bash
echo "$HOLLOW_PANE_ID $HOLLOW_TRANSPORT"
```

## Mirrored networking

WSL 2 mirrored networking lets Linux processes connect to Windows loopback services through `127.0.0.1`.
This makes Hollow's command socket directly reachable from WSL, allowing `hollow-cli` queries and mutations without terminal I/O or a Windows process launch.

Create or update `%UserProfile%\.wslconfig` on Windows:

```ini
[wsl2]
networkingMode=mirrored
dnsTunneling=false
firewall=true
autoProxy=false
```

`dnsTunneling` is independent from loopback mirroring.
Enable it if required by your network, but it can add DNS latency on some systems.
`autoProxy` is also optional and should match the Windows proxy environment.

Apply the configuration from PowerShell:

```powershell
wsl --update
wsl --shutdown
```

Start a new WSL session and verify Hollow's inherited endpoint:

```bash
echo "$HOLLOW_COMMAND_ADDR"
nc -vz 127.0.0.1 "${HOLLOW_COMMAND_ADDR##*:}"
hollow-cli get mux-tree --pretty
```

Mirrored networking requires a recent WSL release on Windows 11 22H2 or newer.
Some VPN and endpoint-security products interfere with mirrored networking.
If that happens, return to NAT networking and let `hollow-cli` use its OSC fallback.

## Troubleshooting

| Problem                                 | Fix                                                                                                                                                                                                                     |
| --------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `wsl.exe not found`                     | Install WSL with `wsl --install` from elevated PowerShell                                                                                                                                                               |
| Agent PTY does not activate             | Check `hollow.log` for `agent pty: ...` warnings — the pane fell back to ConPTY. The `agents/` bundle must be alongside `hollow-native.exe`. During development, `zig build` places it in `zig-out/agents/`. |
| Wrong distro launches                   | Set the `wsl_distro` field on the domain or use the `{distro}WSL` domains populated by `populate_wsl_domains()`                                                                                                         |
| `cwd` reports a Windows path inside WSL | Use an agent-backed workspace source with Linux roots, or pass a Linux `cwd` to `new_tab`/`split_pane` |

## See also

- [Windows](windows.md) — base Windows host setup
- [`hollow.config` → WSL domains](../reference/lua/config.md#wsl-domains)
- [`hollow.ui.workspace`](../reference/lua/workspace.md) — workspace
  discovery, including `wsl_unc`
- [HTP and WSL](../htp-protocol.md#wsl-environment-propagation)
