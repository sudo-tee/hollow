#!/usr/bin/env python3
"""Local experimental focus contract/correctness, not performance qualification."""
import argparse
import json
import os
import subprocess
import tempfile
import unittest

from agent_connectors import ProcessConnection
from agent_conformance import DATA, ERROR, RESPONSE, b64
from agent_pty import PtyClient
from agent_pty_bench import parse_focus_profiles


class FocusTests(unittest.TestCase):
    agent = "zig-out/bin/hollow-agent"
    deficit = False

    def client(self, *, bounded=True, enabled=True, negotiate=True, profile=False, stderr=subprocess.PIPE):
        env = dict(os.environ)
        for key in ("HOLLOW_AGENT_BOUNDED_BULK", "HOLLOW_AGENT_FOCUS_SCHEDULER",
                    "HOLLOW_AGENT_DEFICIT_SCHEDULER", "HOLLOW_AGENT_PROFILE", "HOLLOW_AGENT_QUEUE_PROFILE"):
            env.pop(key, None)
        if bounded:
            env["HOLLOW_AGENT_BOUNDED_BULK"] = "1"
        if enabled:
            env["HOLLOW_AGENT_FOCUS_SCHEDULER"] = "1"
        if self.deficit:
            env["HOLLOW_AGENT_DEFICIT_SCHEDULER"] = "1"
        if profile:
            env["HOLLOW_AGENT_QUEUE_PROFILE"] = "1"
        connection = ProcessConnection(subprocess.Popen([self.agent, "stdio"], env=env,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr,
            bufsize=0, start_new_session=True))
        client = PtyClient(connection)
        self.addCleanup(client.close)
        if negotiate:
            client.start(focus=True, deficit=self.deficit)
        return client

    def test_profile_correlates_payload_and_preserves_unenqueued_censoring(self):
        # File-backed stderr cannot fill a pipe and block diagnostic serialization.
        with tempfile.TemporaryFile(dir="/tmp/opencode" if os.path.isdir("/tmp/opencode") else None) as stderr:
            client = self.client(profile=True, stderr=stderr)
            pane = client.spawn(["/bin/sh", "-c", "stty raw -echo; printf READY; read line; printf OUT; read line"], logical_session=7)
            for expected in (b"READY", b"OUT"):
                if expected == b"OUT":
                    self.assertTrue(client.focus(1, 7, pane.stream)[1]["applied"])
                    self.assertEqual(pane.input(b"go\n")[0], RESPONSE)
                output = bytearray()
                while len(output) < len(expected):
                    kind, payload = pane.receive()
                    self.assertEqual(kind, DATA)
                    output.extend(payload)
                    pane.grant(len(payload))
                self.assertEqual(output, expected)
            self.assertTrue(client.focus(2, 7, pane.stream)[1]["applied"])
            self.assertTrue(client.focus(3, 0)[1]["applied"])
            self.assertTrue(client.focus(4, 7)[1]["applied"])
            self.assertTrue(client.focus(5, 7, pane.stream)[1]["applied"])
            self.assertFalse(client.focus(2, 7, pane.stream)[1]["applied"])
            self.assertEqual(pane.close()[0], RESPONSE)
            self.assertEqual(pane.receive()[0], ERROR)
            client.close()
            stderr.seek(0)
            profiles = parse_focus_profiles(stderr.read().decode())
            self.assertTrue(profiles)
            focus = profiles[-1]["focus"]
            self.assertEqual(focus["accepted"], 5)
            self.assertEqual(focus["dropped"], 0)
            first, superseded, clear, session, released = focus["events"]
            self.assertIsNotNone(first["complete_write_ns"])
            self.assertEqual(first["payload_end"] - first["payload_begin"], 3)
            self.assertEqual(superseded["stop"], "superseded")
            self.assertEqual(clear["stop"], "no_stream")
            self.assertEqual(session["stop"], "no_stream")
            self.assertEqual(released["stop"], "released")

    def test_both_flags_and_hello_are_required(self):
        for bounded, enabled, hello_focus in ((False, True, True), (True, False, True), (True, True, False)):
            with self.subTest(bounded=bounded, enabled=enabled, hello_focus=hello_focus):
                client = self.client(bounded=bounded, enabled=enabled, negotiate=False)
                _, _, _, payload = client.hello(json.dumps({"major": 1, "experimental_pty": True,
                                                            "experimental_focus": hello_focus}).encode())
                self.assertNotIn("experimental.focus", json.loads(payload)["capabilities"])
                self.assertEqual(client.request("FOCUS_UPDATE", {})[1]["code"], "unsupported")

    def test_focus_sequences_generation_and_invalid_target_are_isolated(self):
        client = self.client()
        pane = client.spawn(["/bin/sleep", "60"], logical_session=7)
        self.assertEqual(client.focus(10, 7, pane.stream)[:2], (RESPONSE, {"applied": True, "sequence": 10}))
        self.assertEqual(client.focus(9, 999, 999)[:2], (RESPONSE, {"applied": False, "sequence": 10}))
        for fields in ({"sequence": 11, "generation": "old"}, {"sequence": 11, "active_session_id": 8},
                       {"sequence": 11, "active_stream_id": pane.stream + 2}, {"sequence": 0}):
            body = {"generation": client.focus_generation, "sequence": 11,
                    "active_session_id": 7, "active_stream_id": pane.stream, **fields}
            self.assertEqual(client.request("FOCUS_UPDATE", body)[1]["code"], "invalid_argument")
        # Invalid requests must not consume focus sequence or kill another pane.
        self.assertEqual(client.focus(11, 0)[:2], (RESPONSE, {"applied": True, "sequence": 11}))
        self.assertEqual(pane.resize(40, 90)[0], RESPONSE)

    def test_generation_cannot_cross_connections(self):
        first, second = self.client(), self.client()
        self.assertNotEqual(first.focus_generation, second.focus_generation)
        body = {"generation": first.focus_generation, "sequence": 1,
                "active_session_id": 0, "active_stream_id": 0}
        self.assertEqual(second.request("FOCUS_UPDATE", body)[1]["code"], "invalid_argument")
        self.assertEqual(second.focus(1, 0)[1], {"applied": True, "sequence": 1})

    def test_closed_focus_and_slot_reuse_do_not_retarget_old_stream(self):
        client = self.client()
        old = client.spawn(["/bin/sleep", "60"], logical_session=7)
        self.assertEqual(client.focus(1, 7, old.stream)[0], RESPONSE)
        self.assertEqual(old.close()[0], RESPONSE)
        while old.receive()[0] == DATA:
            pass
        new = client.spawn(["/bin/sleep", "60"], logical_session=7)
        self.assertNotEqual(old.stream, new.stream)
        self.assertEqual(client.focus(2, 7, old.stream)[1]["code"], "invalid_argument")
        self.assertEqual(client.focus(2, 7, new.stream)[1], {"applied": True, "sequence": 2})

    def test_churn_exact_output_bulk_and_zero_credit_pane(self):
        client = self.client()
        panes = [client.spawn(["/bin/sh", "-c", "stty raw -echo; head -c 131072 /dev/zero; read line"],
                              logical_session=1 + index // 4, credit=0 if index == 7 else 65536)
                 for index in range(8)]
        received = [bytearray() for _ in panes]
        sequence = 0
        for _ in range(8):
            for index, pane in enumerate(panes[:7]):
                sequence += 1
                self.assertTrue(client.focus(sequence, 1 + index // 4, pane.stream)[1]["applied"])
                event = pane.receive()
                self.assertEqual(event[0], DATA)
                received[index].extend(event[1])
                pane.grant(len(event[1]))
            # Completed bulk remains serviceable amid focus and stopped credit.
            stdout, stderr = client.allocate_streams()
            kind, body, output = client.request("EXEC", {"argv_b64": [b64(b"/bin/printf"), b64(b"bulk")],
                "stdout_stream_id": stdout, "stderr_stream_id": stderr}, stream_ids=(stdout, stderr))
            self.assertEqual(kind, RESPONSE)
            self.assertEqual(output[stdout], b"bulk")
        for index, pane in enumerate(panes):
            if index == 7:
                self.assertTrue(pane.events.empty())
                # Explicit downstream credit resumes stopped output, no reconnect.
                pane.grant(65536)
            while len(received[index]) < 131072:
                event = pane.receive()
                self.assertEqual(event[0], DATA)
                received[index].extend(event[1])
                pane.grant(len(event[1]))
            self.assertEqual(received[index], bytes(131072))
            self.assertEqual(pane.input(b"\n")[0], RESPONSE)
            event = pane.receive()
            self.assertEqual(event[0], RESPONSE)
            self.assertEqual(event[1]["exit_code"], 0)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--agent", default=FocusTests.agent)
    parser.add_argument("--deficit-scheduler", action="store_true")
    args, remaining = parser.parse_known_args()
    FocusTests.agent = args.agent
    FocusTests.deficit = args.deficit_scheduler
    unittest.main(argv=[__file__, *remaining], verbosity=2)
