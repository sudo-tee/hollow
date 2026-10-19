#!/usr/bin/env python3
"""Experimental interactive agent PTY client. Never changes Hollow's PTY backend.

Use --connector-argv JSON for podman exec -i / wsl.exe --exec / ssh -T transports.
The peer must explicitly negotiate experimental.pty; this is not a rollout switch.
"""
import argparse
import base64
import json
import os
import queue
import select
import signal
import struct
import subprocess
import sys

from agent_connectors import LocalSubprocess, ProcessConnection
from agent_conformance import AgentClient, DATA, ERROR, HELLO_ACK, REQUEST, RESPONSE, WINDOW_UPDATE, b64


class PtySession:
    def __init__(self, client, rid, stream, events):
        self.client, self.id, self.stream, self.events = client, rid, stream, events
        self.done = False

    def receive(self, timeout=5):
        event = self.events.get(timeout=timeout)
        if isinstance(event, BaseException):
            raise event
        kind, rid, sid, payload = event
        if kind == DATA:
            if sid != self.stream:
                raise RuntimeError("unexpected PTY output stream")
            return kind, payload
        if kind not in (RESPONSE, ERROR):
            raise RuntimeError("unexpected PTY event")
        self.done = True
        with self.client.lock:
            self.client.pending.pop(self.id, None)
        return kind, json.loads(payload)

    def grant(self, amount):
        self.client.send(WINDOW_UPDATE, self.id, self.stream, struct.pack("<Q", amount))

    def input(self, data):
        return self.client.request("PTY_INPUT", {"session_id": self.id, "bytes_b64": b64(data)})

    def resize(self, rows, cols):
        return self.client.request("PTY_RESIZE", {"session_id": self.id, "rows": rows, "cols": cols})

    def close(self):
        return self.client.request("PTY_CLOSE", {"session_id": self.id})


class PtyClient(AgentClient):
    def start(self, *, focus=False):
        kind, rid, sid, payload = self.hello(json.dumps({"major": 1, "minor": 0, "experimental_pty": True,
                                                        "experimental_focus": focus}).encode())
        hello = json.loads(payload)
        if kind != HELLO_ACK or "experimental.pty" not in hello.get("capabilities", []):
            raise RuntimeError("peer did not negotiate experimental PTY support")
        if focus and "experimental.focus" not in hello.get("capabilities", []):
            raise RuntimeError("peer did not negotiate experimental focus support")
        self.focus_generation = hello["connection_nonce"]
        self.focus_negotiated = focus
        return hello

    def focus(self, sequence, logical_session, stream=0):
        return self.request("FOCUS_UPDATE", {"generation": self.focus_generation, "sequence": sequence,
                                             "active_session_id": logical_session, "active_stream_id": stream})

    def spawn(self, argv, *, rows=24, cols=80, credit=65536, env=(), cwd=None, timeout_ms=30000,
              logical_session=None):
        if self.focus_negotiated and logical_session is None:
            raise ValueError("negotiated focus requires explicit logical_session")
        out, err = self.allocate_streams()
        body = {"op": "PTY_SPAWN", "argv_b64": [b64(os.fsencode(arg)) for arg in argv],
                "stdout_stream_id": out, "stderr_stream_id": err, "rows": rows, "cols": cols,
                "output_credit": credit, "timeout_ms": timeout_ms,
                "env_b64": [{"key_b64": b64(os.fsencode(k)), "value_b64": b64(os.fsencode(v))} for k, v in env]}
        if cwd is not None:
            body["cwd_b64"] = b64(os.fsencode(cwd))
        if logical_session is not None:
            body["logical_session_id"] = logical_session
        events = queue.Queue()
        with self.write_lock:
            with self.lock:
                if self.dead:
                    raise self.dead
                rid = self.next_id
                self.next_id += 1
                self.pending[rid] = events
            self.send(REQUEST, rid, payload=json.dumps(body, separators=(",", ":")).encode())
        return PtySession(self, rid, out, events)


def main():
    import fcntl
    import termios
    import tty
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--agent", default="zig-out/bin/hollow-agent")
    parser.add_argument("--connector-argv", help="exact JSON argv for an existing remote agent stdio transport")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        parser.error("interactive client requires terminal stdin/stdout; use agent_pty_tests.py for headless tests")
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    command = command or [os.environ.get("SHELL", "/bin/sh"), "-i"]
    if args.connector_argv:
        argv = json.loads(args.connector_argv)
        if not isinstance(argv, list) or not argv or not all(isinstance(a, str) and "\0" not in a for a in argv):
            parser.error("--connector-argv must be a nonempty JSON string array without NUL")
        connection = ProcessConnection(subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                                        stderr=subprocess.PIPE, bufsize=0, start_new_session=True))
    else:
        connection = LocalSubprocess(args.agent).connect()
    client = PtyClient(connection)
    saved = termios.tcgetattr(0)
    winch = [True]
    previous = signal.signal(signal.SIGWINCH, lambda *_: winch.__setitem__(0, True))
    try:
        client.start()
        size = os.get_terminal_size(0)
        session = client.spawn(command, rows=size.lines, cols=size.columns, timeout_ms=86400000,
                               env=[("TERM", os.environ.get("TERM", "xterm-256color"))])
        tty.setraw(0)
        pending_input = b""
        input_closed = False
        while True:
            if winch[0]:
                winch[0] = False
                rows, cols, _, _ = struct.unpack("HHHH", fcntl.ioctl(0, termios.TIOCGWINSZ, b"\0" * 8))
                if rows and cols:
                    session.resize(rows, cols)
            try:
                kind, payload = session.receive(timeout=0.01)
            except queue.Empty:
                kind = None
            if kind == DATA:
                view = memoryview(payload)
                while view:
                    view = view[os.write(1, view):]
                session.grant(len(payload))
            elif kind == RESPONSE:
                return payload["exit_code"]
            elif kind == ERROR:
                raise RuntimeError(payload)
            if not input_closed and not pending_input and select.select([0], [], [], 0)[0]:
                pending_input = os.read(0, 16384)
                if not pending_input:
                    input_closed = True
                    session.close()
            if pending_input:
                kind, result, _ = session.input(pending_input)
                if kind == RESPONSE:
                    pending_input = b""
                elif result.get("code") != "resource_exhausted":
                    raise RuntimeError(result)
    finally:
        termios.tcsetattr(0, termios.TCSANOW, saved)
        signal.signal(signal.SIGWINCH, previous)
        client.close()


if __name__ == "__main__":
    raise SystemExit(main())
