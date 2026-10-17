#!/usr/bin/env python3
"""Reusable PR1/PR2 conformance runner for hollow-agent v1."""
from __future__ import annotations

import argparse
import base64
import json
import os
import queue
import select
import shutil
import signal
import struct
import subprocess
import sys
import threading
import time
import unittest
import uuid

from agent_connectors import ConnectorError, LocalSubprocess, Podman, SSH, WSL

HEADER = struct.Struct("<IBBQQ")
HELLO, HELLO_ACK, REQUEST, RESPONSE, ERROR, DATA, CANCEL, PING, PONG, WINDOW_UPDATE = range(1, 11)
MAX_FRAME = 1 << 20
MAX_DATA = 16 << 10


def frame(kind, request_id=0, stream_id=0, payload=b""):
    if len(payload) > MAX_FRAME or (kind == DATA and len(payload) > MAX_DATA):
        raise ValueError("frame payload exceeds protocol limit")
    return HEADER.pack(len(payload), kind, 0, request_id, stream_id) + payload


class ProtocolError(RuntimeError):
    pass


class AgentClient:
    """One connection. A reader demultiplexes concurrent RPCs by request id."""
    def __init__(self, connection, timeout=10):
        self.connection, self.timeout = connection, timeout
        self.process = connection.process
        self.next_id = 1
        self.next_stream = 2
        self.lock = threading.Lock()
        self.write_lock = threading.RLock()
        os.set_blocking(self.process.stdin.fileno(), False)
        self.pending: dict[int, queue.Queue] = {}
        self.dead: BaseException | None = None
        self.reader = threading.Thread(target=self._reader, daemon=True)
        self.reader.start()

    def _read_exact(self, count):
        result = bytearray()
        fd = self.process.stdout.fileno()
        deadline = time.monotonic() + self.timeout
        while len(result) < count:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([fd], [], [], remaining)[0]:
                raise TimeoutError("agent response timed out")
            part = os.read(fd, count - len(result))
            if not part:
                raise EOFError(f"agent disconnected after {len(result)}/{count} bytes")
            result.extend(part)
        return bytes(result)

    def _recv(self):
        raw = self._read_exact(HEADER.size)
        length, kind, flags, rid, sid = HEADER.unpack(raw)
        if flags or length > MAX_FRAME or kind not in range(HELLO, WINDOW_UPDATE + 1):
            raise ProtocolError(f"invalid frame header kind={kind} flags={flags} length={length}")
        if kind == DATA and length > MAX_DATA:
            raise ProtocolError(f"DATA too large: {length}")
        return kind, rid, sid, self._read_exact(length)

    def _reader(self):
        try:
            while True:
                item = self._recv()
                with self.lock:
                    target = self.pending.get(item[1])
                if target is None:
                    raise ProtocolError(f"unsolicited response request_id={item[1]}")
                target.put(item)
        except BaseException as exc:
            with self.lock:
                self.dead = exc
                targets = list(self.pending.values())
            for target in targets:
                target.put(exc)

    def send(self, kind, request_id=0, stream_id=0, payload=b""):
        encoded = frame(kind, request_id, stream_id, payload)
        fd = self.process.stdin.fileno()
        view = memoryview(encoded)
        deadline = time.monotonic() + self.timeout
        with self.write_lock:
            while view:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not select.select([], [fd], [], remaining)[1]:
                    raise TimeoutError("agent write timed out")
                try:
                    written = os.write(fd, view)
                except BlockingIOError:
                    continue
                view = view[written:]

    def start(self):
        item = self.hello()
        kind, rid, sid, body = item
        if (kind, rid, sid) != (HELLO_ACK, 0, 0):
            raise ProtocolError(f"expected HELLO_ACK, got {item[:3]}")
        return json.loads(body)

    def _await_control(self):
        # HELLO and control tests have no request ID, so briefly read via a
        # dedicated queue installed before sending by start_control().
        q = self.pending.setdefault(0, queue.Queue())
        item = q.get(timeout=self.timeout)
        if isinstance(item, BaseException):
            raise item
        return item

    def hello(self, payload=b'{"major":1,"minor":0}'):
        self.pending[0] = queue.Queue()
        self.send(HELLO, payload=payload)
        return self._await_control()

    def allocate_streams(self):
        with self.lock:
            result = (self.next_stream, self.next_stream + 2)
            self.next_stream += 4
            return result

    def request(self, op, fields=None, *, stream_ids=(), timeout=None, cap=None):
        if op == "FS_READ" and not stream_ids:
            stream_ids = (0,)
        body = json.dumps({"op": op, **(fields or {})}, separators=(",", ":")).encode()
        # Assign and send under one writer lock: monotonic IDs must also arrive
        # monotonically when several test threads submit requests together.
        with self.write_lock:
            with self.lock:
                if self.dead:
                    raise self.dead
                rid = self.next_id
                self.next_id += 1
                q = queue.Queue()
                self.pending[rid] = q
            self.send(REQUEST, rid, payload=body)
        try:
            deadline = time.monotonic() + (timeout or self.timeout)
            streams = set(stream_ids)
            output = {sid: bytearray() for sid in streams}
            while True:
                left = deadline - time.monotonic()
                if left <= 0:
                    raise TimeoutError(f"request {rid} timed out")
                item = q.get(timeout=left)
                if isinstance(item, BaseException):
                    raise item
                kind, got, sid, payload = item
                if got != rid:
                    raise ProtocolError(f"request demux mismatch: {got} != {rid}")
                if kind == DATA:
                    if sid not in output:
                        raise ProtocolError(f"unexpected DATA stream {sid}")
                    output[sid].extend(payload)
                    if cap is not None and sum(map(len, output.values())) > cap:
                        raise ProtocolError("agent exceeded output cap")
                    continue
                if kind not in (RESPONSE, ERROR):
                    raise ProtocolError(f"unexpected response kind {kind}")
                return kind, json.loads(payload), output
        finally:
            with self.lock:
                self.pending.pop(rid, None)

    def ping(self):
        q = queue.Queue()
        self.pending[0] = q
        self.send(PING)
        item = q.get(timeout=self.timeout)
        if isinstance(item, BaseException):
            raise item
        return item

    def cancel(self, rid):
        self.send(CANCEL, rid)

    def close(self):
        self.connection.close()


