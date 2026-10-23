#!/usr/bin/env python3
"""Exercise the built CLI against fake socket/file/PTY hosts, without a GUI."""
import json
import base64
import os
import select
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest

CLI = str(Path(sys.argv.pop(1)).resolve())


def result(payload=None):
    return {"kind": "result", "status": "ok", "payload": payload}


class CliTests(unittest.TestCase):
    def env(self, **extra):
        env = dict(os.environ)
        for key in ("HOLLOW_COMMAND_ADDR", "HOLLOW_REQUEST_DIR", "HOLLOW_PANE_ID"):
            env.pop(key, None)
        env.update(extra)
        return env

    def run_cli(self, *args, env=None):
        return subprocess.run([CLI, *args], env=env or self.env(), capture_output=True,
                              text=True, timeout=5)

    def socket_call(self, args, response, unix=False):
        with tempfile.TemporaryDirectory() as root:
            listener = socket.socket(socket.AF_UNIX if unix else socket.AF_INET)
            address = str(Path(root) / "command.sock") if unix else ("127.0.0.1", 0)
            listener.bind(address)
            listener.listen(1)
            listener.settimeout(3)
            seen = []
            errors = []

            def serve():
                try:
                    for reply in response if isinstance(response, list) else [response]:
                        with listener.accept()[0] as client:
                            client.settimeout(3)
                            def read(n):
                                data = b""
                                while len(data) < n:
                                    chunk = client.recv(n - len(data))
                                    if not chunk:
                                        raise EOFError()
                                    data += chunk
                                return data
                            size, = struct.unpack("<I", read(4))
                            seen.append(json.loads(read(size)))
                            if isinstance(reply, bytes):
                                client.sendall(reply)
                            elif reply is not None:
                                payload = json.dumps(reply).encode()
                                client.sendall(struct.pack("<I", len(payload)) + payload)
                except Exception as error:
                    errors.append(error)

            worker = threading.Thread(target=serve)
            worker.start()
            addr = "unix:" + address if unix else "%s:%s" % listener.getsockname()
            try:
                process = self.run_cli(*args, env=self.env(HOLLOW_COMMAND_ADDR=addr, HOLLOW_PANE_ID="7"))
            finally:
                worker.join(4)
                listener.close()
            self.assertFalse(worker.is_alive())
            self.assertFalse(errors, errors)
            return process, seen

    def test_friendly_and_raw_commands_share_wire_contract(self):
        for args in (("pane", "split", "vertical", "--ratio", "0.3"),
                     ("api", "call", "pane_split", '{"direction":"vertical","ratio":0.3}')):
            process, seen = self.socket_call(args, result())
            self.assertEqual(process.returncode, 0, process.stderr)
            self.assertEqual(seen[0]["kind"], "pane_split")
            self.assertEqual(seen[0]["direction"], "vertical")
            self.assertEqual(seen[0]["ratio"], 0.3)
            self.assertEqual(seen[0]["ctx"]["pane_id"], 7)

    def test_unix_socket_and_query_output(self):
        process, seen = self.socket_call(("--transport", "socket", "get", "revision"), result({"revision": 5}), unix=True)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(json.loads(process.stdout), {"revision": 5})
        self.assertEqual(seen[0]["kind"], "get_revision")

    def test_errors_exit_nonzero(self):
        process, _ = self.socket_call(("api", "describe", "missing"),
                                     {"kind": "error", "status": "method_not_found", "error": "unknown command"})
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(json.loads(process.stderr)["code"], "method_not_found")

    def test_event_subscription_and_filtered_read(self):
        process, seen = self.socket_call(("events", "subscribe"), result({"cursor": 9, "capacity": 512}))
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(json.loads(process.stdout)["cursor"], 9)
        self.assertEqual(seen[0]["kind"], "events_subscribe")
        payload = {"cursor": 12, "events": []}
        process, seen = self.socket_call(("events", "read", "--after", "9", "--pane", "42", "--event", "status_changed"), result(payload))
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(json.loads(process.stdout), payload)
        self.assertEqual(seen[0]["after"], 9)
        self.assertEqual(seen[0]["id"], 42)
        self.assertEqual(seen[0]["event"], "status_changed")

    def test_completion_wait_returns_actual_event_including_failure_exit(self):
        event = {"sequence": 12, "kind": "command_finished", "pane_id": 42, "command_id": 10, "status": 7}
        process, seen = self.socket_call(("wait", "command", "--after", "9", "--pane", "42", "--command-id", "10"), result({"cursor": 12, "events": [event]}))
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(json.loads(process.stdout), event)
        self.assertEqual(seen[0]["command_id"], 10)
        self.assertEqual(seen[0]["event"], "command_finished")

    def test_event_overflow_is_not_completion(self):
        process, _ = self.socket_call(("wait", "process-exit", "--after", "0", "--pane", "42"),
                                     {"kind": "error", "status": "event_overflow", "error": "events lost"})
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(json.loads(process.stderr)["code"], "event_overflow")
        self.assertEqual(process.stdout, "")

    def test_event_wait_requires_barrier_and_explicit_pane(self):
        for args in (("wait", "command", "--pane", "42"), ("wait", "command", "--after", "0"),
                     ("events", "watch", "--after", "0", "--pretty")):
            process = self.run_cli(*args)
            self.assertEqual(process.returncode, 2, process.stderr)

    def test_background_spawn_distinguishes_shell_from_literal_argv(self):
        handle = {"pane_id": 42, "tab_id": 5, "workspace_id": 1,
                  "token": "0123456789abcdef0123456789abcdef", "cursor": 9}
        argv = ["demo", "--pretty", "--timeout", "--quiet", "--wait", "--auto-close", "--user-shell", "$HOME; & *", ""]
        process, seen = self.socket_call(("job", "spawn", "--cwd", "/work", "--", *argv), result(handle))
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(json.loads(process.stdout), handle)
        self.assertEqual(seen[0]["argv"], argv)
        self.assertEqual(seen[0]["kind"], "job_spawn")
        self.assertEqual(seen[0]["cwd"], "/work")
        self.assertIsNone(seen[0].get("cmd"))
        process, seen = self.socket_call(("job", "spawn", "--domain", "linux", "--shell", "build && test"), result(handle))
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(seen[0]["cmd"], "build && test")
        self.assertEqual(seen[0]["domain"], "linux")
        self.assertIsNone(seen[0].get("argv"))

    def test_spawn_user_shell_wait_returns_handle_and_completion(self):
        handle = {"pane_id": 42, "tab_id": 5, "workspace_id": 1,
                  "token": "0123456789abcdef0123456789abcdef", "cursor": 9}
        process, seen = self.socket_call(("job", "spawn", "--user-shell", "--wait", "--", "make", "test"), [
            result(handle), result({"pane_id": 42, "state": "exited", "status": 7, "cursor": 10}),
        ])
        self.assertEqual(process.returncode, 0, process.stderr)
        payload = json.loads(process.stdout)
        self.assertEqual(payload["token"], handle["token"])
        self.assertEqual(payload["tab_id"], 5)
        self.assertEqual(payload["status"], 7)
        self.assertEqual(payload["cursor"], 10)
        self.assertTrue(seen[0]["user_shell"])
        self.assertEqual(seen[0]["argv"], ["make", "test"])
        self.assertEqual([r["kind"] for r in seen], ["job_spawn", "job_get"])

    def test_spawn_wait_timeout_keeps_handle_and_never_closes(self):
        handle = {"pane_id": 42, "tab_id": 5, "workspace_id": 1,
                  "token": "0123456789abcdef0123456789abcdef", "cursor": 9}
        process, seen = self.socket_call(("--timeout", "0", "job", "spawn", "--wait", "--auto-close", "--", "make", "test"), [
            result(handle), result({"pane_id": 42, "state": "running", "cursor": 10}),
        ])
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(json.loads(process.stderr)["code"], "timeout")
        self.assertEqual(json.loads(process.stdout), handle)
        self.assertEqual([r["kind"] for r in seen], ["job_spawn", "job_get"])

    def test_spawn_wait_cleanup_failure_preserves_recovery_handle(self):
        handle = {"pane_id": 42, "tab_id": 5, "workspace_id": 1,
                  "token": "0123456789abcdef0123456789abcdef", "cursor": 9}
        process, seen = self.socket_call(("job", "spawn", "--wait", "--auto-close", "--", "true"), [
            result(handle), result({"pane_id": 42, "state": "exited", "status": 0, "cursor": 10}),
            {"kind": "error", "status": "job_running", "error": "output still draining"},
        ])
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(json.loads(process.stdout), handle)
        self.assertEqual(json.loads(process.stderr)["code"], "job_running")
        self.assertEqual(seen[-1]["kind"], "job_cleanup")

    def test_auto_close_only_after_completion_for_spawn_and_wait(self):
        handle = {"pane_id": 42, "tab_id": 5, "workspace_id": 1,
                  "token": "0123456789abcdef0123456789abcdef", "cursor": 9}
        completed = result({"pane_id": 42, "state": "exited", "status": 7, "cursor": 10})
        for args, responses in [
            (("job", "spawn", "--wait", "--auto-close", "--", "false"), [result(handle), completed, result()]),
            (("job", "wait", "--auto-close", "--id", "42", "--token", handle["token"]), [completed, result()]),
        ]:
            process, seen = self.socket_call(args, responses)
            self.assertEqual(process.returncode, 0, process.stderr)
            self.assertTrue(json.loads(process.stdout)["closed"])
            self.assertEqual(json.loads(process.stdout)["status"], 7)
            self.assertEqual(seen[-1]["kind"], "job_cleanup")
            self.assertEqual(seen[-1]["token"], handle["token"])

    def test_wait_flags_validate_before_launch(self):
        for args in [
            ("job", "spawn", "--auto-close", "--", "make"),
            ("--transport", "htp", "job", "spawn", "--wait", "--", "make"),
        ]:
            process = self.run_cli(*args)
            self.assertEqual(process.returncode, 2, process.stderr)
        process = self.run_cli("api", "call", "job_spawn", json.dumps({"argv": ["make"], "user_shell": "true"}))
        self.assertEqual(process.returncode, 2, process.stderr)

    def test_invalid_job_launches_rejected_without_host(self):
        for payload in ({}, {"argv": []}, {"argv": [""]}, {"argv": ["echo"], "cmd": "echo"},
                        {"argv": ["echo", "\x00"]}, {"cmd": "echo\x00"}, {"argv": ["echo"] * 257}):
            process = self.run_cli("api", "call", "job_spawn", json.dumps(payload))
            self.assertEqual(process.returncode, 2, process.stderr)
        for args in (("job", "spawn"), ("job", "spawn", "--"), ("job", "cleanup", "--id", "42")):
            process = self.run_cli(*args)
            self.assertEqual(process.returncode, 2, process.stderr)

    def test_job_wait_uses_retained_status_after_event_overflow(self):
        token = "0123456789abcdef0123456789abcdef"
        completed = {"pane_id": 42, "state": "exited", "status": 7, "cursor": 1000}
        process, seen = self.socket_call(("job", "wait", "--id", "42", "--token", token), [
            result({"pane_id": 42, "state": "running", "status": None, "cursor": 9}),
            {"kind": "error", "status": "event_overflow", "error": "lost"},
            result(completed),
        ])
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(json.loads(process.stdout), completed)
        self.assertEqual([request["kind"] for request in seen], ["job_get", "events_read", "job_get"])
        self.assertEqual(seen[0]["token"], token)
        self.assertEqual(seen[1]["id"], 42)
        self.assertEqual(seen[1]["event"], "process_exited")

    def test_job_timeout_never_cleans_up_or_relaunches(self):
        token = "0123456789abcdef0123456789abcdef"
        process, seen = self.socket_call(("--timeout", "0", "job", "wait", "--auto-close", "--id", "42", "--token", token),
                                         result({"pane_id": 42, "state": "running", "cursor": 9}))
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(json.loads(process.stderr)["code"], "timeout")
        self.assertEqual([request["kind"] for request in seen], ["job_get"])

    def test_job_output_preserves_binary_bytes_and_cleanup_reports_errors(self):
        token = "0123456789abcdef0123456789abcdef"
        raw = b"\xfffailure\x1b[31m\r\n"
        process, seen = self.socket_call(("job", "output", "--id", "42", "--token", token),
                                         result({"encoding": "base64", "data": base64.b64encode(raw).decode(), "truncated": True, "incomplete": False, "capacity_bytes": 1048576}))
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(base64.b64decode(json.loads(process.stdout)["data"]), raw)
        self.assertEqual(seen[0]["kind"], "job_output")
        process, seen = self.socket_call(("job", "cleanup", "--id", "42", "--token", token),
                                         {"kind": "error", "status": "job_running", "error": "still running"})
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(json.loads(process.stderr)["code"], "job_running")
        self.assertEqual(seen[0]["token"], token)

    def test_watch_emits_ndjson_and_resumes_from_returned_cursor(self):
        first = {"sequence": 11, "kind": "status_changed", "pane_id": 42}
        second = {"sequence": 12, "kind": "process_exited", "pane_id": 42, "status": 0}
        process, seen = self.socket_call(("events", "watch", "--after", "9", "--pane", "42"), [
            result({"cursor": 10, "events": []}),
            result({"cursor": 12, "events": [first, second]}),
            {"kind": "error", "status": "shutting_down", "error": "stopped"},
        ])
        self.assertEqual([json.loads(line) for line in process.stdout.splitlines()], [first, second])
        self.assertEqual([request["after"] for request in seen], [9, 10, 12])
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(json.loads(process.stderr)["code"], "shutting_down")

    def test_wait_retries_empty_reads_without_using_revision(self):
        event = {"sequence": 12, "kind": "status_changed", "pane_id": 42}
        process, seen = self.socket_call(("wait", "status-change", "--after", "9", "--pane", "42"), [
            result({"cursor": 10, "events": []}),
            result({"cursor": 12, "events": [event]}),
        ])
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(json.loads(process.stdout), event)
        self.assertEqual([request["after"] for request in seen], [9, 10])
        self.assertTrue(all(request["kind"] == "events_read" for request in seen))

    def test_auto_falls_back_before_send_to_file_bridge_and_cleans_up(self):
        with tempfile.TemporaryDirectory() as root:
            seen = []
            def serve():
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline:
                    requests = list(Path(root).glob("*.request.json"))
                    if requests:
                        request = json.loads(requests[0].read_text())
                        seen.append(request)
                        reply = Path(request["reply_file"])
                        temporary = reply.with_suffix(".tmp")
                        temporary.write_text(json.dumps(result(result({"revision": 9}))))
                        temporary.replace(reply)
                        return
                    time.sleep(.005)
            worker = threading.Thread(target=serve)
            worker.start()
            process = self.run_cli("--transport", "auto", "get", "revision",
                                   env=self.env(HOLLOW_REQUEST_DIR=root,
                                                HOLLOW_COMMAND_ADDR="unix:" + root + "/missing.sock"))
            worker.join(4)
            self.assertEqual(process.returncode, 0, process.stderr)
            self.assertEqual(json.loads(process.stdout), {"revision": 9})
            self.assertEqual(seen[0]["name"], "command_api")
            self.assertEqual(list(Path(root).iterdir()), [])

    def test_bad_arguments_do_not_need_a_host(self):
        process = self.run_cli("api", "call", "pane_split", '{"direction":"diagonal"}')
        self.assertEqual(process.returncode, 2, process.stderr)
        self.assertEqual(json.loads(process.stderr)["code"], "invalid_args")

    def test_disconnect_does_not_replay(self):
        process, seen = self.socket_call(("pane", "split", "vertical"), None)
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(len(seen), 1)
        self.assertIn("ConnectionClosed", json.loads(process.stderr)["error"])

    def test_truncated_reply_keeps_stderr_machine_readable(self):
        process, _ = self.socket_call(("get", "revision"), b"\x01\x00")
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(json.loads(process.stderr)["code"], "transport_error")

    def test_file_timeout_cleans_up_without_replaying(self):
        with tempfile.TemporaryDirectory() as root:
            process = self.run_cli("--transport", "file", "--timeout", "0.03", "get", "revision",
                                   env=self.env(HOLLOW_REQUEST_DIR=root))
            self.assertNotEqual(process.returncode, 0)
            self.assertEqual(json.loads(process.stderr)["code"], "timeout")
            self.assertEqual(list(Path(root).iterdir()), [])

    @unittest.skipUnless(os.name == "posix", "PTY transport is POSIX-only")
    def test_osc_chunks_and_terminal_restoration(self):
        import fcntl
        import pty
        import termios
        master, slave = pty.openpty()
        previous = termios.tcgetattr(slave)
        prefix, st = b"\x1b]1337;Hollow;", b"\x1b\\"
        params = json.dumps({"id": 123, "text": "x" * 7000})
        process = None
        try:
            process = subprocess.Popen([CLI, "--transport", "osc", "api", "call", "pane_send_text", params],
                                       env=self.env(), stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                       start_new_session=True,
                                       preexec_fn=lambda: fcntl.ioctl(0, termios.TIOCSCTTY, 0))
            pending, chunks, request = b"", {}, None
            deadline = time.monotonic() + 4
            while request is None and time.monotonic() < deadline:
                if not select.select([master], [], [], .1)[0]:
                    continue
                pending += os.read(master, 65536)
                while prefix in pending and st in pending:
                    start = pending.index(prefix) + len(prefix)
                    end = pending.index(st, start)
                    frame = json.loads(pending[start:end])
                    pending = pending[end + len(st):]
                    if frame["kind"] == "chunk":
                        part = frame["payload"]
                        chunks[part["index"]] = part["data"]
                        if len(chunks) == part["total"]:
                            request = json.loads("".join(chunks[i] for i in range(1, part["total"] + 1)))
                    else:
                        request = frame
            self.assertIsNotNone(request)
            self.assertEqual(request["name"], "command_api")
            self.assertEqual(request["params"]["text"], "x" * 7000)
            # Unrelated replies must not terminate our query.
            unrelated = {**result(result(0)), "request_id": "someone-else"}
            os.write(master, prefix + json.dumps(unrelated).encode() + st)
            reply = {**result(result()), "request_id": request["request_id"]}
            text = json.dumps(reply)
            parts = [text[i:i + 40] for i in range(0, len(text), 40)]
            for index, part in enumerate(parts, 1):
                frame = {"kind": "chunk", "request_id": "reply-chunks",
                         "payload": {"index": index, "total": len(parts), "data": part}}
                encoded = prefix + json.dumps(frame).encode() + st
                os.write(master, encoded[:4])
                os.write(master, encoded[4:])
            stdout, stderr = process.communicate(timeout=4)
            self.assertEqual(process.returncode, 0, stderr.decode())
            self.assertIsNone(json.loads(stdout))
            self.assertEqual(termios.tcgetattr(slave), previous)
        finally:
            if process is not None and process.poll() is None:
                process.kill()
                process.communicate()
            os.close(master)
            os.close(slave)

    @unittest.skipUnless(os.name == "posix", "PTY transport is POSIX-only")
    def test_osc_timeout_restores_terminal(self):
        import fcntl
        import pty
        import termios
        master, slave = pty.openpty()
        previous = termios.tcgetattr(slave)
        try:
            process = subprocess.Popen([CLI, "--transport", "osc", "--timeout", "0.05", "get", "revision"],
                                       env=self.env(), stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                       start_new_session=True,
                                       preexec_fn=lambda: fcntl.ioctl(0, termios.TIOCSCTTY, 0))
            _, stderr = process.communicate(timeout=4)
            self.assertNotEqual(process.returncode, 0)
            self.assertEqual(json.loads(stderr)["code"], "timeout")
            self.assertEqual(termios.tcgetattr(slave), previous)
        finally:
            os.close(master)
            os.close(slave)


if __name__ == "__main__":
    unittest.main()
