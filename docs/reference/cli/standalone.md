# Standalone Zig `hollow-cli`

`hollow-cli` is the same implementation as `hollow cli`, without the GUI,
terminal engine, fonts, Lua runtime, or agent RPC. Both entry points share
`src/native_cli.zig`, typed commands, validation, targeting, and transport code.

```sh
hollow-cli pane split vertical --ratio 0.3
hollow-cli api call pane_split '{"direction":"vertical","ratio":0.3}'
hollow-cli api list
hollow-cli --pretty capabilities
```

Friendly syntax remains the normal human-facing interface. Generic `api call`
is an additional automation interface, not a replacement.

[External events and completion waits](events.md) provide pane-scoped event reads,
NDJSON watches, and command/process/status waits through the same CLI.

[Background jobs](jobs.md) combine no-focus launch, returned IDs, process waits,
bounded retained output, and ownership-checked cleanup.

## Build and install

```sh
# Dependency-free build graph, also used for agents:
zig build --build-file build-agent.zig cli -Doptimize=ReleaseSafe
zig build --build-file build-agent.zig cli-all -Doptimize=ReleaseSafe
zig build --build-file build-agent.zig test-cli

# Same steps are available through the main build:
zig build cli
```

`cli` installs the selected-target executable under `zig-out/bin/`. `cli-all`
packages static Linux x86_64 and aarch64 binaries under
`zig-out/cli/linux-<arch>/hollow-cli`, with a separate `cli/SHA256SUMS` manifest.
Normal installation builds both the selected-target CLI and guest bundles.

Linux agents embed their architecture-matched CLI in their shell-integration
bundle. It is installed on the guest shell's PATH automatically, alongside the
existing shell integration. The agent checksum covers the embedded binary; no
second download/deployment protocol or Python installation is required.

The Python script remains at `scripts/hollow-cli`; release and guest shell
bundles retain it as `hollow-cli.py`. Use `python3 /path/to/hollow-cli.py ...` for an older host or an
unmigrated workflow. Do not remove it based only on fake-host transport tests.

## Transports

`--transport auto|socket|file|osc` is available on both entry points.

- **Socket:** Uses `HOLLOW_COMMAND_ADDR`, or the existing local address file.
  Accepts numeric TCP endpoints and `unix:/absolute/socket/path` (for forwarded
  SSH sockets). No tty needed. This remains the preferred automation transport.
- **File:** Uses `HOLLOW_REQUEST_DIR` and the legacy request/reply file envelope.
  The directory must already exist and have a compatible request-file consumer.
  This change does not add a file-watching service to Hollow. Request publication
  is atomic; owned request/reply files are removed on completion or timeout.
- **OSC:** Uses `/dev/tty`, falling back to `/dev/fd/2`. Requires a readable POSIX
  tty, including for mutations because the new bridge acknowledges requests.
  Replies are correlated, chunked messages are bounded, and terminal settings
  are restored on success and errors. Windows binaries use socket/file instead.

Auto tries socket first. Only connection failure permits falling back to the
configured file transport, or otherwise OSC. **After connecting or publishing a
request, failure or timeout never replays it on another transport.** Socket
connection establishment currently uses the OS timeout; `--timeout` bounds frame
exchange, file waiting, or OSC exchange, not TCP connection establishment.

`HOLLOW_PANE_ID` populates invocation metadata on every transport. It is not an
authorization credential and is separate from explicit target `id` fields.
Friendly commands still perform their documented active-pane/tag resolution.

File/OSC wrap the native command envelope in the HTP query `command_api`.
The host parses and validates it with the same command contract as socket
requests. Native results/errors are nested inside the HTP result and unwrapped
by the client. This requires a host built with the bridge; older hosts should use
socket transport or the retained Python client.

Screenshot exports, event reads/watches, completion waits, and blocking
`wait_revision` calls require socket transport.
The bridge returns `unsupported_transport` rather than blocking the frame thread
or claiming unsupported work succeeded. Queued mutations acknowledge acceptance,
not operation or shell-command completion.

Socket forwarding/access controls are unchanged. OSC is not an authenticated
channel, and file directories must be private to the session owner. This is not a
new remote listener or arbitrary Lua execution endpoint.

## Validation scope

`test-cli` tests contracts and real loopback sockets, plus the built executable
against fake TCP/Unix/file hosts and a real PTY pair. It checks shared friendly/raw
requests, errors, chunking, request correlation, terminal restoration, and no
replay after disconnect. These checks do not establish live GUI, SSH, ARM64
runtime, or all legacy Python command-line compatibility.