def b64(value: bytes) -> str:
    return base64.b64encode(value).decode("ascii")


def unb64(value: str) -> bytes:
    return base64.b64decode(value, validate=True)


class Conformance(unittest.TestCase):
    connector: object

    def setUp(self):
        self.connection = self.connector.connect()
        self.client = AgentClient(self.connection)
        self.addCleanup(self.client.close)
        self.client.start()
        self.root = b"/tmp/hollow-agent-conformance-" + uuid.uuid4().hex.encode()
        self.exec([b"/bin/mkdir", b"-p", self.root])

    def tearDown(self):
        try:
            self.exec([b"/bin/rm", b"-rf", self.root], timeout=3)
        except Exception:
            pass
        self.client.close()

    def exec(self, argv, *, cwd=None, env=(), timeout=5000, output_limit=65536, shell_streams=False):
        out, err = self.client.allocate_streams()
        fields = {"argv_b64": list(map(b64, argv)), "env_b64": [
            {"key_b64": b64(k), "value_b64": b64(v)} for k, v in env],
            "timeout_ms": timeout, "output_limit": output_limit,
            "stdout_stream_id": out, "stderr_stream_id": err}
        if cwd is not None:
            fields["cwd_b64"] = b64(cwd)
        return self.client.request("EXEC", fields, stream_ids=(out, err), timeout=max(10, timeout / 1000 + 5), cap=output_limit)

    def test_fs_byte_paths_stat_list_read_and_pagination(self):
        path = self.root + b"/odd-\xff"
        self.exec([b"/bin/sh", b"-c", b"printf 'abc\\000def' > \"$1\"", b"fixture", path])
        kind, st, _ = self.client.request("FS_STAT", {"path_b64": b64(path)})
        self.assertEqual(kind, RESPONSE, st)
        self.assertEqual(st.get("size"), 7)
        kind, listing, _ = self.client.request("FS_LIST", {"path_b64": b64(self.root), "offset": 0, "limit": 1})
        self.assertEqual(kind, RESPONSE, listing)
        self.assertIn(b"odd-\xff", [unb64(e["name_b64"]) for e in listing["entries"]])
        kind, read, data = self.client.request("FS_READ", {"path_b64": b64(path), "offset": 0, "limit": 32})
        self.assertEqual(kind, RESPONSE, read)
        self.assertEqual(b"".join(data.values()), b"abc\0def")
        self.assertTrue(read["eof"])
        kind, tail, tail_data = self.client.request("FS_READ", {"path_b64": b64(path), "offset": 7, "limit": 8})
        self.assertEqual(kind, RESPONSE, tail)
        self.assertEqual(b"".join(tail_data.values()), b"")
        self.assertTrue(tail["eof"])

    def test_fs_non_utf8_symlink_missing_and_unsupported_fifo(self):
        path = self.root + b"/name-\xfe"
        self.exec([b"/bin/sh", b"-c", b": > \"$1\"; ln -s \"$1\" \"$1-link\"; mkfifo \"$1-fifo\"", b"fixture", path])
        for p in (path, path + b"-link"):
            kind, data, _ = self.client.request("FS_STAT", {"path_b64": b64(p)})
            self.assertEqual(kind, RESPONSE, data)
            self.assertEqual(data["kind"], "symlink" if p.endswith(b"-link") else "file")
        kind, missing, _ = self.client.request("FS_STAT", {"path_b64": b64(self.root + b"/absent")})
        self.assertEqual(kind, ERROR)
        kind, fifo, _ = self.client.request("FS_READ", {"path_b64": b64(path + b"-fifo"), "offset": 0, "limit": 10})
        self.assertEqual(kind, ERROR, fifo)

    def test_exec_exact_argv_cwd_env_and_shell_separated_streams(self):
        # First call proves argv is direct (metacharacters stay literal).
        literal = b"x;$(touch nope)\xff"
        kind, result, data = self.exec([b"printf", b"%s", literal], cwd=self.root)
        self.assertEqual(kind, RESPONSE, result)
        self.assertEqual(bytes(data[min(data)]), literal)
        # Shell used only as explicit fixture to generate both streams and cwd.
        kind, result, data = self.exec([b"/bin/sh", b"-c", b"printf '%s:%s' \"$VALUE\" \"$PWD\"; printf err >&2"],
                                       cwd=self.root, env=[(b"VALUE", b"v;\xff")])
        self.assertEqual(kind, RESPONSE, result)
        self.assertEqual(bytes(data[self.client.next_stream - 4]), b"v;\xff:" + self.root)
        self.assertEqual(bytes(data[self.client.next_stream - 2]), b"err")
        self.assertEqual(result["stdout_bytes"], len(data[self.client.next_stream - 4]))
        kind, status, _ = self.exec([b"/bin/sh", b"-c", b"exit 7"])
        self.assertEqual(kind, RESPONSE)
        self.assertEqual(status["exit_code"], 7)

    def test_long_exec_does_not_block_fs_or_ping_and_ids_are_unique(self):
        result = []
        thread = threading.Thread(target=lambda: result.append(self.exec([b"/bin/sleep", b"1"])))
        thread.start()
        time.sleep(.1)
        self.assertEqual(self.client.ping()[0], PONG)
        self.assertEqual(self.client.request("FS_STAT", {"path_b64": b64(self.root)})[0], RESPONSE)
        thread.join(5)
        self.assertFalse(thread.is_alive())
        self.assertEqual(result[0][0], RESPONSE)

    def test_timeout_cancel_output_limit_and_child_group_cleanup(self):
        kind, timeout, _ = self.exec([b"/bin/sh", b"-c", b"trap '' TERM; sleep 30 & wait"], timeout=250)
        self.assertEqual(kind, ERROR, timeout)
        self.assertEqual(timeout["code"], "timeout")
        self.assertTrue(timeout["truncated"])
        kind, limited, _ = self.exec([b"/bin/sh", b"-c", b"while :; do printf 1234567890; done"], output_limit=4096, timeout=5000)
        self.assertEqual(kind, ERROR, limited)
        self.assertEqual(limited["code"], "output_limit")
        self.assertTrue(limited["truncated"])

    def test_explicit_cancel_terminates_exec(self):
        result = []
        worker = threading.Thread(target=lambda: result.append(self.exec(
            [b"/bin/sh", b"-c", b"trap '' TERM; sleep 30 & wait"], timeout=30000)))
        worker.start()
        deadline = time.monotonic() + 3
        while self.client.next_id < 3 and time.monotonic() < deadline:
            time.sleep(.01)
        rid = self.client.next_id - 1
        time.sleep(.1)
        self.client.cancel(rid)
        worker.join(5)
        self.assertFalse(worker.is_alive())
        self.assertEqual(result[0][0], ERROR)
        self.assertEqual(result[0][1]["code"], "cancelled")

    def test_exec_rejects_nul_and_invalid_environment(self):
        kind, result, _ = self.exec([b"printf", b"%s", b"bad\0arg"])
        self.assertEqual((kind, result["code"]), (ERROR, "invalid_argv"))
        kind, result, _ = self.exec([b"true"], env=[(b"BAD=KEY", b"value")])
        self.assertEqual((kind, result["code"]), (ERROR, "invalid_argv"))
        kind, result, _ = self.exec([b"hollow-definitely-not-a-command"])
        self.assertEqual((kind, result["code"]), (ERROR, "not_found"))
        self.assertEqual(self.client.ping()[0], PONG)

    def test_large_binary_output_and_repeated_queue_drain(self):
        # More than the global queue size over one persistent connection catches
        # failure to reclaim already-written frame prefixes.
        for _ in range(6):
            kind, result, data = self.exec([b"/bin/sh", b"-c", b"exec dd if=/dev/zero bs=65536 count=16 2>/dev/null"], output_limit=1048576)
            self.assertEqual(kind, RESPONSE, result)
            self.assertEqual(len(data[min(data)]), 1048576)
            self.assertFalse(any(data[min(data)]))
            self.assertEqual(result["stdout_bytes"], 1048576)

    def test_natural_exit_cleans_remaining_process_group(self):
        # Explicit backgrounding is not a persistent-process API. Leader exits
        # naturally; the agent must still clean redirected descendants.
        kind, result, data = self.exec([b"/bin/sh", b"-c", b"sleep 30 </dev/null >/dev/null 2>&1 & printf '%s' $!"])
        self.assertEqual(kind, RESPONSE, result)
        pid = bytes(data[min(data)])
        self.assertTrue(pid.isdigit())
        kind, result, _ = self.exec([b"kill", b"-0", pid])
        self.assertEqual(kind, RESPONSE, result)
        self.assertNotEqual(result["exit_code"], 0, "background child outlived completed connection-scoped job")

    def test_directory_pages_cover_all_names(self):
        self.exec([b"/bin/sh", b"-c", b"i=0; while [ $i -lt 300 ]; do : > \"$1/file-$i\"; i=$((i+1)); done", b"fixture", self.root])
        names = []
        for offset in range(0, 350, 50):
            kind, result, _ = self.client.request("FS_LIST", {"path_b64": b64(self.root), "offset": offset, "limit": 50})
            self.assertEqual(kind, RESPONSE, result)
            names.extend(unb64(entry["name_b64"]) for entry in result["entries"])
        self.assertEqual(set(names), {f"file-{i}".encode() for i in range(300)})
        self.assertEqual(len(names), 300)

    def test_invalid_request_shapes_do_not_crash_connection(self):
        for op, fields in (("FS_STAT", {}), ("FS_STAT", {"path_b64": 2}),
                           ("FS_STAT", {"path_b64": "%%%"}), ("FS_STAT", {"path_b64": b64(b"a\0b")}),
                           ("FS_READ", {"path_b64": b64(b"/tmp"), "offset": -1}),
                           ("FS_READ", {"path_b64": b64(b"/tmp"), "limit": 10**100})):
            kind, _, _ = self.client.request(op, fields)
            self.assertEqual(kind, ERROR)
            self.assertEqual(self.client.ping()[0], PONG)

    def test_eof_cleanup_and_reconnect(self):
        # Terminate transport while child is active; new generation gets fresh IDs.
        disconnected = []
        def request_until_disconnect():
            try:
                self.exec([b"/bin/sh", b"-c", b"sleep 30 & wait"], timeout=30000)
            except (EOFError, BrokenPipeError, OSError) as exc:
                disconnected.append(exc)
        work = threading.Thread(target=request_until_disconnect)
        work.start()
        time.sleep(.2)
        self.connection.process.stdin.close()
        self.connection.process.wait(timeout=5)
        work.join(5)
        self.assertFalse(work.is_alive())
        self.assertTrue(disconnected, "in-flight request did not fail on disconnect")
        self.client.close()
        conn = self.connector.connect()
        client = AgentClient(conn)
        try:
            self.assertIsInstance(client.start(), dict)
            self.assertEqual(client.ping()[0], PONG)
        finally:
            client.close()


