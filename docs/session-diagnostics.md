# Session diagnostics

Hollow traces ownership changes to diagnose unexpected session takeovers.
Tracing does not change ownership policy or enable automatic reclaim or retries.

## Log locations

The Windows GUI log is `%APPDATA%\hollow\hollow.log`.
The standalone Windows session owner writes `%LOCALAPPDATA%\hollow\session-owner.log`.
The WSL session owner writes `owner.log` in its session state directory.
See [persistent sessions](persistent-sessions-guide.md) for session directory configuration.
Collect both logs when investigating an unexpected takeover.

## Correlation fields

Log entries include a UTC timestamp, PID, process-instance ID, and scope.
Timestamps have millisecond precision; stack traces use a timestamped header.
An instance ID changes on process restart.
A connection ID distinguishes multiple connections from one process.
Build IDs fingerprint executables independently of upgrade negotiation.
A zero build fingerprint means fingerprint acquisition was unavailable.

Traces cover connection start, hello, readiness, and end.
They also cover request queueing, submission, and replies.
Connection end records the failure or local-close reason.
It includes last complete send/receive times as UTC Unix milliseconds.
High-frequency layout requests, keystrokes, and terminal output are not logged.

`session.takeover` identifies the creator, previous holder, and incoming client.
It includes their build IDs and the current owner's identity and build.
It also includes the incoming request ID and attach intent.
Intent is `open`, `restore`, `reclaim`, or `unknown`.
The displaced GUI receives the same ownership details in its `taken` event.
Creator identity survives supported in-place owner upgrades.
Older sessions or peers may have missing identities and unknown intent.
These are self-reported diagnostic identities, not authentication credentials.

`runtime.execution_gap` records GUI frame gaps of at least 30 seconds.
A gap can indicate sleep, a stalled process, or a wall-clock adjustment.
It is not proof of OS suspend.

## Investigating a takeover

Find `session.takeover` for the affected session and compare `previous` with `next`.
Different instance IDs indicate different process incarnations.
One instance with two connection IDs means one process connected twice.
Use connection and request IDs to find queue, submission, and reply traces.
Check the attach intent and nearby execution-gap and connection-end records.
Compare builds to identify an old client or owner participating in the transition.

Traces omit terminal contents, shell commands, and environment variables.
Peer identity fields are bounded and sanitized to prevent forged log lines.
