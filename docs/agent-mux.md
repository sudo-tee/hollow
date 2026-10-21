# Sharing a connection between panes

Normally, Hollow starts a separate background helper for each WSL or remote
pane. Mux lets compatible panes share one helper instead. Your panes still
work separately: each has its own shell, working folder, and running programs.

**Mux is optional and experimental.** You do not need to enable it to use
multiple panes. The usual one-helper-per-pane setup remains the default.

## Should I try it?

Try mux if you want fewer background helpers when using several panes on the
same host. Current Windows/WSL measurements show similar throughput and CPU
with much lower helper memory use. It is a practical option for that workload,
not a promise of better performance on every host.

If your current setup works well, there is no need to change it.

## Turn it on

Add `pty = { mode = "mux" }` to an existing agent-backed domain in your
[personal config](configuration.md#config-layers). For example, if you use
the automatically created `UbuntuWSL` domain:

```lua
hollow.config.set({
  domains = {
    UbuntuWSL = {
      pty = { mode = "mux" },
    },
  },
})
```

Replace `UbuntuWSL` with your domain's name. Keep your existing shell and host
settings. Reload your config with `<leader>uu`, then open new panes in that
domain. Already-open panes are unchanged.

The setting applies to agent-backed WSL, SSH, and container domains. It does not
change native PowerShell or Command Prompt panes, or domains with `host = false`.
Performance and lifecycle checks described below cover WSL, not all connectors.
You do not need to tune reader or batch settings to try it.

## What changes when panes share a helper?

- You use each pane as usual. Closing one does not normally close the others.
- Compatible panes on the same host can share a helper. Different hosts or
  connection settings may still need separate helpers.
- Closing the last pane using a helper shuts that helper down.
- If a shared connection fails, several panes may stop together. Open new
  panes to reconnect. Hollow will not restart your commands automatically.
- This is not session persistence: closing Hollow does not preserve these
  sessions for later attachment. Detach/reattach is future work.

## What did our tests show?

In our October 21 four-pane Windows/WSL comparison, using the current mux
read-ahead fix and the same executable for both modes:

| Measurement | Default setup | Mux |
| --- | ---: | ---: |
| Background agent helpers | 4 | 1 |
| Memory used by those helpers, sampled | 3.38 MiB | 0.72 MiB |
| Uncapped producer-admitted output, median | 41.27 MiB/s | 42.08 MiB/s |
| Loaded Windows CPU, including captured helpers | 1.251 cores | 1.232 cores |
| Loaded ACK observation p50 | 9.32 ms | 9.05 ms |
| Loaded ACK observation p99 | 17.55 ms | 15.79 ms |

That was about **79% less helper memory**, not 79% less memory for Hollow as a
whole. Both modes sustained 10 MiB/s offered load in the three qualified
capped pairs. The CPU row includes captured Windows helpers, not shared WSL/VM
services or Linux processes; 1.0 cores means one fully occupied logical CPU.

Four uncapped and four loaded-echo pairs completed. Output speed varied, and
occasional maximum ACK latency was higher with mux despite its lower p99 in
each pair. One capped pair was excluded because its dedicated producer missed
the matched-load tolerance. ACK observation includes command IPC and text
queries, not keyboard-to-display latency; output speed is not screen refresh
rate. These results support mux as an option, not exact parity or a universal
speedup. See the [current head-to-head report](windows-mux-cpu.md#current-mux-versus-dedicated-pty-head-to-head-october-21-2026)
for paired variation and exclusions.

We also ran a ten-minute WSL test while opening, resizing, switching between,
and closing panes. It completed 18 open/close cycles without a crash, and the
helper's sampled memory stayed steady. That is a useful check, not a promise
that every machine or remote connection will behave the same way.

## Switch back

Change the domain's setting to:

```lua
pty = { mode = "dedicated" },
```

Reload your config, then open new panes. Existing panes keep their current
setup until you close them. You do not need to uninstall anything.

## More information

- [WSL setup](platforms/wsl.md#shared-terminal-connections)
- [All mux settings](reference/lua/config.md#experimental-shared-terminal-connections)
- [Current Windows/WSL performance report](windows-mux-cpu.md)
- [Detailed tests and developer notes](agent-mux-development.md)
