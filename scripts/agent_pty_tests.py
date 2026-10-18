#!/usr/bin/env python3
"""Real opt-in PTY experiment tests; not GUI/Windows performance qualification."""
import argparse
import json
import os
import queue
import re
import subprocess
import time
import unittest

from agent_connectors import LocalSubprocess, ProcessConnection
from agent_conformance import AgentClient, DATA, ERROR, RESPONSE, b64
from agent_pty import PtyClient


class PtyTests(unittest.TestCase):
    agent = "zig-out/bin/hollow-agent"

    def connection(self):
        if os.environ.get("HOLLOW_TEST_CONNECTOR_ARGV"):
            return ProcessConnection(subprocess.Popen(json.loads(os.environ["HOLLOW_TEST_CONNECTOR_ARGV"]),
                                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                                     bufsize=0, start_new_session=True))
        return LocalSubprocess(self.agent).connect()

    def setUp(self):
        self.client = PtyClient(self.connection())
        self.addCleanup(self.client.close)
        self.client.start()

    def until(self, session, needle, timeout=5):
        output = bytearray()
        deadline = time.monotonic() + timeout
        while needle not in output and time.monotonic() < deadline:
            kind, data = session.receive(timeout=max(0.01, deadline - time.monotonic()))
            self.assertEqual(kind, DATA, data)
            output.extend(data)
            session.grant(len(data))
            self.assertLessEqual(len(output), 1024 * 1024)
        self.assertIn(needle, output)
        return bytes(output)

    def terminal(self, session):
        output = bytearray()
        while True:
            kind, data = session.receive()
            if kind != DATA:
                return kind, data, bytes(output)
            output.extend(data)
            session.grant(len(data))
            self.assertLessEqual(len(output), 1024 * 1024)

    def test_streams_before_exit_and_all_stdio_have_controlling_tty(self):
        session = self.client.spawn(["/bin/sh", "-c", 'test -t 0 && test -t 1 && test -t 2 && test -r /dev/tty || exit 99; stty -echo; printf READY; read v; printf "<%s>" "$v"; exit 7'])
        self.until(session, b"READY")
        self.assertFalse(session.done)
        self.assertEqual(session.input(b"hello terminal\n")[0], RESPONSE)
        kind, result, data = self.terminal(session)
        self.assertEqual(kind, RESPONSE, result)
        self.assertEqual(result["exit_code"], 7)
        self.assertIn(b"<hello terminal>", data)

    def test_resize_and_winch_reach_foreground_process(self):
        session = self.client.spawn(["/bin/sh", "-c", "stty -echo; trap 'stty size' WINCH; printf READY; while :; do read v; done"], rows=25, cols=81)
        self.until(session, b"READY")
        self.assertEqual(session.resize(43, 119)[0], RESPONSE)
        self.until(session, b"43 119")
        session.close()
        self.assertEqual(self.terminal(session)[1]["code"], "cancelled")

    def test_raw_input_preserves_nul_non_utf8_and_control_bytes(self):
        session = self.client.spawn(["/bin/sh", "-c", "stty raw -echo; printf READY; head -c 4 | od -An -tx1"])
        self.until(session, b"READY")
        self.assertEqual(session.input(b"\x00\xff\x03\x0a")[0], RESPONSE)
        kind, result, data = self.terminal(session)
        self.assertEqual(kind, RESPONSE, result)
        self.assertIn(b"00 ff 03 0a", data)

    def test_ctrl_c_interrupts_foreground_job_not_interactive_shell(self):
        session = self.client.spawn(["/bin/sh", "-i"], env=[("PS1", "PTY_PROMPT> "), ("TERM", "xterm")])
        self.until(session, b"PTY_PROMPT>")
        session.input(b"sleep 30\n")
        time.sleep(0.1)
        session.input(b"\x03")
        self.until(session, b"PTY_PROMPT>", timeout=4)
        session.input(b"exit 0\n")
        self.assertEqual(self.terminal(session)[1]["exit_code"], 0)

    def test_credit_backpressures_output_without_blocking_rpc_and_drains_exit(self):
        session = self.client.spawn(["/bin/sh", "-c", "stty raw -echo; head -c 70000 /dev/zero"], credit=1024)
        kind, data = session.receive()
        self.assertEqual(kind, DATA)
        received = bytearray(data)
        while len(received) < 1024:
            kind, data = session.receive()
            self.assertEqual(kind, DATA)
            received.extend(data)
        self.assertEqual(len(received), 1024)
        with self.assertRaises(queue.Empty):
            session.receive(timeout=0.1)
        start = time.monotonic()
        self.assertEqual(self.client.request("HOST_INFO")[0], RESPONSE)
        self.assertLess(time.monotonic() - start, 2)
        session.grant(70000)
        kind, result, tail = self.terminal(session)
        self.assertEqual(kind, RESPONSE, result)
        self.assertEqual(len(received) + len(tail), 70000)
        self.assertEqual(set(received + tail), {0})

    def test_close_isolated_from_second_session_and_bad_resize_is_per_request(self):
        one = self.client.spawn(["/bin/sh", "-c", "printf ONE; exec sleep 30"])
        two = self.client.spawn(["/bin/sh", "-c", "stty -echo; printf TWO; read v; printf OK"])
        self.until(one, b"ONE")
        self.until(two, b"TWO")
        self.assertEqual(two.resize(0, 80)[0], ERROR)
        one.close()
        self.assertEqual(self.terminal(one)[1]["code"], "cancelled")
        two.input(b"go\n")
        self.assertIn(b"OK", self.terminal(two)[2])
        self.assertEqual(one.input(b"late")[0], ERROR)

    def test_missing_executable_returns_launch_error_and_connection_survives(self):
        session = self.client.spawn(["/hollow-no-such-pty-executable"])
        kind, result, _ = self.terminal(session)
        self.assertEqual(kind, ERROR)
        self.assertEqual(result["code"], "not_found")
        self.assertEqual(self.client.request("HOST_INFO")[0], RESPONSE)

    def test_pty_requires_explicit_hello_opt_in(self):
        plain = AgentClient(self.connection())
        self.addCleanup(plain.close)
        self.assertNotIn("experimental.pty", plain.start()["capabilities"])
        kind, result, _ = plain.request("PTY_SPAWN", {"argv_b64": [b64(b"/bin/sh")]})
        self.assertEqual(kind, ERROR)
        self.assertEqual(result["code"], "unsupported")

    def test_unread_input_is_bounded_and_deadline_closes_stalled_session(self):
        session = self.client.spawn(["/bin/sh", "-c", "stty raw -echo; printf READY; exec sleep 30"], timeout_ms=1000)
        self.until(session, b"READY")
        rejected = False
        for _ in range(32):
            kind, result, _ = session.input(b"x" * 16384)
            if kind == ERROR:
                self.assertEqual(result["code"], "resource_exhausted")
                rejected = True
                break
        self.assertTrue(rejected, "unread PTY input did not backpressure")
        kind, result, _ = self.terminal(session)
        self.assertEqual(kind, ERROR)
        self.assertEqual(result["code"], "timeout")

    def assert_workload_gone(self, pid, identity):
        inspector = AgentClient(self.connection())
        try:
            inspector.start()
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                kind, result, data = inspector.request("FS_READ", {"path_b64": b64(f"/proc/{pid}/stat".encode()), "limit": 4096})
                if kind == ERROR and result["code"] == "not_found":
                    return
                self.assertEqual(kind, RESPONSE, result)
                if data[0].rsplit(b") ", 1)[1].split()[19] != identity:
                    return  # PID was reused; never signal it.
                time.sleep(0.02)
            self.fail("owned PTY workload survived transport/agent death")
        finally:
            inspector.close()

    def workload(self):
        session = self.client.spawn(["/bin/sh", "-c", "printf 'PID=%s\\n' $$; exec sleep 30"])
        data = self.until(session, b"\n")
        pid = int(re.search(rb"PID=(\d+)", data)[1])
        kind, result, stat = self.client.request("FS_READ", {"path_b64": b64(f"/proc/{pid}/stat".encode()), "limit": 4096})
        self.assertEqual(kind, RESPONSE, result)
        return pid, stat[0].rsplit(b") ", 1)[1].split()[19]

    def test_transport_eof_reaps_owned_pty_workload(self):
        pid, identity = self.workload()
        self.client.close()
        self.assert_workload_gone(pid, identity)

    def test_agent_sigkill_guardian_reaps_owned_pty_workload(self):
        pid, identity = self.workload()
        _, info, _ = self.client.request("HOST_INFO")
        out, err = self.client.allocate_streams()
        fields = {"argv_b64": [b64(b"/bin/kill"), b64(b"-KILL"), b64(str(info["agent_pid"]).encode())],
                  "stdout_stream_id": out, "stderr_stream_id": err}
        with self.assertRaises((EOFError, BrokenPipeError, ConnectionResetError)):
            self.client.request("EXEC", fields, stream_ids=(out, err))
        self.assert_workload_gone(pid, identity)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--agent", required=True)
    args = parser.parse_args()
    PtyTests.agent = args.agent
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(PtyTests)
    raise SystemExit(0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1)
