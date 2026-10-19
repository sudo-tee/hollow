# Hollow Host Agent v1 — PR 0–2 RFC

Status: implemented initial contract for protocol/agent/Podman foundation. Scope is
read-only filesystem operations and bounded non-PTY exec. The agent is
connection-scoped; Hollow retains ownership of workspaces, panes, terminal
parsing and existing PTY backends. No PTY migration in these milestones.

## Ownership and rollout

Hollow owns host identity, connection generation, request dispatch and user
policy. Connector owns bootstrap/deployment and exposes an ordered binary byte
stream. Agent owns request execution, child lifecycle/reaping and response
buffers. One failed connection fails its in-flight requests once; reconnect
creates a new generation. Never replay ambiguous EXEC. Bound concurrency,
payloads, outputs, process count, filesystem page sizes and allocations; reject
resource exhaustion explicitly. Run commands as connector-selected target UID,
without privilege escalation. Logs go to stderr, never protocol stdout.

PR0 locks this RFC and reproduces legacy WSL PTY performance baselines before
any PTY implementation. PR1 implements Linux standalone agent and local
subprocess conformance. PR2 adds Podman binary deployment and persistent
`podman exec -i` transport; never allocate a TTY for fs/exec. Pane PTYs now run
`hollow-agent pty`, one connector process per pane (replacing the former WSL
bypass helper); a multiplexed shared transport is later work, gated on parity,
performance, backpressure and failure-isolation measurements.

## Frame

All frames are fixed 22-byte header followed by exactly `payload_length` bytes:

| Offset | Field | Encoding |
|---:|---|---|
| 0 | payload_length | u32 little-endian; max 1 MiB |
| 4 | kind | u8 |
| 5 | flags | u8, MUST be zero in v1 |
| 6 | request_id | u64 little-endian |
| 14 | stream_id | u64 little-endian |

Kinds: HELLO=1, HELLO_ACK=2, REQUEST=3, RESPONSE=4, ERROR_RESPONSE=5,
DATA=6, CANCEL=7, PING=8, PONG=9, WINDOW_UPDATE=10. Unknown kinds, nonzero
flags, lengths above 1 MiB, and DATA above 16 KiB are protocol errors. No
compression. Metadata is UTF-8 JSON; binary content is raw DATA, never JSON
byte escaping. Incremental parsers must tolerate arbitrary header/payload
fragmentation and must not allocate based on an unchecked length.

`stream_id=0` means control/non-streaming RPC. Client-created streams use even
nonzero IDs; server-created streams use odd nonzero IDs. IDs are never reused
within connection generation. Request IDs are unique nonzero values while
in-flight; zero is for uncorrelated events. Responses echo request ID.
Connection generation prevents stale replies attaching after reconnect.

WINDOW_UPDATE payload is exactly one positive u64 LE consumed-byte count;
header stream_id identifies credit recipient. Zero/incorrect-sized updates
are invalid. Credit means downstream consumer drained/accepted bytes, not merely
parser-buffered data. This semantic is locked now; full scheduling is future
work.

## Messages and operations

HELLO JSON advertises `{ "major": 1, "minor": 0 }`; HELLO_ACK selects supported
version/capabilities. Version mismatch is fatal and typed as
`protocol_mismatch`.

REQUEST payloads use JSON with `op`. V1 operations:

* `FS_LIST`: `path_b64`, `offset`, `limit`; response entries preserve names as
  `name_b64`. Pagination must be bounded and document that concurrent directory
  mutation can shift offset pages; it is not a snapshot.
* `FS_READ`: `path_b64`, `offset`, `limit`. Agent emits zero or more DATA frames
  with original request ID and stream_id 0, then RESPONSE JSON `{ "bytes": N,
  "eof": bool }`. Each DATA <=16 KiB; aggregate read bounded by requested and
  configured limits.
* `EXEC`: `argv_b64` (array), optional `cwd_b64`, `env_b64` array of
  `{key_b64,value_b64}`, `timeout_ms`, `output_limit`, and distinct even
  `stdout_stream_id`/`stderr_stream_id`. No shell interpretation. stdout and
  stderr are raw DATA on supplied streams. Final RESPONSE is
  `{ "exit_code": N, "stdout_bytes": N, "stderr_bytes": N }`. Nonzero exit is
  successful RPC result.

Paths, argv and environment are arbitrary bytes encoded base64; reject embedded
NUL for OS path/argv use and reject malformed/oversize input. Display strings
must never replace byte identity. FS_LIST pagination and FS_READ/EXEC outputs
are capped. Requests/responses are finite in v1; streams do not imply indefinite
jobs.

ERROR_RESPONSE JSON is `{ "code": ..., "message": ... }`. Stable codes include
`unsupported`, `not_found`, `permission_denied`, `invalid_path`, `invalid_argv`,
`timeout`, `cancelled`, `output_limit`, `resource_exhausted`,
`transport_disconnected`, `protocol_mismatch`, and `session_gone`.