class WireConformance(unittest.TestCase):
    """Raw-wire checks which cannot use the already-HELLO fixture."""
    connector: object

    def fresh(self):
        connection = self.connector.connect()
        return connection, AgentClient(connection)

    def test_hello_version_mismatch_is_fatal(self):
        conn, client = self.fresh()
        try:
            item = client.hello(b'{"major":99,"minor":0}')
            self.assertIn(item[0], (ERROR,))
            self.assertEqual(json.loads(item[3])["code"], "protocol_mismatch")
        finally:
            client.close()

    def test_fragmented_hello_header_and_payload(self):
        conn, client = self.fresh()
        try:
            encoded = frame(HELLO, payload=b'{"major":1,"minor":0}')
            client.pending[0] = queue.Queue()
            fd = client.process.stdin.fileno()
            for byte in encoded:
                os.write(fd, bytes((byte,)))
                time.sleep(.0002)
            item = client._await_control()
            self.assertEqual(item[0], HELLO_ACK)
        finally:
            client.close()

    def test_invalid_headers_are_fatal(self):
        for kind, flags, length in ((77, 0, 0), (PING, 1, 0), (PING, 0, MAX_FRAME + 1), (DATA, 0, MAX_DATA + 1)):
            conn, client = self.fresh()
            try:
                client.start()
                raw = HEADER.pack(length, kind, flags, 0, 0)
                os.write(client.process.stdin.fileno(), raw)
                client.reader.join(3)
                self.assertFalse(client.reader.is_alive(), "agent did not reject invalid frame")
                self.assertIsNotNone(client.dead)
            finally:
                client.close()

    def test_negotiated_limits_and_connection_nonce(self):
        conn, client = self.fresh()
        try:
            item = client.hello(b'{"major":1,"minor":0,"max_payload":4096,"max_data":1024,"max_streams":2,"max_in_flight":1}')
            self.assertEqual(item[0], HELLO_ACK)
            hello = json.loads(item[3])
            self.assertEqual((hello["max_data"], hello["max_streams"], hello["max_exec"]), (1024, 2, 1))
            self.assertEqual(len(hello["connection_nonce"]), 32)
            streams = client.allocate_streams()
            kind, result, data = client.request("EXEC", {"argv_b64": list(map(b64, [b"dd", b"if=/dev/zero", b"bs=4096", b"count=1"])),
                "stdout_stream_id": streams[0], "stderr_stream_id": streams[1]}, stream_ids=streams)
            self.assertEqual(kind, RESPONSE, result)
            self.assertEqual(len(data[streams[0]]), 4096)
            nonce = hello["connection_nonce"]
        finally:
            client.close()
        conn, client = self.fresh()
        try:
            self.assertNotEqual(client.start()["connection_nonce"], nonce)
        finally:
            client.close()


