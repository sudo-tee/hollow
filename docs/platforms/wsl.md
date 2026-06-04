# WSL

WSL is Hollow's first-class shell domain.
Hollow itself is a Windows app; the WSL shell is launched from the
Windows host, optionally through a Linux-side helper that skips
ConPTY.

For the broader Windows setup see [Windows](windows.md).
For the bypass helper protocol see
[`src/pty/wsl_bypass_protocol.zig`](../../src/pty/wsl_bypass_protocol.zig).

## How WSL panes launch

When you create a pane in the `wsl` domain (or any `{distro}WSL` domain
populated by `populate_wsl_domains()`), the runtime picks one of two
backends:

1. **`wsl_bypass`** — the Linux-side helper, if installed. Spawns
   `wsl.exe` and a Linux-side PTY relay that talks to Hollow via APC
   frames. Skips ConPTY entirely.
2. **ConPTY** — the default fallback. Works on every Windows host that
   has WSL installed, no helper required.

The runtime tries `wsl_bypass` first and falls back to ConPTY if the
helper is missing or fails to start. The fallback is silent — you only
see it as a `wsl bypass unavailable, falling back to ConPTY` line in
`hollow.log`.

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
hollow.config.set({ default_domain = "wsl" })
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

## Bypass helper

The bypass helper is a small Linux-side binary Hollow spawns inside
the WSL distro.
Without it, WSL still works — it just goes through ConPTY.
With it, you get lower latency and avoid the extra ConPTY layer.

### Install from a source checkout

```bash
zig build install-wsl-bypass
```

That target builds `hollow-wsl-bypass` and installs it to
`/usr/local/bin/hollow-wsl-bypass` inside the default WSL distro.

### Install from a release bundle

```bash
wsl sh -lc 'sudo install -d -m 755 /usr/local/bin && \
  sudo install -m 755 /mnt/c/path/to/hollow/wsl/hollow-wsl-bypass \
  /usr/local/bin/hollow-wsl-bypass'
```

### Requirements

- `/usr/local/bin` must be on the WSL shell `PATH`
- Hollow must launch WSL through `wsl.exe` as usual
- The default distro must have a user Hollow can `wsl.exe -u <user>` into

If you do nothing, WSL panes still work — they just use ConPTY.

## WSL workflow patterns

### Linux-first on a Windows host

Use `wsl` as the default domain. Most shell, toolchain, and SSH setup
lives in Linux; Hollow remains a Windows desktop app.

```lua
hollow.config.set({ default_domain = "wsl" })
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

If you want the workspace switcher to find projects under a WSL path
but launch them as Linux-side cwds, use a `wsl_unc` `cwd_resolver`:

```lua
hollow.ui.workspace.configure({
  sources = {
    {
      name = "Ubuntu",
      resolver = "local",   -- not "wsl": we want to read Windows UNC paths
      domain = "wsl",
      cwd_resolver = "wsl_unc",
      roots = {
        "\\\\wsl$\\Ubuntu\\home\\me\\Projects",
      },
    },
  },
})
```

`wsl_unc` translates `\\wsl$\Ubuntu\home\me\Projects\foo` to
`/home/me/Projects/foo` so the launched shell starts in the right
place.

## Environment propagation

Hollow injects `HOLLOW_PANE_ID` and `HOLLOW_TRANSPORT` into every
guest session.
For WSL domains, Hollow also configures `WSLENV` so these variables
cross the Windows/WSL boundary with `/u` (UTF-8 propagation).

You can read them from inside WSL:

```bash
echo "$HOLLOW_PANE_ID $HOLLOW_TRANSPORT"
```

## Troubleshooting

| Problem | Fix |
| --- | --- |
| `wsl.exe not found` | Install WSL with `wsl --install` from elevated PowerShell |
| Bypass helper does not activate | Install `hollow-wsl-bypass` into WSL `PATH` with `zig build install-wsl-bypass`; otherwise Hollow uses ConPTY |
| Wrong distro launches | Set the `wsl_distro` field on the domain or use the `{distro}WSL` domains populated by `populate_wsl_domains()` |
| `cwd` reports a Windows path inside WSL | Use `cwd_resolver = "wsl_unc"` in the workspace source, or pass a Linux `cwd` to `new_tab`/`split_pane` |

## See also

- [Windows](windows.md) — base Windows host setup
- [`hollow.config` → WSL domains](../reference/lua/config.md#wsl-domains)
- [`hollow.ui.workspace`](../reference/lua/workspace.md) — workspace
  discovery, including `wsl_unc`
- [HTP and WSL](../shell-integration.md#wsl-environment-propagation)