CANCEL header request_id targets original request; payload is empty. Cancellation
and timeout terminate process group (SIGTERM, 1500 ms grace, then SIGKILL), reap
children and emit exactly one terminal error. Output-limit termination reports
`output_limit` and truncation; no DATA follows terminal result. Connection EOF
cancels outstanding work. Never leave jobs silently running. Per-job supervision
handles ordinary descendants after RPC-agent death; simultaneous supervisor
death and resource-control qualification remain separate gates.

## Limits, failures and deferred work

Initial absolute frame max 1 MiB, DATA max 16 KiB; implementation also caps
in-flight requests (256), streams (128), process count, queued bytes, per-op
output and directory page size. Reserve capacity for control/cancel traffic.
Failures are terminal and exactly-once; no mutation replay. The wire codec
does not provide authentication: connector transport must use trusted local
pipes/SSH host verification and verified agent deployment.

No PTY, PTY stream ownership, session persistence, daemon, filesystem write,
PTY flow scheduler, TCP listener, or Lua API is included in PR0–2. Existing PTY
path stays untouched. Future PTY work requires independent latency/throughput,
renderer responsiveness, bounded-memory/backpressure, fault-injection and
failure-isolation gates against reproducible legacy WSL measurements. Pane PTYs
currently use dedicated per-pane `hollow-agent pty` transports. A failed
shared multiplexing experiment does not block fs/exec; keep dedicated PTY
transports if measurements require it.

## Current implementation choices and remaining qualification

* The agent uses a single nonblocking `poll` loop, `signalfd` and a draining
  `waitpid(-1, WNOHANG)` loop. At most 16 worker jobs are live, below the protocol
  ceilings. Filesystem requests run in bounded worker processes so blocking
  filesystem syscalls cannot freeze RPC dispatch; operation handlers remain
  connector-independent. This is not the future PTY `epoll` scheduler.
* HELLO_ACK includes a fresh 128-bit `connection_nonce`. Clients must also keep
  their own connection generation and never replay ambiguous requests. V1
  requires **strictly increasing request IDs** and increasing allocated even
  stream IDs, advertised as `monotonic_ids`. This avoids unbounded ID-history
  storage. A late CANCEL is ignored, preventing duplicate completion.
* HELLO optionally requests `max_payload`, `max_data`, `max_streams` and
  `max_in_flight`. Limits are clamped to safety ceilings; minimum payload/DATA
  limits are 1024 bytes. At least two streams and one request are required.
  Stream/request limits can lower the concurrent-worker cap.
* `HOST_INFO` returns protocol, build, OS/arch, byte-valued home/cwd and limits.
  `FS_STAT` uses `lstat` semantics and returns kind, mode, size and mtime seconds.
  `FS_READ` follows symlinks, but rejects non-regular files. Stat/read require
  Linux `statx` (kernel >=4.11 and permitted by seccomp); unsupported kernels or
  policies return an error, not a different environment-specific handler.
* Directory pages contain at most 256 names; reads at most 16 KiB. Directory
  offsets scan at most 1,000,000 entries and are not snapshot cursors. FS_READ
  EOF reflects a best-effort size observation, not a transactional snapshot.
* EXEC inherits environment, applies byte-valued overrides and resolves argv[0]
  using the resulting PATH. There is no implicit shell fallback. Stdin is
  `/dev/null`. Timeout defaults to 30 seconds, must be 1–86,400,000 ms, and
  combined stdout/stderr capture defaults to, and cannot exceed, 1 MiB. Capture
  is delivered only after completion, not as a streaming process API.
* Cancellation/timeout/output-limit errors discard captured output and report
  `truncated: true`. Natural completion drains both pipes before completion.
  Surviving process-group members are terminated after leader exit, including
  children that redirected their output. Filesystem workers have a 30-second
  deadline and can be cancelled by request ID.
* Captures are bounded per worker, and the outbound queue is capped at 4 MiB.
  A peer that exhausts even reserved error capacity loses its connection after
  job cleanup. A non-draining stdout transport is disconnected after 10 seconds.
* Each EXEC has an unprivileged guardian, separate from its workload process
  group. The guardian blocks lifecycle signals into signalfd, subreaps adopted
  children and receives SIGTERM on agent death. It closes inherited RPC and
  other-job descriptors, escalates TERM to KILL after 1500 ms, and waits for
  `ECHILD` before exiting with the workload leader's exit code. Agent escalation
  uses SIGUSR2 to request forced cleanup, not to kill the guardian. Signals to
  adopted children use unreaped PID identities; a reaped leader's PGID is not
  reused for signaling. Local and rootless Podman gates cover grandchildren and
  detached double-fork descendants after SIGKILL and EOF. This is **not a security
  sandbox**, cgroup limit, or guarantee against simultaneous guardian death,
  malicious same-UID processes, OOM or uninterruptible kernel waits. Hang/OOM
  qualification and allocation-failure fuzzing remain release gates.

Additional typed codes used by these bounded primitives are `invalid_argument`
and `io_error`. Full per-stream credit scheduling, control-lane fairness and
PTY output ordering are not claimed by the finite fs/exec implementation.