class PodmanDeploymentConformance(unittest.TestCase):
    """Fault injection only against this harness's own disposable container."""
    connector: Podman

    def test_corrupt_cached_binary_is_replaced_without_breaking_live_agent(self):
        target = self.connector.deploy()
        client = AgentClient(self.connector.connect())
        try:
            client.start()
            # Replace the pathname, not the live inode. This is a deliberate
            # deployment fault, confined to a disposable test container.
            import shlex
            broken = target + ".fault-" + uuid.uuid4().hex
            self.connector._run(["exec", self.connector.container, "/bin/sh", "-c",
                f"printf broken > {shlex.quote(broken)} && mv {shlex.quote(broken)} {shlex.quote(target)}"])
            self.assertEqual(client.ping()[0], PONG)
            replacement = AgentClient(self.connector.connect())
            try:
                self.assertIsInstance(replacement.start(), dict)
            finally:
                replacement.close()
        finally:
            client.close()

    def test_restart_disconnects_old_generation_and_allows_reconnect(self):
        client = AgentClient(self.connector.connect())
        try:
            nonce = client.start()["connection_nonce"]
            self.connector._run(["restart", "--time", "1", self.connector.container])
            client.reader.join(5)
            self.assertFalse(client.reader.is_alive())
            self.assertIsNotNone(client.dead)
        finally:
            client.close()
        client = AgentClient(self.connector.connect())
        try:
            self.assertNotEqual(client.start()["connection_nonce"], nonce)
        finally:
            client.close()

    def test_container_recreation_reinstalls_agent(self):
        self.connector.deploy()
        name = self.connector.container
        self.connector._run(["rm", "--force", name])
        self.connector._run(["run", "--detach", "--name", name, "--entrypoint", "/bin/sh",
                             self.connector.image, "-c", "while :; do sleep 3600; done"])
        client = AgentClient(self.connector.connect())
        try:
            self.assertIsInstance(client.start(), dict)
        finally:
            client.close()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--connector", choices=("local-subprocess", "podman", "wsl", "ssh"), required=True)
    parser.add_argument("--agent", help="local agent binary (required for local-subprocess and Podman)")
    parser.add_argument("--image", default="docker.io/library/alpine:3.21")
    parser.add_argument("--container")
    parser.add_argument("--keep-container", action="store_true")
    parser.add_argument("--agent-path", help="preinstalled absolute Linux agent path inside Podman, WSL, or SSH host")
    parser.add_argument("--distro", help="existing WSL distribution (required for WSL)")
    parser.add_argument("--wsl-user", help="optional Linux user for WSL")
    parser.add_argument("--wsl", default="wsl.exe", help="native WSL launcher executable (default: wsl.exe)")
    parser.add_argument("--destination", help="SSH destination alias, DNS name, or IPv6 address")
    parser.add_argument("--port", type=int, help="SSH port")
    parser.add_argument("--ssh-user", help="optional SSH user")
    parser.add_argument("--identity-file", help="optional SSH private identity file")
    parser.add_argument("--known-hosts", help="optional SSH known-hosts file")
    parser.add_argument("--ssh-config", help="optional SSH client config file")
    parser.add_argument("--ssh", default="ssh", help="native SSH executable (default: ssh)")
    args = parser.parse_args(argv)
    if args.connector in ("local-subprocess", "podman") and not args.agent:
        parser.error("--agent is required for local-subprocess and Podman connectors")
    if args.connector == "wsl" and not args.distro:
        parser.error("--distro is required for WSL")
    if args.connector == "wsl" and not args.agent_path:
        parser.error("--agent-path is required for WSL preinstalled agent")
    if args.connector == "ssh" and not args.agent_path:
        parser.error("--agent-path is required for SSH preinstalled agent")
    if args.connector == "ssh" and not args.destination:
        parser.error("--destination is required for SSH")
    if args.connector == "podman" and args.image.rsplit(":", 1)[-1] == "latest":
        parser.error("--image must use pinned, non-latest tag")
    if args.connector == "local-subprocess":
        connector = LocalSubprocess(args.agent)
    elif args.connector == "podman":
        connector = Podman(args.agent, args.image, args.container, args.keep_container, agent_path=args.agent_path)
    elif args.connector == "wsl":
        connector = WSL(args.agent_path, args.distro, args.wsl_user, args.wsl)
    else:
        connector = SSH(args.agent_path, args.destination, args.port, args.ssh_user,
                        args.identity_file, args.known_hosts, args.ssh_config, args.ssh)
    if args.connector == "podman":
        try:
            if not shutil.which("podman"):
                print("SKIP: Podman unavailable", file=sys.stderr)
                return 2
            probe = subprocess.run(["podman", "info", "--format", "{{.Host.Security.Rootless}}"], capture_output=True, timeout=15)
            if probe.returncode or probe.stdout.strip().lower() != b"true":
                print("SKIP: rootless Podman unavailable", file=sys.stderr)
                return 2
        except Exception as exc:
            print(f"SKIP: Podman unavailable: {exc}", file=sys.stderr)
            return 2
    Conformance.connector = WireConformance.connector = connector
    suite = unittest.TestSuite()
    suite.addTests(unittest.defaultTestLoader.loadTestsFromTestCase(Conformance))
    suite.addTests(unittest.defaultTestLoader.loadTestsFromTestCase(WireConformance))
    if args.connector == "podman" and not args.container and not args.agent_path:
        PodmanDeploymentConformance.connector = connector
        suite.addTests(unittest.defaultTestLoader.loadTestsFromTestCase(PodmanDeploymentConformance))
    try:
        result = unittest.TextTestRunner(verbosity=2).run(suite)
        return 0 if result.wasSuccessful() else 1
    except ConnectorError as exc:
        print(f"NOT VERIFIED: {exc}", file=sys.stderr)
        return 2
    finally:
        close = getattr(connector, "close", None)
        if close:
            close()


if __name__ == "__main__":
    raise SystemExit(main())
