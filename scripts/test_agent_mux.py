#!/usr/bin/env python3
"""Real-agent mux correctness tests; no GUI dependencies."""
import os
import struct
import sys
import time
import unittest

from agent_mux import (
    Client, HEADER, SPAWN, INPUT, OUTPUT, RESIZE, EXIT, ERROR, CLOSE,
    SPAWNED, CREDIT, FOCUS, WINDOW,
    mixed_benchmark,
)

AGENT = os.environ.get("HOLLOW_TEST_AGENT", "zig-out/bin/hollow-agent")


class MuxTests(unittest.TestCase):
    def setUp(self):
        self.client = Client([AGENT])
        self.addCleanup(self.client.close)

    def until(self, predicate, timeout=5):
        deadline = time.monotonic() + timeout
        frames = []
        while time.monotonic() < deadline:
            frame = self.client.recv(deadline - time.monotonic())
            frames.append(frame)
            if predicate(*frame):
                return frames
        self.fail("deadline exceeded")

    def test_mixed_benchmark_counts_each_flood_and_actual_echoes(self):
        # Functional checks only; timing thresholds belong in comparative runs.
        for mode, panes in (("pty", 1), ("pty", 4), ("mux", 4)):
            result = mixed_benchmark([AGENT], mode, panes, 3)
            self.assertEqual(result["samples"], 3)
            self.assertEqual(len(result["flood_bytes"]), panes - 1)
            self.assertTrue(all(n > 0 for n in result["flood_bytes"]))
            self.assertGreater(result["echo_ms"]["p50"], 0)

    def test_raw_reader_batch_diagnostic_counts_all_bytes(self):
        from agent_pty_read_bench import benchmark
        for workers, batch in ((1, 1), (2, 8)):
            result = benchmark(2, workers, 65536, batch)
            self.assertEqual(result["bytes"], 2 * 65536)
            self.assertEqual(result["batch_reads"], batch)
            self.assertGreater(result["reads"], 0)

    def test_invalid_reader_batch_size_rejected_before_hello(self):
        import subprocess
        for value in ("0", "3"):
            result = subprocess.run(
                [AGENT, "mux"], input=b"", capture_output=True, timeout=3,
                env=dict(os.environ, HOLLOW_MUX_READ_WORKERS="2", HOLLOW_MUX_READ_BATCH_JOBS=value),
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, b"")
            self.assertIn(b"InvalidBatchSize", result.stderr)

    def test_single_multi_single_read_path_switches_preserve_binary_order(self):
        with Client([AGENT], env=dict(os.environ, HOLLOW_MUX_DIAGNOSTICS="1")) as client:
            count = 128 * 1024
            code = (
                "import os,tty; tty.setraw(0); os.write(1,b'READY'); "
                f"exec('for _ in range(3):\\n b=os.read(0,1); left={count}\\n while left:\\n  n=os.write(1,b*min(left,65536)); left-=n')"
            )
            client.spawn(1, ["python3", "-c", code])

            def output(sid, expected):
                got = bytearray()
                while len(got) < len(expected):
                    kind, stream, body = client.recv()
                    if kind == ERROR:
                        self.fail(body.decode())
                    if kind == OUTPUT:
                        self.assertEqual(stream, sid)
                        got.extend(body)
                self.assertEqual(got, expected)

            output(1, b"READY")
            client.input(1, b"\x00")
            output(1, b"\x00" * count)
            client.spawn(2, ["python3", "-c", "import os,tty; tty.setraw(0); os.write(1,b'READY'); os.read(0,1)"])
            output(2, b"READY")
            client.input(1, b"\xff")
            output(1, b"\xff" * count)
            client.send(CLOSE, 2)
            while True:
                kind, sid, body = client.recv()
                if kind == ERROR:
                    self.fail(body.decode())
                if kind == EXIT and sid == 2:
                    break
            client.input(1, b"\x80")
            output(1, b"\x80" * count)
            while True:
                kind, sid, body = client.recv()
                if kind == ERROR:
                    self.fail(body.decode())
                if kind == EXIT and sid == 1:
                    self.assertEqual(struct.unpack("<I", body)[0], 0)
                    break
        if int(os.environ.get("HOLLOW_MUX_READ_WORKERS", "0")):
            # Persistent readers handle every attached stream.
            self.assertEqual(client.diagnostics["inline_reads"], 0)
            self.assertGreater(client.diagnostics["pty_reads"], 0)
        else:
            self.assertGreater(client.diagnostics["inline_reads"], 0)

    def test_independent_environment_cwd_exit_and_spawn_failure(self):
        self.client.spawn(1, ["/bin/sh", "-c", "printf '%s:%s' \"$MUX_TEST\" \"$PWD\"; exit 7"],
                          cwd="/", env=[dict(key="MUX_TEST", value="one")])
        self.client.spawn(2, ["/does/not/exist"])
        self.client.spawn(3, ["/bin/sh", "-c", "printf '%s:%s' \"${MUX_TEST-unset}\" \"$PWD\""], cwd="/tmp")
        output = {1: bytearray(), 3: bytearray()}
        exits = {}
        failed = False
        while len(exits) < 2 or not failed:
            kind, sid, body = self.client.recv()
            if kind == OUTPUT:
                output[sid].extend(body)
            elif kind == EXIT:
                exits[sid] = struct.unpack("<I", body)[0]
            elif kind == ERROR:
                self.assertEqual(sid, 2)
                failed = True
        self.assertEqual(output, {1: b"one:/", 3: b"unset:/tmp"})
        self.assertEqual(exits, {1: 7, 3: 0})

    def test_stopped_output_consumer_does_not_block_other_stream(self):
        self.client.stopped.add(1)
        self.client.spawn(1, ["/bin/sh", "-c", "exec yes x"])
        count = 0
        while count < WINDOW:
            kind, sid, body = self.client.recv()
            if kind == OUTPUT and sid == 1:
                count += len(body)
        self.assertEqual(count, WINDOW)
        self.client.spawn(2, ["/bin/sh", "-c", "printf alive"])
        frames = self.until(lambda k, s, _: k == EXIT and s == 2)
        self.assertEqual(b"".join(b for k, s, b in frames if k == OUTPUT and s == 2), b"alive")
        self.assertFalse(any(k == OUTPUT and s == 1 for k, s, _ in frames))
        self.client.send(CLOSE, 1)
        self.until(lambda k, s, _: k == EXIT and s == 1)

    def test_blocked_child_input_and_close_leave_other_stream_running(self):
        self.client.spawn(1, ["python3", "-c", "import tty,time,os; tty.setraw(0); os.write(1,b'R'); time.sleep(60)"])
        self.until(lambda k, s, b: k == OUTPUT and s == 1 and b == b"R")
        for _ in range(4):
            self.client.input(1, b"x" * 16384)
        self.client.spawn(2, ["/bin/sh", "-c", "printf responsive"])
        self.until(lambda k, s, _: k == EXIT and s == 2)
        self.client.send(CLOSE, 1)
        self.until(lambda k, s, _: k == EXIT and s == 1)

    def test_fragmented_spawn_resize_and_final_output_order(self):
        import json
        body = json.dumps(dict(argv=["/bin/sh", "-c", "sleep .05; stty size; printf final"], shell_integration=False)).encode()
        wire = HEADER.pack(SPAWN, 9, len(body)) + body
        for byte in wire:
            os.write(self.client.process.stdin.fileno(), bytes([byte]))
        self.client.send(RESIZE, 9, struct.pack("<HH", 123, 45))
        frames = self.until(lambda k, s, _: k == EXIT and s == 9)
        output = b"".join(b for k, s, b in frames if k == OUTPUT and s == 9)
        self.assertEqual(output, b"45 123\r\nfinal")
        # Late stream data must never be delivered to a newer pane.
        self.client.send(INPUT, 9, b"late")
        self.client.spawn(10, ["/bin/sh", "-c", "printf new"])
        frames = self.until(lambda k, s, _: k == EXIT and s == 10)
        self.assertEqual(b"".join(b for k, s, b in frames if k == OUTPUT and s == 10), b"new")

    def test_oversized_input_rejected_from_header_without_payload(self):
        os.write(self.client.process.stdin.fileno(), HEADER.pack(INPUT, 1, 16385))
        self.client.process.wait(timeout=3)
        self.assertNotEqual(self.client.process.returncode, 0)

    def test_duplicate_id_invalidates_connection(self):
        self.client.spawn(1, ["/bin/sleep", "60"])
        self.until(lambda k, s, _: k == SPAWNED and s == 1)
        self.client.spawn(1, ["/bin/sleep", "60"])
        self.client.process.wait(timeout=4)
        self.assertNotEqual(self.client.process.returncode, 0)

    def test_stream_limit_is_recoverable(self):
        for sid in range(1, 33):
            self.client.spawn(sid, ["/bin/sleep", "60"])
        self.client.spawn(33, ["/bin/true"])
        frames = self.until(lambda k, s, _: k == ERROR and s == 33)
        self.assertEqual(frames[-1][2], b"StreamLimit")
        self.client.send(CLOSE, 1)
        self.until(lambda k, s, _: k == EXIT and s == 1)
        self.client.spawn(34, ["/bin/true"])
        self.until(lambda k, s, _: k == EXIT and s == 34)

    def test_credit_overflow_invalidates_connection(self):
        self.client.spawn(1, ["/bin/sleep", "60"])
        self.until(lambda k, s, _: k == SPAWNED and s == 1)
        self.client.send(CREDIT, 1, struct.pack("<I", WINDOW))
        self.client.process.wait(timeout=4)
        self.assertNotEqual(self.client.process.returncode, 0)

    def test_close_during_spawn_is_abort_not_connection_close(self):
        self.client.spawn(1, ["/bin/sleep", "60"])
        self.client.send(CLOSE, 1)
        self.until(lambda k, s, _: k == EXIT and s == 1)
        self.client.spawn(2, ["/bin/sh", "-c", "printf survived"])
        self.until(lambda k, s, _: k == EXIT and s == 2)

    def test_child_does_not_inherit_other_masters_or_transport_fds(self):
        self.client.spawn(1, ["/bin/sleep", "60"])
        self.until(lambda k, s, _: k == SPAWNED and s == 1)
        code = (
            "import os; "
            "print(','.join(str(fd) for fd in range(3,256) if os.path.exists('/proc/self/fd/'+str(fd))))"
        )
        self.client.spawn(2, ["python3", "-c", code])
        frames = self.until(lambda k, s, _: k == EXIT and s == 2)
        self.assertEqual(b"".join(b for k, s, b in frames if k == OUTPUT and s == 2), b"\r\n")

    def test_disconnect_kills_and_reaps_children_without_reading_output(self):
        self.client.spawn(1, ["/bin/sh", "-c", "printf '%s\\n' $$; exec yes"])
        frames = self.until(lambda k, s, _: k == OUTPUT and s == 1)
        output = b"".join(b for k, s, b in frames if k == OUTPUT and s == 1)
        pid = int(output.splitlines()[0])
        self.client.process.stdin.close()
        self.client.process.wait(timeout=3)
        self.assertFalse(os.path.exists(f"/proc/{pid}"))

    def test_invalid_environment_fails_only_its_stream(self):
        self.client.spawn(1, ["/bin/true"], env=[dict(key="bad=key", value="v")])
        frames = self.until(lambda k, s, _: k == ERROR and s == 1)
        self.assertEqual(frames[-1][2], b"InvalidEnv")
        self.client.spawn(2, ["/bin/true"])
        self.until(lambda k, s, _: k == EXIT and s == 2)

    def test_batched_binary_output_order_exit_and_staging_bound(self):
        env = dict(os.environ, HOLLOW_MUX_DIAGNOSTICS="1")
        with Client([AGENT], env=env) as client:
            expected = {}
            received = {}
            for sid in range(1, 9):
                expected[sid] = bytes(range(256)) * 1024 + bytes([sid])
                received[sid] = bytearray()
                code = (
                    "import os,tty; tty.setraw(0); "
                    f"data=bytes(range(256))*1024+bytes([{sid}]); "
                    "exec('while data:\\n n=os.write(1,data[:65536]); data=data[n:]')"
                )
                client.spawn(sid, ["python3", "-c", code])
            exited = set()
            while len(exited) < len(expected):
                kind, sid, body = client.recv()
                if kind == OUTPUT:
                    self.assertNotIn(sid, exited)
                    self.assertLessEqual(len(body), 16384)
                    received[sid].extend(body)
                elif kind == EXIT:
                    self.assertEqual(received[sid], expected[sid])
                    self.assertEqual(struct.unpack("<I", body)[0], 0)
                    exited.add(sid)
                elif kind == ERROR:
                    self.fail(body.decode())
        self.assertLessEqual(client.diagnostics["tx_high_water"], 16384 + HEADER.size)
        self.assertEqual(client.diagnostics["output_bytes"], sum(map(len, expected.values())))
        workers = int(os.environ.get("HOLLOW_MUX_READ_WORKERS", "0"))
        self.assertEqual(client.diagnostics["read_workers"], workers)
        self.assertEqual(client.diagnostics["read_batch_jobs"], int(os.environ.get("HOLLOW_MUX_READ_BATCH_JOBS", "1")))
        self.assertGreater(client.diagnostics["pty_reads"], 0)

    def test_focused_echo_and_background_progress_with_output_flood(self):
        self.client.spawn(1, ["/bin/sh", "-c", "exec yes x"])
        code = (
            "import os,tty; tty.setraw(0); os.write(1,b'READY'); "
            "exec('for _ in range(8):\\n os.write(1,os.read(0,1))')"
        )
        self.client.spawn(2, ["python3", "-c", code])
        self.until(lambda k, s, b: k == OUTPUT and s == 2 and b == b"READY")
        self.client.send(FOCUS, 2)
        background_bytes = 0
        for _ in range(8):
            self.client.input(2, b"q")
            frames = self.until(lambda k, s, _: k == OUTPUT and s == 2)
            self.assertEqual(frames[-1][2], b"q")
            background_bytes += sum(len(b) for k, s, b in frames if k == OUTPUT and s == 1)
        self.assertGreater(background_bytes, 0)
        self.client.send(CLOSE, 1)
        self.until(lambda k, s, _: k == EXIT and s == 1)

    def test_stopped_batch_member_leaves_many_floods_and_focused_echo_live(self):
        # More floods than readers forces paired mode to exercise independent
        # credits/results, not merely the single-job fallback for scarce work.
        self.client.stopped.add(1)
        for sid in range(1, 9):
            self.client.spawn(sid, ["/bin/sh", "-c", "exec yes x"])
        code = (
            "import os,tty; tty.setraw(0); os.write(1,b'READY'); "
            "exec('for _ in range(8):\\n os.write(1,os.read(0,1))')"
        )
        self.client.spawn(9, ["python3", "-c", code])
        counts = {sid: 0 for sid in range(1, 9)}
        deadline = time.monotonic() + 5

        def recv():
            remaining = deadline - time.monotonic()
            self.assertGreater(remaining, 0, "flood/echo progress deadline exceeded")
            kind, sid, body = self.client.recv(remaining)
            if kind == ERROR:
                self.fail(body.decode())
            if kind == OUTPUT and sid in counts:
                counts[sid] += len(body)
            return kind, sid, body

        ready = False
        while not ready or counts[1] < WINDOW or not all(counts.values()):
            kind, sid, body = recv()
            if kind == OUTPUT and sid == 9:
                self.assertEqual(body, b"READY")
                ready = True
        self.client.send(FOCUS, 9)
        for _ in range(8):
            self.client.input(9, b"q")
            while True:
                kind, sid, body = recv()
                if kind == OUTPUT and sid == 9:
                    self.assertEqual(body, b"q")
                    break
        for sid in range(1, 9):
            self.client.send(CLOSE, sid)
        exited = set()
        while len(exited) < 9:
            kind, sid, _ = recv()
            if kind == EXIT:
                exited.add(sid)
        self.assertEqual(counts[1], WINDOW)

    def test_inflight_close_slot_reuse_and_fixed_thread_fd_counts(self):
        root = f"/proc/{self.client.process.pid}"
        initial_fds = len(os.listdir(root + "/fd"))
        expected_threads = 1 + int(os.environ.get("HOLLOW_MUX_READ_WORKERS", "0"))
        self.assertEqual(len(os.listdir(root + "/task")), expected_threads)
        for base in (1, 9):
            floods = set(range(base, base + 4))
            for sid in sorted(floods):
                self.client.spawn(sid, ["/bin/sh", "-c", "exec yes x"])
            seen = set()
            while seen != floods:
                kind, sid, _ = self.client.recv()
                if kind == OUTPUT:
                    seen.add(sid)
            for sid in sorted(floods):
                self.client.send(CLOSE, sid)
            fresh = set(range(base + 4, base + 8))
            for sid in sorted(fresh):
                self.client.spawn(sid, ["/bin/sh", "-c", f"printf new{sid}"])
            received = {sid: bytearray() for sid in fresh}
            exited = set()
            while exited != floods | fresh:
                kind, sid, body = self.client.recv()
                if kind == OUTPUT and sid in fresh:
                    self.assertNotIn(sid, exited)
                    received[sid].extend(body)
                elif kind == EXIT:
                    exited.add(sid)
                elif kind == ERROR:
                    self.fail(body.decode())
            self.assertEqual(received, {sid: f"new{sid}".encode() for sid in fresh})
            self.assertEqual(len(os.listdir(root + "/fd")), initial_fds)
            self.assertEqual(len(os.listdir(root + "/task")), expected_threads)

    def test_close_after_pty_eof_still_terminates_live_child(self):
        code = (
            "import os,time; os.write(1,b'closed'); "
            "os.close(0); os.close(1); os.close(2); time.sleep(60)"
        )
        self.client.spawn(1, ["python3", "-c", code])
        self.until(lambda k, s, b: k == OUTPUT and s == 1 and b == b"closed")
        time.sleep(.05)  # Let the owner observe EOF before the explicit close.
        self.client.send(CLOSE, 1)
        self.until(lambda k, s, _: k == EXIT and s == 1)

    def test_stalled_final_output_keeps_child_pid_reserved_until_close(self):
        import fcntl
        import tempfile
        # Force a partial transport frame while a completed read result still
        # contains final output. Its exited PID must not be reaped/recycled yet.
        # Keep two streams live so enabled workers, not the single-pane fast
        # path, exercise the retained-result lifecycle.
        self.client.spawn(1, ["/bin/sleep", "60"])
        self.until(lambda k, s, _: k == SPAWNED and s == 1)
        fcntl.fcntl(self.client.process.stdout.fileno(), fcntl.F_SETPIPE_SZ, 4096)
        parent = "/tmp/opencode" if os.path.isdir("/tmp/opencode") else None
        with tempfile.TemporaryDirectory(dir=parent) as directory:
            pid_path = directory + "/pid"
            code = (
                "import os,tty; tty.setraw(0); "
                f"open({pid_path!r},'w').write(str(os.getpid())); "
                "data=b'x'*24000; "
                "exec('while data:\\n n=os.write(1,data); data=data[n:]'); os._exit(0)"
            )
            self.client.spawn(2, ["python3", "-c", code])
            self.until(lambda k, s, _: k == SPAWNED and s == 2)
            deadline = time.monotonic() + 3
            pid = None
            state = None
            while time.monotonic() < deadline:
                if os.path.exists(pid_path):
                    with open(pid_path) as file:
                        text = file.read()
                    if text:
                        pid = int(text)
                        self.assertTrue(os.path.exists(f"/proc/{pid}"), "child PID reaped before output drained")
                        with open(f"/proc/{pid}/stat") as file:
                            state = file.read().split(")", 1)[1].split()[0]
                        if state == "Z":
                            break
                time.sleep(.01)
            self.assertEqual(state, "Z")
            time.sleep(.05)
            self.assertTrue(os.path.exists(f"/proc/{pid}"))
            self.client.send(CLOSE, 2)
            self.until(lambda k, s, _: k == EXIT and s == 2)
            self.assertFalse(os.path.exists(f"/proc/{pid}"))

    def test_shell_integration_preparation_after_fork_stays_isolated(self):
        import tempfile
        parent = "/tmp/opencode" if os.path.isdir("/tmp/opencode") else None
        with tempfile.TemporaryDirectory(dir=parent) as home:
            for sid in (1, 2):
                env = [dict(key="HOME", value=home)]
                if sid == 1:
                    env.append(dict(key="HOLLOW_TEST_MUX_CHILD_ENV", value="one"))
                self.client.spawn(
                    sid, ["/bin/bash"], shell_integration=True, close_on_exit=True,
                    env=env, cwd="/",
                    command="printf '__MUX_%s__:%s' \"${HOLLOW_TEST_MUX_CHILD_ENV-unset}\" \"${HOLLOW_SHELL_INTEGRATION_DIR:+yes}\"",
                )
            output = {1: bytearray(), 2: bytearray()}
            exited = set()
            while len(exited) < 2:
                kind, sid, body = self.client.recv()
                if kind == OUTPUT:
                    output[sid].extend(body)
                elif kind == EXIT:
                    self.assertEqual(struct.unpack("<I", body)[0], 0)
                    exited.add(sid)
                elif kind == ERROR:
                    self.fail(body.decode())
            self.assertIn(b"__MUX_one__:yes", output[1])
            self.assertIn(b"__MUX_unset__:yes", output[2])


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]], verbosity=2)
